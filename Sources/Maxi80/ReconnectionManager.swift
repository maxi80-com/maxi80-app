import Foundation
import Maxi80Model
import Maxi80Services

/// Manages automatic reconnection with exponential backoff when the audio stream drops.
///
/// On stream drop, attempts reconnection up to 3 times with delays of 2s, 4s, 8s (2^n seconds).
/// If all attempts fail, transitions to error state. If any attempt succeeds, resets the counter
/// and transitions to playing. Manual retry resets the counter and starts fresh.
@MainActor
public final class ReconnectionManager {

    // MARK: - Configuration

    private let maxAttempts = 3

    // MARK: - State

    private var currentAttempt = 0
    private var reconnectTask: Task<Void, Never>?

    // MARK: - Callbacks

    /// Called when the playback state should change (e.g., `.reconnecting(attempt:)` or `.error`).
    public var onStateChanged: ((PlaybackState) -> Void)?

    /// Called to attempt a reconnection. Returns `true` if the reconnection succeeded.
    public var onReconnect: (() async -> Bool)?

    // MARK: - Public API

    /// Begin the reconnection sequence with exponential backoff.
    /// Each call to this method starts from the current attempt counter.
    public func startReconnection() {
        // Cancel any existing reconnection task
        reconnectTask?.cancel()

        reconnectTask = Task { [weak self] in
            guard let self else { return }

            while self.currentAttempt < self.maxAttempts {
                self.currentAttempt += 1
                let attempt = self.currentAttempt

                // Notify state: reconnecting with current attempt number
                self.onStateChanged?(.reconnecting(attempt))

                // Wait with exponential backoff: 2^attempt seconds
                let delayNanoseconds = self.delay(for: attempt)
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    // Task was cancelled — stop reconnection
                    return
                }

                // Check cancellation before attempting
                if Task.isCancelled { return }

                // Attempt reconnection
                let success = await self.onReconnect?() ?? false

                if Task.isCancelled { return }

                if success {
                    // Reconnection succeeded — reset counter
                    self.currentAttempt = 0
                    self.onStateChanged?(.playing)
                    return
                }
            }

            // All attempts exhausted — transition to error
            self.onStateChanged?(.error("Connection lost. All reconnection attempts failed."))
        }
    }

    /// Reset the reconnection counter and cancel any in-progress reconnection.
    /// Use this for manual retry — allows a fresh 3-attempt cycle.
    public func reset() {
        reconnectTask?.cancel()
        reconnectTask = nil
        currentAttempt = 0
    }

    /// Cancel any in-progress reconnection without resetting the counter.
    public func cancel() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    /// Calculate the delay for a given attempt number (1-indexed).
    /// Formula: 2^n seconds, yielding 2s, 4s, 8s for attempts 1, 2, 3.
    /// - Parameter attempt: The attempt number (1-indexed).
    /// - Returns: Delay in nanoseconds.
    public func delay(for attempt: Int) -> UInt64 {
        let seconds = pow(2.0, Double(attempt))
        return UInt64(seconds * 1_000_000_000)
    }
}
