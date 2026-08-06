import Foundation

public enum PlaybackState: Sendable, Equatable {
  case idle
  case loading
  case playing
  case paused
  case error(String)
  case reconnecting(Int)

  /// Whether audio is playing. The state machine has several non-playing cases, so callers that
  /// only need the yes/no answer read this instead of re-writing the `if case .playing` pattern —
  /// which appeared at four sites (coordinator republish/artwork-retry, view model `isPlaying`)
  /// before it lived here, each an independent chance to get the case list wrong.
  public var isPlaying: Bool {
    if case .playing = self { return true }
    return false
  }

  /// Whether a connection attempt is in flight — the states that show a spinner rather than a
  /// transport glyph. `.reconnecting` counts: from the user's point of view the app is still trying
  /// to start audio.
  public var isLoading: Bool {
    switch self {
    case .loading, .reconnecting:
      return true
    default:
      return false
    }
  }
}
