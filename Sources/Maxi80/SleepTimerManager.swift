import Foundation
import OSLog

/// Manages the sleep timer lifecycle: start, cancel, extend, and the fade-to-silence firing.
///
/// Extracted from `RadioPlayerCoordinator` (issue #68 item 1a) — encapsulates all timer state and
/// fade logic. Communicates back to the coordinator through closures so it remains independently
/// testable.
@MainActor @Observable
final class SleepTimerManager {

  // MARK: - Observable State

  /// The absolute date when the timer will fire, or `nil` when no timer is active.
  private(set) var firesAt: Date?

  // MARK: - Configuration

  /// How long the fade-out runs before playback stops, in nanoseconds.
  private static let fadeDurationNanos: UInt64 = 2_500_000_000
  /// Number of attenuation steps across the fade. ~12 steps over ~2.5s is smooth without spinning.
  nonisolated private static let fadeSteps = 12

  // MARK: - Private State

  private var timerTask: Task<Void, Never>?
  private let logger = Logger(subsystem: "com.maxi80", category: "SleepTimerManager")

  // MARK: - Pure/Static Helpers (unit-testable)

  /// The attenuation multiplier at `step` (1…`fadeSteps`); the final step is `0.0` (silence).
  nonisolated static func fadeMultiplier(step: Int) -> Double {
    1.0 - Double(step) / Double(fadeSteps)
  }

  /// Compute the absolute fire date for a timer of `minutes`, relative to `now`.
  nonisolated static func sleepTimerFireDate(minutes: Int, from now: Date) -> Date {
    now.addingTimeInterval(TimeInterval(max(0, minutes) * 60))
  }

  /// Whole minutes remaining until `firesAt`, relative to `now`, rounded up.
  nonisolated static func remainingMinutes(until firesAt: Date, from now: Date) -> Int {
    let seconds = firesAt.timeIntervalSince(now)
    guard seconds > 0 else { return 0 }
    return Int((seconds / 60).rounded(.up))
  }

  // MARK: - Public API

  /// Start (or restart) the sleep timer for `minutes` from now.
  ///
  /// - Parameters:
  ///   - minutes: Duration in minutes before playback stops.
  ///   - isPlaying: Whether playback is currently active (timer is only valid while playing).
  ///   - setAttenuation: Closure to adjust player volume (0.0–1.0).
  ///   - onFired: Closure called when the timer fires (after fade-out). Typically stops playback.
  func start(
    minutes: Int,
    isPlaying: Bool,
    setAttenuation: @escaping (Double) -> Void,
    onFired: @escaping () -> Void
  ) {
    guard isPlaying else {
      logger.info("ignoring sleep timer request while not playing")
      return
    }
    timerTask?.cancel()
    let fireDate = Self.sleepTimerFireDate(minutes: minutes, from: Date())
    firesAt = fireDate
    logger.info("sleep timer set for \(minutes) min (fires at \(fireDate))")

    timerTask = Task { [weak self] in
      let interval = fireDate.timeIntervalSinceNow
      if interval > 0 {
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
      }
      if Task.isCancelled { return }
      guard let self else { return }
      await self.fire(setAttenuation: setAttenuation, onFired: onFired)
    }
  }

  /// Cancel the running timer and restore full volume.
  func cancel(setAttenuation: @escaping (Double) -> Void) {
    guard firesAt != nil || timerTask != nil else { return }
    timerTask?.cancel()
    timerTask = nil
    firesAt = nil
    setAttenuation(1.0)
    logger.info("sleep timer cancelled")
  }

  /// Extend the running timer by `minutes`, folding in whatever time is currently left.
  func extend(
    minutes: Int,
    isPlaying: Bool,
    setAttenuation: @escaping (Double) -> Void,
    onFired: @escaping () -> Void
  ) {
    guard let fireDate = firesAt else { return }
    let remaining = Self.remainingMinutes(until: fireDate, from: Date())
    start(minutes: remaining + minutes, isPlaying: isPlaying, setAttenuation: setAttenuation, onFired: onFired)
  }

  // MARK: - Private

  private func fire(setAttenuation: @escaping (Double) -> Void, onFired: @escaping () -> Void) async {
    logger.info("sleep timer fired — fading out and stopping")
    firesAt = nil
    timerTask = nil

    let stepDelay = Self.fadeDurationNanos / UInt64(Self.fadeSteps)
    for step in 1...Self.fadeSteps {
      if Task.isCancelled { setAttenuation(1.0); return }
      setAttenuation(Self.fadeMultiplier(step: step))
      try? await Task.sleep(nanoseconds: stepDelay)
    }

    onFired()
    setAttenuation(1.0)
  }
}
