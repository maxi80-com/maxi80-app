import Foundation

public enum PlaybackState: Sendable {
    case idle
    case loading
    case playing
    case paused
    case error(String)
    case reconnecting(Int)
}
