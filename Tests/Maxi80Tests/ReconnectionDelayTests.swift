import Foundation
import Testing

@testable import Maxi80
@testable import Maxi80Model

/// Pins the arithmetic safety of `ReconnectionManager`'s backoff conversion.
///
/// `delay(for:)` turns `Double` seconds into `UInt64` nanoseconds, and both of its inputs
/// (`timeScale` on a `public init`, `attempt` on a `public` method) come from outside the type.
/// An unguarded `UInt64(_:)` conversion traps — not throws — on a negative, NaN, or overflowing
/// operand, so these cases are asserted rather than left to a crash on a device.
/// Deliberately free of SwiftCheck so this suite also runs in the Android test build, where
/// `*PropertyTests.swift` files are excluded from the target.
@Suite("Reconnection backoff delay conversion")
struct ReconnectionDelayTests {

  // MARK: - The production ladder is unchanged

  @Test("Default scale keeps the 2s/4s/8s ladder")
  @MainActor
  func defaultScaleProducesProductionLadder() {
    let manager = ReconnectionManager()

    #expect(manager.delay(for: 1) == 2_000_000_000)
    #expect(manager.delay(for: 2) == 4_000_000_000)
    #expect(manager.delay(for: 3) == 8_000_000_000)
  }

  @Test("A fractional scale shortens delays without changing the 2^n shape")
  @MainActor
  func fractionalScalePreservesShape() {
    let manager = ReconnectionManager(timeScale: 0.001)

    #expect(manager.delay(for: 1) == 2_000_000)
    #expect(manager.delay(for: 2) == 4_000_000)
    #expect(manager.delay(for: 3) == 8_000_000)
  }

  // MARK: - Out-of-range timeScale is clamped instead of trapping

  @Test("A negative time scale clamps to an immediate delay")
  @MainActor
  func negativeTimeScaleClampsToZero() {
    let manager = ReconnectionManager(timeScale: -1.0)

    // The unclamped expression is `-2 * 1_000_000_000`, which traps in `UInt64(_:)`.
    for attempt in 1...3 {
      #expect(manager.delay(for: attempt) == 0)
    }
  }

  @Test("A NaN time scale clamps to an immediate delay")
  @MainActor
  func nanTimeScaleClampsToZero() {
    let manager = ReconnectionManager(timeScale: .nan)

    #expect(manager.delay(for: 1) == 0)
  }

  @Test("An infinite time scale saturates instead of trapping")
  @MainActor
  func infiniteTimeScaleSaturates() {
    #expect(ReconnectionManager(timeScale: .infinity).delay(for: 1) == 0)
    #expect(ReconnectionManager(timeScale: -.infinity).delay(for: 1) == 0)
  }

  @Test("A zero time scale yields no delay")
  @MainActor
  func zeroTimeScaleYieldsNoDelay() {
    #expect(ReconnectionManager(timeScale: 0).delay(for: 3) == 0)
  }

  // MARK: - Out-of-range attempt saturates instead of trapping

  @Test("A huge attempt number saturates at UInt64.max")
  @MainActor
  func hugeAttemptSaturates() {
    let manager = ReconnectionManager()

    // 2^64 seconds in nanoseconds overflows UInt64; the guard must saturate.
    #expect(manager.delay(for: 64) == .max)
    #expect(manager.delay(for: 4096) == .max)
  }

  @Test("A large time scale saturates rather than overflowing")
  @MainActor
  func largeTimeScaleSaturates() {
    let manager = ReconnectionManager(timeScale: .greatestFiniteMagnitude)

    #expect(manager.delay(for: 1) == .max)
  }

  @Test("Delays stay monotonically non-decreasing across the production ladder")
  @MainActor
  func delaysAreMonotonic() {
    let manager = ReconnectionManager()

    #expect(manager.delay(for: 1) < manager.delay(for: 2))
    #expect(manager.delay(for: 2) < manager.delay(for: 3))
  }
}
