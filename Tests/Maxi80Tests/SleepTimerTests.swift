import Foundation
import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Tests for the sleep-timer feature (GitHub issue #1).
///
/// The fire-time / remaining-minutes arithmetic lives in pure static functions on
/// `SleepTimerManager` so it can be verified against a fixed reference date without real
/// sleeping. The coordinator-level tests then assert the observable state transitions (start,
/// cancel, cancel-on-play/pause) that the UI reads through — the coordinator still owns the
/// "only settable while playing" policy, so those tests belong at that level.
@Suite("Sleep Timer Tests")
struct SleepTimerTests {

  @MainActor
  private func makeCoordinator() -> (coordinator: RadioPlayerCoordinator, player: FakeAudioPlayer) {
    makeTestCoordinator()
  }

  /// Drive the coordinator into `.playing` — `startSleepTimer` now guards on playback state (a timer
  /// is only settable while audio is playing), so tests that arm a timer must play first. `play()`
  /// sets `.loading`; a metadata callback promotes it to `.playing`.
  @MainActor
  private func startPlaying(_ coordinator: RadioPlayerCoordinator) async {
    coordinator.play()
    await coordinator.handleMetadataChanged("Artist - Song")
  }

  // MARK: - Pure fire-time arithmetic

  @Test("Fire date is the reference date plus the requested minutes")
  func fireDateAddsMinutes() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    let firesAt = SleepTimerManager.fireDate(minutes: 30, from: base)
    #expect(firesAt == base.addingTimeInterval(30 * 60))
  }

  @Test("A non-positive duration clamps to the reference date (fires immediately)")
  func fireDateClampsNonPositive() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    #expect(SleepTimerManager.fireDate(minutes: 0, from: base) == base)
    #expect(SleepTimerManager.fireDate(minutes: -10, from: base) == base)
  }

  @Test("Remaining minutes rounds a partial final minute up")
  func remainingMinutesRoundsUp() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    // 90 seconds left → 2 minutes.
    let firesAt = base.addingTimeInterval(90)
    #expect(SleepTimerManager.remainingMinutes(until: firesAt, from: base) == 2)
    // Exactly 15 minutes left → 15.
    #expect(
      SleepTimerManager.remainingMinutes(until: base.addingTimeInterval(15 * 60), from: base)
        == 15)
  }

  @Test("Remaining minutes never goes negative for an elapsed timer")
  func remainingMinutesClampsPast() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    let firesAt = base.addingTimeInterval(-60)
    #expect(SleepTimerManager.remainingMinutes(until: firesAt, from: base) == 0)
  }

  @Test("The fade ramp ends at exactly zero (no faded-but-audible final step)")
  func fadeMultiplierEndsAtSilence() {
    // The last step must be full silence so the stream is never audible at the moment of stop.
    #expect(SleepTimerManager.fadeMultiplier(step: 12) == 0.0)
    // The ramp is monotonic and starts below 1.0.
    #expect(SleepTimerManager.fadeMultiplier(step: 1) < 1.0)
    #expect(
      SleepTimerManager.fadeMultiplier(step: 1) > SleepTimerManager.fadeMultiplier(step: 6)
    )
  }

  @Test("Extend folds the current remainder into the new duration")
  func extendFoldsRemainder() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    // 20 minutes remaining, extend by 15 → the new timer is 35 minutes from now.
    let firesAt = base.addingTimeInterval(20 * 60)
    let remaining = SleepTimerManager.remainingMinutes(until: firesAt, from: base)
    #expect(remaining + 15 == 35)
  }

  // MARK: - Coordinator state transitions

  @Test("Starting a timer sets a future fire date; cancelling clears it")
  @MainActor
  func startThenCancel() async {
    let (coordinator, _) = makeCoordinator()
    #expect(coordinator.sleepTimerFiresAt == nil)

    await startPlaying(coordinator)
    coordinator.startSleepTimer(minutes: 30)
    #expect(coordinator.sleepTimerFiresAt != nil)
    #expect(coordinator.sleepTimerFiresAt! > Date())

    coordinator.cancelSleepTimer()
    #expect(coordinator.sleepTimerFiresAt == nil)
  }

  @Test("Starting a timer again replaces the previous fire date")
  @MainActor
  func restartReplacesFireDate() async {
    let (coordinator, _) = makeCoordinator()

    await startPlaying(coordinator)
    coordinator.startSleepTimer(minutes: 15)
    let first = coordinator.sleepTimerFiresAt
    coordinator.startSleepTimer(minutes: 90)
    let second = coordinator.sleepTimerFiresAt

    #expect(first != nil)
    #expect(second != nil)
    #expect(second! > first!)
  }

  @Test("Starting a timer while not playing is ignored (guarded at the API boundary)")
  @MainActor
  func startWhileNotPlayingIsIgnored() {
    let (coordinator, _) = makeCoordinator()
    // Fresh coordinator is `.idle` — no audio, so arming must no-op.
    coordinator.startSleepTimer(minutes: 30)
    #expect(coordinator.sleepTimerFiresAt == nil)
  }

  @Test("A manual pause leaves the sleep timer running (only explicit cancel / firing ends it)")
  @MainActor
  func pauseDoesNotCancelTimer() async {
    let (coordinator, _) = makeCoordinator()

    coordinator.play()
    await coordinator.handleMetadataChanged("Artist - Song")
    coordinator.startSleepTimer(minutes: 30)
    let firesAt = coordinator.sleepTimerFiresAt
    #expect(firesAt != nil)

    // Pausing the stream keeps the timer running toward its original fire time (matching Apple
    // Podcasts / Music): the user can resume and still have it stop on schedule, or leave it stopped
    // and the timer simply elapses as a no-op. Only an explicit cancel or firing ends a timer.
    coordinator.pause()
    #expect(coordinator.sleepTimerFiresAt == firesAt)

    // The explicit cancel is still the way to end it.
    coordinator.cancelSleepTimer()
    #expect(coordinator.sleepTimerFiresAt == nil)
  }

  @Test("An external audio-focus pause leaves a running sleep timer intact (issue #57)")
  @MainActor
  func externalPauseDoesNotCancelTimer() async {
    let (coordinator, _) = makeCoordinator()

    coordinator.play()
    await coordinator.handleMetadataChanged("Artist - Song")
    coordinator.startSleepTimer(minutes: 30)
    let firesAt = coordinator.sleepTimerFiresAt
    #expect(firesAt != nil)

    // On Android a transient audio-focus loss surfaces as this external `false` transition (the
    // same event that fires `onInterruption(true)`), so it must NOT cancel the timer — otherwise
    // another app taking audio focus would end the sleep session. Nothing but an explicit cancel
    // or the timer firing ends it.
    coordinator.handlePlaybackStateChanged(isPlaying: false)
    #expect(coordinator.sleepTimerFiresAt == firesAt)
  }

  @Test("A sleep timer survives an audio interruption began then ended (issue #57)")
  @MainActor
  func interruptionDoesNotCancelTimer() async {
    let (coordinator, _) = makeCoordinator()

    coordinator.play()
    await coordinator.handleMetadataChanged("Artist - Song")
    coordinator.startSleepTimer(minutes: 30)
    let firesAt = coordinator.sleepTimerFiresAt
    #expect(firesAt != nil)

    // Interruption began (phone call / another app taking audio focus): playback pauses but the
    // timer keeps running toward its original absolute fire time — unchanged.
    coordinator.handleInterruption(began: true)
    #expect(coordinator.sleepTimerFiresAt == firesAt)

    // Interruption ended: playback resumes and the same timer is still armed for the same date.
    coordinator.handleInterruption(began: false)
    #expect(coordinator.sleepTimerFiresAt == firesAt)
  }

  @Test("A Bluetooth/wired disconnect leaves the sleep timer running")
  @MainActor
  func disconnectStopDoesNotCancelTimer() async {
    let (coordinator, _) = makeCoordinator()

    coordinator.play()
    await coordinator.handleMetadataChanged("Artist - Song")
    coordinator.startSleepTimer(minutes: 30)
    let firesAt = coordinator.sleepTimerFiresAt
    #expect(firesAt != nil)

    // A headphone/BT disconnect is involuntary, like a pause — it must not end the sleep session.
    coordinator.handleDisconnectStop()
    #expect(coordinator.sleepTimerFiresAt == firesAt)
  }

  @Test("Resuming playback leaves a running sleep timer intact")
  @MainActor
  func playDoesNotCancelTimer() async {
    let (coordinator, _) = makeCoordinator()

    coordinator.play()
    await coordinator.handleMetadataChanged("Artist - Song")
    coordinator.startSleepTimer(minutes: 30)
    #expect(coordinator.sleepTimerFiresAt != nil)

    // A resume/replay (e.g. auto-reconnect confirmation, or resuming after a pause) must NOT drop
    // the running timer. Only an explicit cancel or the timer firing ends it.
    coordinator.play()
    #expect(coordinator.sleepTimerFiresAt != nil)
  }

  @Test("Extending with no active timer is a no-op")
  @MainActor
  func extendWithoutActiveTimerIsNoOp() {
    let (coordinator, _) = makeCoordinator()
    coordinator.extendSleepTimer(minutes: 15)
    #expect(coordinator.sleepTimerFiresAt == nil)
  }

  // MARK: - ViewModel read-through

  @Test("The view model reflects the coordinator's sleep-timer state")
  @MainActor
  func viewModelReadsThrough() async {
    let (coordinator, _) = makeCoordinator()
    let viewModel = RadioPlayerViewModel(coordinator: coordinator)

    #expect(!viewModel.isSleepTimerActive)
    #expect(viewModel.sleepTimerFiresAt == nil)

    await startPlaying(coordinator)
    viewModel.startSleepTimer(minutes: 45)
    #expect(viewModel.isSleepTimerActive)
    #expect(viewModel.sleepTimerFiresAt != nil)

    viewModel.cancelSleepTimer()
    #expect(!viewModel.isSleepTimerActive)
  }

  @Test("The countdown text formats remaining time as M:SS")
  @MainActor
  func countdownTextFormatsMMSS() async {
    let (coordinator, _) = makeCoordinator()
    let viewModel = RadioPlayerViewModel(coordinator: coordinator)

    #expect(viewModel.sleepCountdownText(now: Date()) == nil)

    await startPlaying(coordinator)
    coordinator.startSleepTimer(minutes: 30)
    let firesAt = coordinator.sleepTimerFiresAt!
    // 90 seconds before firing → "1:30".
    let now = firesAt.addingTimeInterval(-90)
    #expect(viewModel.sleepCountdownText(now: now) == "1:30")
    // 5 seconds before firing → "0:05" (zero-padded seconds).
    let near = firesAt.addingTimeInterval(-5)
    #expect(viewModel.sleepCountdownText(now: near) == "0:05")
  }
}
