import Foundation

public enum PlaybackState: Sendable, Equatable {
  case idle
  case loading
  case playing
  case paused
  case error(String)
  case reconnecting(Int)
}

extension PlaybackState {
  /// Whether playback is currently active.
  public var isPlaying: Bool {
    if case .playing = self { return true }
    return false
  }
}
