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

  @Test("The player's onPlaybackStateChanged callback promotes a loading state to playing")
  @MainActor
  func playbackStateCallbackPromotesLoading() async {
    let (coordinator, player) = makeCoordinator()

    coordinator.play()
    #expect(coordinator.playbackState == .loading)

    // The Android/iOS listener reports STATE_READY / isPlaying via this callback. It was
    // previously never wired into the coordinator, so the signal was dropped.
    player.onPlaybackStateChanged?(true)
    await Task.yield()

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
