import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Tests for volume synchronization between the system volume, the coordinator, and the view model.
/// Validates the fix for GitHub issue #4 (hardware volume buttons should move the in-app bar).
@Suite("Volume Sync Tests")
struct VolumeSyncTests {

  actor StubAPIClient: APIClientProtocol {
    func fetchStation() async throws(APIClientError) -> String { throw .noContent }
    func fetchArtworkURL(artist: String, title: String) async throws(APIClientError) -> String {
      throw .noContent
    }
    func fetchHistory() async throws(APIClientError) -> String { throw .noContent }
  }

  @MainActor
  private func make() -> (vm: RadioPlayerViewModel, coordinator: RadioPlayerCoordinator, player: AudioStreamPlayer) {
    let player = AudioStreamPlayer()
    let apiClient = StubAPIClient()
    let coordinator = RadioPlayerCoordinator(
      player: player,
      nowPlaying: NowPlayingController(),
      apiClient: apiClient,
      artworkService: ArtworkService(apiClient: apiClient)
    )
    return (RadioPlayerViewModel(coordinator: coordinator), coordinator, player)
  }

  // MARK: - View model reads through to the coordinator

  @Test("View model volume reads through to the coordinator")
  @MainActor
  func viewModelVolumeReadsCoordinator() {
    let (vm, coordinator, _) = make()
    coordinator.volume = 0.42
    #expect(vm.volume == 0.42)
  }

  // MARK: - A hardware volume change is reflected in the view model

  @Test("A system volume change (hardware buttons) updates the coordinator and view model")
  @MainActor
  func systemVolumeChangeUpdatesViewModel() async {
    let (vm, coordinator, player) = make()

    // Simulate the Android ContentObserver firing after a hardware-button press.
    // The player forwards the new level via onVolumeChanged, which the coordinator wired to
    // update its observable `volume`.
    player.onVolumeChanged?(0.3)
    await Task.yield()

    #expect(coordinator.volume == 0.3)
    #expect(vm.volume == 0.3)
  }

  // MARK: - Setting the volume from the UI propagates

  @Test("Setting volume from the view model updates the coordinator's observable volume")
  @MainActor
  func setVolumeFromViewModelUpdatesCoordinator() {
    let (vm, coordinator, _) = make()
    vm.setVolume(0.6)
    // The coordinator optimistically reflects the new level so the slider tracks the drag.
    #expect(coordinator.volume == 0.6)
    #expect(vm.volume == 0.6)
  }

  // MARK: - Round trip: UI set then hardware change

  @Test("UI-set volume and a later hardware change both land on the view model")
  @MainActor
  func roundTripVolume() async {
    let (vm, coordinator, player) = make()

    vm.setVolume(0.8)
    #expect(vm.volume == 0.8)

    // Later the user presses a hardware button; the observer fires with a new level.
    player.onVolumeChanged?(0.5)
    await Task.yield()
    #expect(coordinator.volume == 0.5)
    #expect(vm.volume == 0.5)
  }
}
