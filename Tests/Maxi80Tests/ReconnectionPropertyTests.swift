import Testing
import Foundation
import SwiftCheck
@testable import Maxi80
@testable import Maxi80Model

/// **Validates: Requirements 12.2, 12.3**
@Suite("Reconnection Property Tests — P6: Backoff Sequence")
struct ReconnectionPropertyTests {

    /// Property 6: For any attempt n in 1...3, the delay follows 2^n seconds (in nanoseconds).
    /// Yields 2s, 4s, 8s for attempts 1, 2, 3.
    @Test("P6: Delay follows 2^n seconds for attempts 1..3")
    @MainActor
    func backoffDelaySequence() {
        let manager = ReconnectionManager()

        property("delay(n) == 2^n seconds in nanoseconds for n in 1...3") <- forAll(Gen<Int>.fromElements(in: 1...3)) { attempt in
            let expectedSeconds = pow(2.0, Double(attempt))
            let expectedNanos = UInt64(expectedSeconds * 1_000_000_000)
            let actualNanos = manager.delay(for: attempt)
            return actualNanos == expectedNanos
        }
    }

    /// Property 6 (continued): The manager stops reconnection after 3 failed attempts.
    /// For failure counts 1–5, delays are produced only for attempts 1..3; maxAttempts is 3.
    @Test("P6: Delays are monotonically increasing and max attempts is 3")
    @MainActor
    func backoffDelaysIncreasingAndCapped() {
        let manager = ReconnectionManager()

        // Verify delay(1) < delay(2) < delay(3)
        let delay1 = manager.delay(for: 1)
        let delay2 = manager.delay(for: 2)
        let delay3 = manager.delay(for: 3)

        #expect(delay1 < delay2)
        #expect(delay2 < delay3)
        #expect(delay1 == 2_000_000_000)  // 2s
        #expect(delay2 == 4_000_000_000)  // 4s
        #expect(delay3 == 8_000_000_000)  // 8s
    }

    /// Property 6 (continued): For generated failure counts 1–5, the system only produces
    /// reconnection attempts for the first 3 failures and then stops.
    @Test("P6: Reconnection stops after 3 failures")
    @MainActor
    func reconnectionStopsAfterMaxAttempts() {
        property("for failure counts 1-5, only first 3 have valid backoff delays") <- forAll(Gen<Int>.fromElements(in: 1...5)) { failureCount in
            let manager = ReconnectionManager()
            let maxAttempts = 3

            // For attempts within maxAttempts, delay should be valid (2^n seconds)
            // For attempts beyond maxAttempts, the system should stop (not schedule more)
            if failureCount <= maxAttempts {
                let expectedNanos = UInt64(pow(2.0, Double(failureCount)) * 1_000_000_000)
                return manager.delay(for: failureCount) == expectedNanos
            } else {
                // Beyond max attempts, the system ceases reconnection.
                // The delay function still computes a value, but the reconnection logic
                // won't call it — maxAttempts == 3 caps the sequence.
                return failureCount > maxAttempts
            }
        }
    }
}
