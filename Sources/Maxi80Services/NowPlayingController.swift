import Foundation

/* SKIP @bridge */
#if !SKIP_BRIDGE
  public final class NowPlayingController {
    /// Callback invoked when remote command received from lock screen/notification.
    /// Values: "play", "pause", "togglePlayPause"
    public var onRemoteCommand: ((String) -> Void)?

    public init() {}

    /// Update the published now-playing metadata.
    ///
    /// `artworkAssetName` names the bundled generic cover the app is displaying, for platforms that
    /// cannot be handed a URL for it: Android has no image APIs to materialize one, so the Android
    /// implementation resolves this name to an `android.resource://…/drawable/…` URI (issue #80).
    /// Apple already receives a materialized `file://` URL in `artworkURL` and ignores it.
    public func updateNowPlaying(
      artist: String, title: String, artworkURL: String?, artworkAssetName: String?,
      isPlaying: Bool
    ) {
      #if SKIP
        platformUpdateNowPlaying(
          artist: artist, title: title, artworkURL: artworkURL,
          artworkAssetName: artworkAssetName, isPlaying: isPlaying)
      #elseif os(iOS) || os(tvOS)
        platformUpdateNowPlaying(
          artist: artist, title: title, artworkURL: artworkURL,
          artworkAssetName: artworkAssetName, isPlaying: isPlaying)
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
