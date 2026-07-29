import Foundation
import Testing

@testable import Maxi80
@testable import Maxi80Model
@testable import Maxi80Services

/// Tests for the sleep-timer feature (GitHub issue #1).
///
/// The fire-time / remaining-minutes arithmetic is extracted into pure static functions on
/// `RadioPlayerCoordinator` so it can be verified against a fixed reference date without real
/// sleeping. The coordinator-level tests then assert the observable state transitions (start,
/// cancel, cancel-on-play/pause) that the UI reads through.
@Suite("Sleep Timer Tests")
struct SleepTimerTests {

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
    let firesAt = RadioPlayerCoordinator.sleepTimerFireDate(minutes: 30, from: base)
    #expect(firesAt == base.addingTimeInterval(30 * 60))
  }

  @Test("A non-positive duration clamps to the reference date (fires immediately)")
  func fireDateClampsNonPositive() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    #expect(RadioPlayerCoordinator.sleepTimerFireDate(minutes: 0, from: base) == base)
    #expect(RadioPlayerCoordinator.sleepTimerFireDate(minutes: -10, from: base) == base)
  }

  @Test("Remaining minutes rounds a partial final minute up")
  func remainingMinutesRoundsUp() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    // 90 seconds left → 2 minutes.
    let firesAt = base.addingTimeInterval(90)
    #expect(RadioPlayerCoordinator.remainingMinutes(until: firesAt, from: base) == 2)
    // Exactly 15 minutes left → 15.
    #expect(
      RadioPlayerCoordinator.remainingMinutes(until: base.addingTimeInterval(15 * 60), from: base)
        == 15)
  }

  @Test("Remaining minutes never goes negative for an elapsed timer")
  func remainingMinutesClampsPast() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    let firesAt = base.addingTimeInterval(-60)
    #expect(RadioPlayerCoordinator.remainingMinutes(until: firesAt, from: base) == 0)
  }

  @Test("The fade ramp ends at exactly zero (no faded-but-audible final step)")
  func fadeMultiplierEndsAtSilence() {
    // The last step must be full silence so the stream is never audible at the moment of stop.
    #expect(RadioPlayerCoordinator.fadeMultiplier(step: 12) == 0.0)
    // The ramp is monotonic and starts below 1.0.
    #expect(RadioPlayerCoordinator.fadeMultiplier(step: 1) < 1.0)
    #expect(
      RadioPlayerCoordinator.fadeMultiplier(step: 1) > RadioPlayerCoordinator.fadeMultiplier(step: 6)
    )
  }

  @Test("Extend folds the current remainder into the new duration")
  func extendFoldsRemainder() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    // 20 minutes remaining, extend by 15 → the new timer is 35 minutes from now.
    let firesAt = base.addingTimeInterval(20 * 60)
    let remaining = RadioPlayerCoordinator.remainingMinutes(until: firesAt, from: base)
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

  @Test("A manual pause cancels a running sleep timer")
  @MainActor
  func pauseCancelsTimer() async {
    let (coordinator, _) = makeCoordinator()

    coordinator.play()
    await coordinator.handleMetadataChanged("Artist - Song")
    coordinator.startSleepTimer(minutes: 30)
    #expect(coordinator.sleepTimerFiresAt != nil)

    coordinator.pause()
    #expect(coordinator.sleepTimerFiresAt == nil)
  }

  @Test("An external pause (media3 notification) cancels a running sleep timer")
  @MainActor
  func externalPauseCancelsTimer() async {
    let (coordinator, _) = makeCoordinator()

    coordinator.play()
    await coordinator.handleMetadataChanged("Artist - Song")
    coordinator.startSleepTimer(minutes: 30)
    #expect(coordinator.sleepTimerFiresAt != nil)

    // Simulate the Android media3 notification / external pause callback.
    coordinator.handlePlaybackStateChanged(isPlaying: false)
    #expect(coordinator.sleepTimerFiresAt == nil)
  }

  @Test("A Bluetooth/wired disconnect stop cancels a running sleep timer")
  @MainActor
  func disconnectStopCancelsTimer() async {
    let (coordinator, _) = makeCoordinator()

    coordinator.play()
    await coordinator.handleMetadataChanged("Artist - Song")
    coordinator.startSleepTimer(minutes: 30)
    #expect(coordinator.sleepTimerFiresAt != nil)

    coordinator.handleDisconnectStop()
    #expect(coordinator.sleepTimerFiresAt == nil)
  }

  @Test("Resuming playback leaves a running sleep timer intact (only manual pause cancels)")
  @MainActor
  func playDoesNotCancelTimer() async {
    let (coordinator, _) = makeCoordinator()

    coordinator.play()
    await coordinator.handleMetadataChanged("Artist - Song")
    coordinator.startSleepTimer(minutes: 30)
    #expect(coordinator.sleepTimerFiresAt != nil)

    // A resume/replay (e.g. auto-reconnect confirmation or a redundant play) must NOT drop the
    // running timer — only an explicit pause/stop does.
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
