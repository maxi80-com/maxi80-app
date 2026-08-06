import Foundation
import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Tests the first consumer of the flag system: the `sleep_timer` kill switch (GitHub issue #72).
///
/// The gate lives in one place, `RadioPlayerViewModel.isSleepTimerAvailable`, which hides the tray
/// button that presents the picker. That button is the feature's only entry point, so nothing can arm
/// a timer while the flag is off and the coordinator needs no guard of its own.
///
/// A timer that was *already* running when the flag goes off deliberately keeps its countdown pill:
/// that pill is how the user cancels it, and hiding it would leave playback set to stop with no way
/// to call it off.
@Suite("Sleep Timer Feature Gate")
struct SleepTimerFeatureGateTests {

  @MainActor
  private func makeViewModel(flags: FeatureFlags)
    -> (viewModel: RadioPlayerViewModel, coordinator: RadioPlayerCoordinator)
  {
    let (coordinator, _) = makeTestCoordinator(featureFlags: flags)
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

  @Test("With the flag on, arming a sleep timer still works")
  @MainActor
  func flagOnStillArmsTheTimer() async {
    let flags = FeatureFlags()
    let (viewModel, coordinator) = makeViewModel(flags: flags)
    await startPlaying(coordinator)

    coordinator.startSleepTimer(minutes: 30)

    #expect(viewModel.isSleepTimerActive == true)
    coordinator.cancelSleepTimer()
  }

  @Test("A timer already running when the flag goes off stays cancellable in the UI")
  @MainActor
  func killSwitchLeavesARunningTimerCancellable() async {
    let flags = FeatureFlags()
    let (viewModel, coordinator) = makeViewModel(flags: flags)
    await startPlaying(coordinator)
    coordinator.startSleepTimer(minutes: 30)

    flags.update(from: ["sleep_timer": false])

    // The entry point is gone, but the countdown pill stays — it's the only way to call off a stop
    // that is already scheduled.
    #expect(viewModel.isSleepTimerAvailable == false)
    #expect(viewModel.isSleepTimerActive == true)
    #expect(viewModel.sleepCountdownText(now: Date()) != nil)

    viewModel.cancelSleepTimer()
    #expect(viewModel.isSleepTimerActive == false)
  }
}
