// Sources/Maxi80/Services/BridgedNowPlayingPublisher.swift
import Foundation
import Maxi80Services

/// Publishes Now Playing info through the bridged `NowPlayingController` — MediaPlayer
/// (`MPNowPlayingInfoCenter`) on Apple platforms, the media3 `MediaSession` on Android.
///
/// This is the fallback path where the modern NowPlaying framework is unavailable, and the ONLY
/// path on Android. Exists so the coordinator can hold a single `any NowPlayingPublishing` instead
/// of branching on `#if !SKIP` at every publish site.
@MainActor
final class BridgedNowPlayingPublisher: NowPlayingPublishing {
  /// Internal, not private: the composition root reads it to wire `onRemoteCommand`, and holding
  /// this publisher is what keeps the controller alive for the process.
  let controller: NowPlayingController

  init(controller: NowPlayingController) {
    self.controller = controller
  }

  /// No-op: the MediaPlayer info center and the Android MediaSession are both implicitly active —
  /// there is no separate activation step to mirror the modern framework's.
  func activate() {}

  /// `stationName` is unused here: the bridged surface carries artist/title directly, whereas the
  /// modern framework models a station with a current program.
  func update(
    stationName: String, artist: String, title: String, artworkURL: String?, isPlaying: Bool
  ) {
    controller.updateNowPlaying(
      artist: artist, title: title, artworkURL: artworkURL, isPlaying: isPlaying)
  }

  func updatePlaybackState(isPlaying: Bool) {
    controller.updatePlaybackState(isPlaying: isPlaying)
  }
}
