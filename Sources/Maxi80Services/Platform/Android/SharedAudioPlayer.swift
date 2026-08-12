import Foundation

#if !SKIP_BRIDGE

  #if SKIP
    import androidx.media3.common.AudioAttributes
    import androidx.media3.common.C
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
        // Audio focus is configured HERE, at construction, not on each play. media3's
        // `ExoPlayer.Builder` never assigns `handleAudioFocus` (verified in 1.9.4:
        // `ExoPlayer.java`'s Builder ctor sets only `audioAttributes = AudioAttributes.DEFAULT`,
        // and `ExoPlayerImpl` passes `builder.handleAudioFocus` straight through), so it defaults
        // to FALSE. Configuring it from `androidPlay()` — the previous design — meant a player
        // started from ANY other entry point never requested focus at all: on an Android Auto cold
        // start `StopOnPausePlayer` drives this player directly and `androidPlay()` never runs, so
        // the stream decoded with no focus request. media3 reported READY + playWhenReady, so the
        // car rendered a playing button, but the car's audio policy routed no stream — playback was
        // "playing" and SILENT. (Tell-tale symptom: starting voice dictation forced a real focus
        // transaction and the already-running AudioTrack became briefly audible.) Building focus
        // into the player makes every path — in-app, car cold start, media button, auto-resume —
        // audible by construction, with no entry point left to forget it.
        let audioAttributes = AudioAttributes.Builder()
          .setUsage(C.USAGE_MEDIA)
          .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
          .build()
        let created = ExoPlayer.Builder(context)
          .setMediaSourceFactory(mediaSourceFactory)
          .setAudioAttributes(audioAttributes, /* handleAudioFocus: */ true)
          // Hold a network wake lock while playing so a backgrounded car session isn't stalled by
          // doze. media3 holds the lock only in READY/BUFFERING with playWhenReady, and releases it
          // on stop, so this costs nothing when idle. Requires WAKE_LOCK in the manifest.
          .setWakeMode(C.WAKE_MODE_NETWORK)
          .setHandleAudioBecomingNoisy(true)
          .build()
        player = created
        return created
      }

      /// The current shared player WITHOUT creating one — `nil` after `releaseShared()` until the
      /// next `shared()` rebuild. Consumed only by the defensive identity guards in
      /// `AudioStreamPlayer.androidPlay`/`androidStop`; kept coupled to them (remove together if
      /// those guards are ever dropped). Those guards are unreachable in the current design because
      /// the sole `releaseShared()` caller kills the process, so this is defense-in-depth.
      static var current: ExoPlayer? { player }

      /// Release and drop the shared player (service destroy / full teardown).
      static func releaseShared() {
        player?.release()
        player = nil
      }
    }
  #endif

#endif
