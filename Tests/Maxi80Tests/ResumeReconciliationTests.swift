import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Tests for the background→foreground resume fix (GitHub issue #9).
///
/// On Android, returning from background destroys and recreates the activity while the
/// process-wide coordinator/view-model survive. Two failures result:
///   - the coordinator's `playbackState` can stay stuck at `.loading` (spinner) because the
///     player's real playing state was never reconciled;
///   - the recreated carousel reports its leftmost (oldest) cover, clobbering the persisted
///     `selectedCoverID` because the write-drop guard only covered rotation.
/// These tests reproduce both and validate the reconcile + guard fix.
@Suite("Resume Reconciliation Tests")
struct ResumeReconciliationTests {

  @MainActor
  private func makeCoordinator() -> (coordinator: RadioPlayerCoordinator, player: FakeAudioPlayer) {
    makeTestCoordinator()
  }

  // MARK: - Axis B: playback state reconciliation

  @Test("Reconciling while the player is actually playing clears a stuck loading spinner")
  @MainActor
  func reconcilePromotesStuckLoadingToPlaying() {
    let (coordinator, player) = makeCoordinator()

    // Simulate the resume wedge: UI thinks it's loading, but the foreground-service player
    // is really playing (no fresh ICY metadata arrived to promote the state).
    coordinator.play()
    #expect(coordinator.playbackState == .loading)
    player.isPlaying = true

    coordinator.reconcileWithPlayer()

    #expect(coordinator.playbackState == .playing)
  }

  @Test("Reconciling does not override a user-initiated pause")
  @MainActor
  func reconcileKeepsPausedWhenPlayerNotPlaying() async {
    let (coordinator, player) = makeCoordinator()

    coordinator.play()
    await coordinator.handleMetadataChanged("Artist - Song")
    #expect(coordinator.playbackState == .playing)

    coordinator.pause()
    #expect(coordinator.playbackState == .paused)
    player.isPlaying = false

    coordinator.reconcileWithPlayer()

    #expect(coordinator.playbackState == .paused)
  }

  @Test("Reconciling promotes idle to playing when the player is really playing")
  @MainActor
  func reconcilePromotesIdleWhenPlayerPlaying() {
    let (coordinator, player) = makeCoordinator()

    // Idle app but the player is really playing = playback was started EXTERNALLY (e.g. Android
    // Auto / the car auto-resuming) while the app was backgrounded. On foreground return, reconcile
    // must reflect that so the button shows ⏸ not ▶ (issue #41). This can't override a user pause:
    // a user pause stops the player, so this path (guarded by `player.isPlaying`) is unreachable
    // after one.
    #expect(coordinator.playbackState == .idle)
    player.isPlaying = true

    coordinator.reconcileWithPlayer()

    #expect(coordinator.playbackState == .playing)
  }

  // MARK: - Axis C: external playback state sync (GitHub issue #29, symptom 2)

  @Test("An external pause (notification) demotes .playing to .paused")
  @MainActor
  func externalPauseDemotesPlayingToPaused() async {
    let (coordinator, _) = makeCoordinator()

    coordinator.play()
    await coordinator.handleMetadataChanged("Artist - Song")
    #expect(coordinator.playbackState == .playing)

    // media3 pauses the ExoPlayer from the notification → onIsPlayingChanged(false).
    coordinator.handlePlaybackStateChanged(isPlaying: false)

    #expect(coordinator.playbackState == .paused)
  }

  @Test("An external play signal promotes idle to playing (player is source of truth)")
  @MainActor
  func externalPlayPromotesIdle() {
    let (coordinator, _) = makeCoordinator()

    #expect(coordinator.playbackState == .idle)

    // The player only reports isPlaying=true when audio is actually playing (STATE_READY /
    // onIsPlayingChanged), so an external start (Android Auto / the car auto-resuming) while the
    // app is idle must flip the button to playing — the player is the source of truth (issue #41).
    coordinator.handlePlaybackStateChanged(isPlaying: true)

    #expect(coordinator.playbackState == .playing)
  }

  @Test("External state changes do not override an in-flight reconnection")
  @MainActor
  func externalStateDoesNotOverrideReconnecting() {
    let (coordinator, _) = makeCoordinator()

    // ReconnectionManager owns the .reconnecting state and emits isPlaying=false transients
    // while it stops/replays the stream. The external handler must leave it alone.
    coordinator.playbackState = .reconnecting(1)
    coordinator.handlePlaybackStateChanged(isPlaying: false)
    #expect(coordinator.playbackState == .reconnecting(1))

    coordinator.playbackState = .error("stream dropped")
    coordinator.handlePlaybackStateChanged(isPlaying: false)
    #expect(coordinator.playbackState == .error("stream dropped"))

    // Even an isPlaying=true during error must not silently flip to .playing.
    coordinator.playbackState = .error("stream dropped")
    coordinator.handlePlaybackStateChanged(isPlaying: true)
    #expect(coordinator.playbackState == .error("stream dropped"))
  }

  @Test("An external play signal clears a pending loading spinner")
  @MainActor
  func externalPlayClearsLoadingSpinner() {
    let (coordinator, _) = makeCoordinator()

    coordinator.play()
    #expect(coordinator.playbackState == .loading)

    coordinator.handlePlaybackStateChanged(isPlaying: true)

    #expect(coordinator.playbackState == .playing)
  }

  // MARK: - Axis A: carousel selection is canonical across recreation (guard tower removed)
  //
  // The old guard-window tests asserted that transient leftmost write-backs were DROPPED during
  // a recreation window. With the state-driven CoverFlowStrip there is no window: the renderer
  // never reports relayout geometry, and CarouselModel ignores ids it doesn't know. These tests
  // assert the same user-visible invariants directly on the model-backed view model.

  @Test("A stale id write (the old recreation transient) never moves the selection")
  @MainActor
  func staleIdWriteNeverMovesSelection() {
    let (coordinator, _) = makeCoordinator()
    let viewModel = RadioPlayerViewModel(coordinator: coordinator)

    #expect(viewModel.selectedCoverID == AnyHashable(RadioPlayerViewModel.nowSlotID))

    // The old failure mode (issue #44): repeated reports of an id that isn't a real cover.
    // No window/timer needed — the model rejects unknown ids unconditionally, however many
    // arrive and however late.
    for _ in 0..<10 {
      viewModel.selectedCoverID = AnyHashable("oldest|Artist|Old Song")
    }
    #expect(viewModel.selectedCoverID == AnyHashable(RadioPlayerViewModel.nowSlotID))

    // Real user selections of existing covers are honored (the model syncs from `covers`,
    // which the view computes on every render pass).
    coordinator.history = [HistoryEntry(artist: "Past", title: "Cover", timestamp: "some")]
    _ = viewModel.covers
    viewModel.selectedCoverID = AnyHashable("some|Past|Cover")
    #expect(viewModel.selectedCoverID == AnyHashable("some|Past|Cover"))
  }

  @Test("A browsed history cover survives a resume/recreation (selection is process-wide state)")
  @MainActor
  func browsedCoverSurvivesResume() {
    let (coordinator, _) = makeCoordinator()
    let viewModel = RadioPlayerViewModel(coordinator: coordinator)

    // User browses a past cover, then backgrounds the app.
    coordinator.history = [HistoryEntry(artist: "Artist", title: "Song", timestamp: "browsed")]
    _ = viewModel.covers
    viewModel.selectedCoverID = AnyHashable("browsed|Artist|Song")

    // Resume: the view tree (or Android activity) is recreated. The renderer re-reads
    // `selectedID` and re-derives the centered cover; the only thing that could disturb the
    // selection is a write of a different id — and history growing (a new song while away)
    // preserves the browsed selection as long as its cover still exists.
    SharedPlayer.handleForeground()
    coordinator.history = [
      HistoryEntry(artist: "Artist", title: "Song", timestamp: "browsed"),
      HistoryEntry(artist: "New", title: "Arrival", timestamp: "newer"),
    ]
    _ = viewModel.covers
    #expect(viewModel.selectedCoverID == AnyHashable("browsed|Artist|Song"))
    #expect(viewModel.isBrowsingHistory)
  }
}
