import Foundation

#if !SKIP_BRIDGE

  #if SKIP
    import android.net.Uri
    import androidx.media3.common.MediaItem
    import androidx.media3.common.MediaMetadata
    import skip.foundation.ProcessInfo

    // MARK: - AndroidNowPlayingController (Android Implementation)

    extension NowPlayingController {

      private var context: android.content.Context {
        ProcessInfo.processInfo.androidContext
      }

      // MARK: - Now Playing Metadata

      /// Update the MediaSession metadata with current track information.
      /// The session is hosted by Maxi80MediaService; this method publishes metadata to the shared
      /// player, which the service's session reflects automatically.
      func platformUpdateNowPlaying(
        artist: String, title: String, artworkURL: String?, isPlaying: Bool
      ) {
        let metadata = MediaMetadata.Builder()
          .setTitle(title)
          .setArtist(artist)
        if let urlString = artworkURL, !urlString.isEmpty {
          _ = metadata.setArtworkUri(android.net.Uri.parse(urlString))
        } else {
          // No live cover: fall back to the bundled station logo rather than clearing artwork,
          // so a coverless song does not flicker the card to no-art. Mirrors the initial MediaItem
          // built in ExoPlayerStreamPlayer.androidPlay() and Maxi80MediaService.stationArtworkUri().
          // `drawable/media_placeholder` is a dedicated 1024px raster PNG (NOT the small
          // ic_launcher_foreground, and NOT the ic_launcher adaptive-icon XML which media3's
          // RawResourceDataSource can't rasterize — issue #41): high-res so Android Auto's large
          // artwork surface stays crisp instead of pixelated.
          _ = metadata.setArtworkUri(
            android.net.Uri.parse(
              "android.resource://\(context.packageName)/drawable/media_placeholder")
          )
        }
        // Apply to the shared player's current item so the service's session (and notification,
        // lock screen, later the car) see live metadata automatically.
        let player = SharedAudioPlayer.shared(context: context)
        guard let current = player.getCurrentMediaItem() else { return }
        let updated = current.buildUpon()
          .setMediaMetadata(metadata.build())
          .build()
        player.replaceMediaItem(player.getCurrentMediaItemIndex(), updated)
      }

      // MARK: - Playback State

      /// Update playback state on the MediaSession.
      func platformUpdatePlaybackState(isPlaying: Bool) {
        // No-op: the MediaSession reflects the shared player's own play/pause state (set in
        // ExoPlayerStreamPlayer). Retained for API parity with iOS's MPNowPlayingInfoCenter path.
      }

      // MARK: - Remote Command Handling

      func handleRemoteCommand(_ command: String) {
        let callback = onRemoteCommand
        if let callback = callback {
          callback(command)
        }
      }

      // MARK: - Session Lifecycle

      /// Release resources. The MediaSession is released by Maxi80MediaService.onDestroy();
      /// the shared player is released by SharedAudioPlayer.releaseShared() there as well.
      func platformTearDown() {
        // Nothing to do here — session and player lifecycle owned by Maxi80MediaService.
      }
    }

  #else
    // iOS implementation is in IOSNowPlayingController.swift
  #endif

#endif  // !SKIP_BRIDGE
