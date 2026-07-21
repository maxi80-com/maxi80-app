import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Tests for the coordinator's audio-focus interruption state machine.
/// Validates that after a permanent audio focus loss (e.g. another media app taking over),
/// the user can resume playback by tapping Play — reproducing and validating the fix for
/// GitHub issue #5.
@Suite("Audio Focus Interruption Tests")
struct AudioFocusInterruptionTests {

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

  /// Brings coordinator to `.playing` by simulating the normal play→metadata flow.
  @MainActor
  private func startPlaying(_ coordinator: RadioPlayerCoordinator) async {
    coordinator.play()
    #expect(coordinator.playbackState == .loading)
    await coordinator.handleMetadataChanged("Artist - Song Title")
    #expect(coordinator.playbackState == .playing)
  }

  /// Fires the player's interruption callback and yields to let the scheduled Task execute.
  /// The coordinator wires `onInterruption` via `Task { @MainActor ... }`, so we must yield
  /// after invoking the callback to give that task a chance to run.
  @MainActor
  private func fireInterruption(_ player: AudioStreamPlayer, began: Bool) async {
    player.onInterruption?(began)
    await Task.yield()
  }

  // MARK: - Permanent Focus Loss → User Resume

  @Test("After permanent audio focus loss, user tap on Play transitions to loading state")
  @MainActor
  func permanentFocusLossAllowsManualResume() async {
    let (coordinator, player) = makeCoordinator()

    // Bring to playing state via normal flow.
    await startPlaying(coordinator)

    // Simulate permanent audio focus loss (AUDIOFOCUS_LOSS).
    await fireInterruption(player, began: true)

    #expect(coordinator.playbackState == .paused)

    // User taps Play after the other app releases focus.
    coordinator.play()

    #expect(coordinator.playbackState == .loading)
  }

  // MARK: - Transient Focus Loss → Auto Resume

  @Test("After transient audio focus loss, resume interruption transitions back to loading/playing")
  @MainActor
  func transientFocusLossResumesOnRegain() async {
    let (coordinator, player) = makeCoordinator()

    // Bring to playing state.
    coordinator.play()
    await coordinator.handleMetadataChanged("Artist - Some Song")
    #expect(coordinator.playbackState == .playing)

    // Transient loss.
    await fireInterruption(player, began: true)
    #expect(coordinator.playbackState == .paused)

    // Focus regained — coordinator calls play() internally.
    await fireInterruption(player, began: false)

    #expect(coordinator.playbackState == .loading)
  }

  // MARK: - Multiple Focus Loss/Regain Cycles Don't Wedge

  @Test("Multiple consecutive focus loss and regain cycles don't wedge the state machine")
  @MainActor
  func multipleFocusCyclesDontWedge() async {
    let (coordinator, player) = makeCoordinator()

    // Bring to playing state.
    coordinator.play()
    await coordinator.handleMetadataChanged("Artist - First Song")
    #expect(coordinator.playbackState == .playing)

    // Cycle 1: loss → regain
    await fireInterruption(player, began: true)
    #expect(coordinator.playbackState == .paused)
    await fireInterruption(player, began: false)
    #expect(coordinator.playbackState == .loading)

    // Simulate metadata arriving (stream reconnected).
    await coordinator.handleMetadataChanged("Artist - Second Song")
    #expect(coordinator.playbackState == .playing)

    // Cycle 2: loss → regain
    await fireInterruption(player, began: true)
    #expect(coordinator.playbackState == .paused)
    await fireInterruption(player, began: false)
    #expect(coordinator.playbackState == .loading)

    // Cycle 3: loss → manual resume
    await coordinator.handleMetadataChanged("Artist - Third Song")
    await fireInterruption(player, began: true)
    #expect(coordinator.playbackState == .paused)
    coordinator.play()
    #expect(coordinator.playbackState == .loading)

    // Final metadata proves the stream is alive.
    await coordinator.handleMetadataChanged("Artist - Fourth Song")
    #expect(coordinator.playbackState == .playing)
  }

  // MARK: - Pause During Interruption Doesn't Double-Pause

  @Test("User pause during interrupted state doesn't cause invalid state")
  @MainActor
  func pauseDuringInterruptionIsClean() async {
    let (coordinator, player) = makeCoordinator()

    // Bring to playing state.
    coordinator.play()
    await coordinator.handleMetadataChanged("Artist - Song")
    #expect(coordinator.playbackState == .playing)

    await fireInterruption(player, began: true)
    #expect(coordinator.playbackState == .paused)

    // User explicitly pauses (maybe hit pause before realizing it's already paused).
    coordinator.pause()
    #expect(coordinator.playbackState == .paused)

    // User plays again — should transition to loading, not get stuck.
    coordinator.play()
    #expect(coordinator.playbackState == .loading)
  }
}
