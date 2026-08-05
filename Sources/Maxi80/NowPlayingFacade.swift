import Foundation
import Maxi80Services

/// Consolidates the modern NowPlaying framework (iOS 26+) and the bridged MediaPlayer
/// `NowPlayingController` into a single publish interface, eliminating the repeated
/// `#if !SKIP` / `if let modernNowPlaying` branching from the coordinator.
///
/// Extracted from `RadioPlayerCoordinator` (issue #68 item 1c).
@MainActor
final class NowPlayingFacade {

  #if !SKIP
    private let modern: (any NowPlayingPublishing)?
  #endif
  private let fallback: NowPlayingController

  init(
    fallback: NowPlayingController,
    onPlay: @escaping () -> Void,
    onPause: @escaping () -> Void
  ) {
    self.fallback = fallback
    #if !SKIP
      self.modern = makeModernNowPlaying(onPlay: onPlay, onPause: onPause)
    #endif
  }

  /// Whether the facade is using the modern framework (for conditional logic outside).
  var usesModernFramework: Bool {
    #if !SKIP
      return modern != nil
    #else
      return false
    #endif
  }

  /// Publish track metadata to the system Now Playing info (Lock Screen, Control Center, CarPlay).
  func publish(
    artist: String,
    title: String,
    stationName: String,
    artworkURL: String?,
    isPlaying: Bool
  ) {
    #if !SKIP
      if let modern {
        modern.activate()
        modern.update(
          stationName: stationName,
          programName: "\(title) — \(artist)",
          artworkURL: artworkURL,
          isPlaying: isPlaying
        )
        return
      }
    #endif
    fallback.updateNowPlaying(
      artist: artist, title: title, artworkURL: artworkURL, isPlaying: isPlaying)
  }

  /// Publish only the play/pause state change.
  func publishState(isPlaying: Bool) {
    #if !SKIP
      if let modern {
        modern.updatePlaybackState(isPlaying: isPlaying)
        return
      }
    #endif
    fallback.updatePlaybackState(isPlaying: isPlaying)
  }
}
