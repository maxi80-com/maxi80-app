import Foundation

#if !SKIP_BRIDGE

  #if SKIP
    import androidx.media3.datasource.DefaultHttpDataSource
    import androidx.media3.exoplayer.ExoPlayer
    import androidx.media3.exoplayer.source.DefaultMediaSourceFactory

    /// Holds the ONE long-lived ExoPlayer for the app's Android audio. Created once, kept for the
    /// service/process lifetime, and shared by playback (`AudioStreamPlayer`) and the media session/
    /// service — the media3-canonical topology so the car/notification control the audible player.
    enum SharedAudioPlayer {
      private static var player: ExoPlayer? = nil

      /// The single ExoPlayer, created on first use against the app context.
      ///
      /// Built with an ICY-metadata-enabled HTTP data source: SHOUTcast/Icecast streams (Maxi 80
      /// sends `icy-metaint`) push the current "ARTIST - TITLE" in-band, but ExoPlayer only requests
      /// and parses it when the HTTP source sends the `Icy-MetaData: 1` header. Without this the
      /// player captures the title only once, at prepare() time, and never sees subsequent live song
      /// changes — the app froze on the first song until the next prepare (pause/play). With ICY
      /// enabled the timed metadata surfaces through `Player.Listener.onMetadata` (IcyInfo) on every
      /// track change.
      static func shared(context: android.content.Context) -> ExoPlayer {
        if let existing = player { return existing }
        let httpDataSourceFactory = DefaultHttpDataSource.Factory()
          .setAllowCrossProtocolRedirects(true)
        let mediaSourceFactory = DefaultMediaSourceFactory(context)
          .setDataSourceFactory(httpDataSourceFactory)
        let created = ExoPlayer.Builder(context)
          .setMediaSourceFactory(mediaSourceFactory)
          .setHandleAudioBecomingNoisy(true)
          .build()
        player = created
        return created
      }

      /// Release and drop the shared player (service destroy / full teardown).
      static func releaseShared() {
        player?.release()
        player = nil
      }
    }
  #endif

#endif
