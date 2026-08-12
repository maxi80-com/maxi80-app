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
        artist: String, title: String, artworkURL: String?, artworkAssetName: String?,
        isPlaying: Bool
      ) {
        let metadata = MediaMetadata.Builder()
          .setTitle(title)
          .setArtist(artist)
        if let urlString = artworkURL, !urlString.isEmpty {
          _ = metadata.setArtworkUri(android.net.Uri.parse(urlString))
        } else if let assetName = artworkAssetName,
          let drawable = Self.androidDrawableName(for: assetName)
        {
          // The song's own generic cover, shipped as an Android drawable (issue #80). Android has no
          // platform image APIs, so the coordinator cannot materialize a file:// URL for it the way
          // Apple does — it passes the asset NAME and we resolve the drawable here. Without this the
          // card fell through to the station logo below while the carousel showed a per-song cover.
          _ = metadata.setArtworkUri(
            android.net.Uri.parse(
              "android.resource://\(context.packageName)/drawable/\(drawable)"))
        } else {
          // Genuinely nothing to show (no song yet): the bundled station logo rather than clearing
          // artwork, so the card does not flicker to no-art. Mirrors the initial MediaItem built in
          // ExoPlayerStreamPlayer.androidPlay() and Maxi80MediaService.stationArtworkUri().
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

      /// Map a bundled cover asset name (`NoCover-25ans-2`) to its Android drawable resource name
      /// (`nocover_25ans_2`). Android resource names allow only lowercase, digits and underscores,
      /// so the asset catalog's mixed case and hyphens are normalized. Returns nil for a name with
      /// no shipped drawable, so the caller falls back to the station logo rather than publishing a
      /// URI that media3 cannot resolve.
      static func androidDrawableName(for assetName: String) -> String? {
        let normalized = assetName.lowercased().replacingOccurrences(of: "-", with: "_")
        return normalized.hasPrefix("nocover_") ? normalized : nil
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
