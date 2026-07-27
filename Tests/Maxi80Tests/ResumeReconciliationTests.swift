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

  actor StubAPIClient: APIClientProtocol {
    func fetchStation() async throws(APIClientError) -> String { throw .noContent }
    func fetchArtworkURL(artist: String, title: String) async throws(APIClientError) -> String {
      throw .noContent
    }
    func fetchHistory() async throws(APIClientError) -> String { throw .noContent }
  }

  @MainActor
  private func makeCoordinator() -> (coordinator: RadioPlayerCoordinator, player: AudioStreamPlayer)
  {
    let player = AudioStreamPlayer()
    let nowPlaying = NowPlayingController()
    let apiClient = StubAPIClient()
    let artworkService = ArtworkService(apiClient: apiClient)
    let coordinator = RadioPlayerCoordinator(
      player: player,
      nowPlaying: nowPlaying,
      apiClient: apiClient,
      artworkService: artworkService
    )
    return (coordinator, player)
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

  // MARK: - Axis A: carousel selection guard across recreation

  @Test("A foreground transition drops the recreated carousel's leftmost write-back")
  @MainActor
  func foregroundTransitionDropsCarouselWriteBack() {
    let (coordinator, _) = makeCoordinator()
    let viewModel = RadioPlayerViewModel(coordinator: coordinator)

    // Start focused on the live (now) slot, as after a normal launch.
    #expect(viewModel.selectedCoverID == AnyHashable(RadioPlayerViewModel.nowSlotID))

    // Returning from background recreates the carousel; open the guard window first.
    viewModel.beginForegroundTransition()

    // The freshly-laid-out carousel reports its leftmost (oldest) cover.
    viewModel.setSelectionFromCarousel(AnyHashable("oldest|Artist|Old Song"))

    // The write must be dropped so the persisted live selection survives.
    #expect(viewModel.selectedCoverID == AnyHashable(RadioPlayerViewModel.nowSlotID))
  }
}
