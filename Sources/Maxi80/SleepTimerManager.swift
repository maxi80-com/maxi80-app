import Foundation
import Observation
import SkipFuse

private let logger = Logger(subsystem: "com.stormacq.maxi80", category: "SleepTimer")

/// Owns the sleep timer: when it fires, the fade-out ramp that precedes the stop, and the cancelable
/// task driving both.
///
/// Extracted from `RadioPlayerCoordinator` because it is genuinely self-contained — its only contact
/// with the rest of the coordinator is attenuating the player and calling back when it fires. The
/// static helpers were already `nonisolated static` for exactly that reason.
///
/// What deliberately did NOT move here is the "only settable while playing" gate: that reads
/// `playbackState`, which the coordinator owns. This type will arm a timer whenever asked; the
/// coordinator decides whether asking is allowed. Keeping the policy with the state it consults is
/// what lets this type stay ignorant of playback.
@MainActor
@Observable
final class SleepTimerManager {

  /// When the timer will fire, or `nil` when none is running. Storing the absolute fire *date*
  /// (rather than a countdown integer) makes the remaining time always computable fresh, so the
  /// countdown survives backgrounding/activity recreation without drift and needs no ticking state of
  /// its own. This is the single source of truth for both "is a timer running" and "how long is left".
  private(set) var firesAt: Date?

  @ObservationIgnored
  private let player: any AudioPlaying

  /// Called when the timer elapses and the fade has finished, so the coordinator can perform its own
  /// true-stop. Invoked on the main actor.
  ///
  /// Assigned after construction rather than injected, because the coordinator's handler captures
  /// `self` and so cannot exist while the coordinator's own stored properties are still being
  /// initialized. This mirrors how the coordinator wires the player's callbacks in `setupCallbacks()`.
  @ObservationIgnored
  var onFired: (() -> Void)?

  /// How long the fade-out runs before playback stops, in nanoseconds. Injectable so tests can drive
  /// the ramp in milliseconds; production keeps the 2.5s default.
  @ObservationIgnored
  private let fadeDuration: UInt64

  /// The running task: sleeps until the fire time, then fades out and stops playback. Cancelled by
  /// `cancel()` and superseded by `start(minutes:)`.
  @ObservationIgnored
  private var task: Task<Void, Never>?

  init(player: any AudioPlaying, fadeDuration: UInt64 = 2_500_000_000) {
    self.player = player
    self.fadeDuration = fadeDuration
  }

  // MARK: - Pure helpers
  //
  // `nonisolated static` so the arithmetic is unit-testable without real sleeping or a live manager.

  /// Number of attenuation steps across the fade. ~12 steps over ~2.5s is smooth without spinning.
  nonisolated static let fadeSteps = 12

  /// The attenuation multiplier at `step` (1…`fadeSteps`); the final step is `0.0` (silence).
  /// Pure/static so the fade ramp is unit-testable — a future change to `fadeSteps` can't silently
  /// leave a non-zero final multiplier (faded-but-audible on stop).
  nonisolated static func fadeMultiplier(step: Int) -> Double {
    1.0 - Double(step) / Double(fadeSteps)
  }

  /// Compute the absolute fire date for a timer of `minutes`, relative to `now`. Negative or zero
  /// durations clamp to `now` (fire immediately) rather than scheduling in the past.
  nonisolated static func fireDate(minutes: Int, from now: Date) -> Date {
    now.addingTimeInterval(TimeInterval(max(0, minutes) * 60))
  }

  /// Whole minutes remaining until `firesAt`, relative to `now`, rounded up so a partial final minute
  /// still counts (e.g. 90s left → 2 min). Never negative. Used by `extend(minutes:)` to fold the
  /// current remainder into the new duration.
  nonisolated static func remainingMinutes(until firesAt: Date, from now: Date) -> Int {
    let seconds = firesAt.timeIntervalSince(now)
    guard seconds > 0 else { return 0 }
    return Int((seconds / 60).rounded(.up))
  }

  // MARK: - Control

  /// Start (or restart) the timer for `minutes` from now. Playback fades out and `onFired` runs when
  /// it elapses. A stored cancelable `Task` with `Task.isCancelled` guards, so cancelling or extending
  /// mid-run supersedes this task cleanly.
  func start(minutes: Int) {
    task?.cancel()
    let firesAt = Self.fireDate(minutes: minutes, from: Date())
    self.firesAt = firesAt
    logger.info("sleep timer set for \(minutes) min (fires at \(firesAt))")

    task = Task { [weak self] in
      let interval = firesAt.timeIntervalSinceNow
      if interval > 0 {
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
      }
      if Task.isCancelled { return }
      guard let self else { return }
      await self.fire()
    }
  }

  /// Cancel a running timer and restore full playback volume. A no-op when none is running (so the
  /// fire path, which clears its own state first, doesn't re-enter it).
  func cancel() {
    guard firesAt != nil || task != nil else { return }
    task?.cancel()
    task = nil
    firesAt = nil
    player.setPlaybackAttenuation(1.0)
    logger.info("sleep timer cancelled")
  }

  /// Extend the running timer by `minutes`, folding in whatever time is currently left. A no-op when
  /// none is running (the UI only offers extend while active).
  func extend(minutes: Int) {
    guard let firesAt else { return }
    let remaining = Self.remainingMinutes(until: firesAt, from: Date())
    start(minutes: remaining + minutes)
  }

  /// Runs when the timer elapses: fade the output to silence, hand off to `onFired`, then restore
  /// attenuation for the next play. Clears `firesAt`/`task` up front so the observable "timer
  /// running" state ends the moment it fires. If playback was already stopped (the user paused
  /// earlier and never resumed), the fade and the stop are inaudible no-ops.
  private func fire() async {
    logger.info("sleep timer fired — fading out and stopping")
    firesAt = nil
    task = nil

    let stepDelay = fadeDuration / UInt64(Self.fadeSteps)
    for step in 1...Self.fadeSteps {
      if Task.isCancelled { player.setPlaybackAttenuation(1.0); return }
      player.setPlaybackAttenuation(Self.fadeMultiplier(step: step))
      try? await Task.sleep(nanoseconds: stepDelay)
    }

    onFired?()
    player.setPlaybackAttenuation(1.0)
  }
}
