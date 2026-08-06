import Foundation
import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Tests the first consumer of the flag system: the `sleep_timer` kill switch (GitHub issue #72).
///
/// The gate is enforced in two places on purpose. `RadioPlayerViewModel.isSleepTimerAvailable` hides
/// the control, and `RadioPlayerCoordinator.startSleepTimer` refuses to arm one — so a kill switch
/// actually kills the feature rather than only hiding its button (CarPlay and the TV UIs reach the
/// coordinator through paths that don't go through the phone control tray).
@Suite("Sleep Timer Feature Gate")
struct SleepTimerFeatureGateTests {

  actor StubAPIClient: APIClientProtocol {
    func fetchStation() async throws(APIClientError) -> String { throw .noContent }
    func fetchArtworkURL(artist: String, title: String) async throws(APIClientError) -> String {
      throw .noContent
    }
    func fetchHistory() async throws(APIClientError) -> String { throw .noContent }
  }

  @MainActor
  private func makeViewModel(flags: FeatureFlags)
    -> (viewModel: RadioPlayerViewModel, coordinator: RadioPlayerCoordinator)
  {
    let apiClient = StubAPIClient()
    let coordinator = RadioPlayerCoordinator(
      player: AudioStreamPlayer(),
      nowPlaying: NowPlayingController(),
      apiClient: apiClient,
      artworkService: ArtworkService(apiClient: apiClient),
      featureFlags: flags
    )
    return (RadioPlayerViewModel(coordinator: coordinator, featureFlags: flags), coordinator)
  }

  /// `startSleepTimer` guards on playback state, so tests that arm a timer must be playing first.
  @MainActor
  private func startPlaying(_ coordinator: RadioPlayerCoordinator) async {
    coordinator.play()
    await coordinator.handleMetadataChanged("Artist - Song")
  }

  @Test("The sleep timer is available by default (the flag defaults on)")
  @MainActor
  func availableByDefault() {
    let (viewModel, _) = makeViewModel(flags: FeatureFlags())

    #expect(viewModel.isSleepTimerAvailable == true)
  }

  @Test("The backend kill switch makes the sleep timer unavailable to the UI")
  @MainActor
  func killSwitchHidesControl() {
    let flags = FeatureFlags()
    let (viewModel, _) = makeViewModel(flags: flags)

    flags.update(from: ["sleep_timer": false])

    #expect(viewModel.isSleepTimerAvailable == false)
  }

  @Test("The coordinator refuses to arm a sleep timer while the flag is off")
  @MainActor
  func killSwitchPreventsArmingTheTimer() async {
    let flags = FeatureFlags()
    let (_, coordinator) = makeViewModel(flags: flags)
    await startPlaying(coordinator)

    flags.update(from: ["sleep_timer": false])
    coordinator.startSleepTimer(minutes: 30)

    #expect(coordinator.sleepTimerFiresAt == nil)
  }

  @Test("With the flag on, arming a sleep timer still works")
  @MainActor
  func flagOnStillArmsTheTimer() async {
    let flags = FeatureFlags()
    let (_, coordinator) = makeViewModel(flags: flags)
    await startPlaying(coordinator)

    coordinator.startSleepTimer(minutes: 30)

    #expect(coordinator.sleepTimerFiresAt != nil)
    coordinator.cancelSleepTimer()
  }

  @Test("With the flag off, the UI reports no active timer even if one was armed earlier")
  @MainActor
  func killSwitchMakesAnArmedTimerInertInTheUI() async {
    let flags = FeatureFlags()
    let (viewModel, coordinator) = makeViewModel(flags: flags)
    await startPlaying(coordinator)
    coordinator.startSleepTimer(minutes: 30)
    #expect(viewModel.isSleepTimerActive == true)

    // In production this ordering can't happen — `loadStation()` applies the flags once at launch,
    // before any timer can be armed. Asserting it anyway keeps the UI from ever rendering a
    // countdown pill or an active moon glyph for a feature that is switched off.
    flags.update(from: ["sleep_timer": false])

    #expect(viewModel.isSleepTimerAvailable == false)
    #expect(viewModel.isSleepTimerActive == false)
    #expect(viewModel.sleepCountdownText(now: Date()) == nil)

    coordinator.cancelSleepTimer()
  }
}
