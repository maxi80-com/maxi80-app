import Foundation

/* SKIP @bridge */
#if !SKIP_BRIDGE
  public final class NowPlayingController {
    /// Callback invoked when remote command received from lock screen/notification.
    /// Values: "play", "pause", "togglePlayPause"
    public var onRemoteCommand: ((String) -> Void)?

    public init() {}

    /// Update the published now-playing metadata.
    public func updateNowPlaying(
      artist: String, title: String, artworkURL: String?, isPlaying: Bool
    ) {
      #if SKIP
        platformUpdateNowPlaying(
          artist: artist, title: title, artworkURL: artworkURL, isPlaying: isPlaying)
      #elseif os(iOS) || os(tvOS)
        platformUpdateNowPlaying(
          artist: artist, title: title, artworkURL: artworkURL, isPlaying: isPlaying)
      #endif
    }

    /// Update only the playback state (rate: 1.0 playing, 0.0 paused).
    public func updatePlaybackState(isPlaying: Bool) {
      #if SKIP
        platformUpdatePlaybackState(isPlaying: isPlaying)
      #elseif os(iOS) || os(tvOS)
        platformUpdatePlaybackState(isPlaying: isPlaying)
      #endif
    }

    /// Tear down the media session and release resources.
    public func tearDown() {
      #if SKIP
        platformTearDown()
      #elseif os(iOS) || os(tvOS)
        platformTearDown()
      #endif
    }
  }
#endif
