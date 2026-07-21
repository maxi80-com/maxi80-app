import Foundation

#if !SKIP_BRIDGE

  #if SKIP
    import android.content.Context
    import androidx.media3.common.AudioAttributes
    import androidx.media3.common.C
    import androidx.media3.common.Metadata
    import androidx.media3.common.MediaItem
    import androidx.media3.common.Player
    import androidx.media3.exoplayer.ExoPlayer
    import androidx.media3.extractor.metadata.icy.IcyInfo
    import skip.foundation.ProcessInfo

    // MARK: - Named Listener for Metadata Changes

    class MetadataPlayerListener: Player.Listener {
      private let player: AudioStreamPlayer

      init(player: AudioStreamPlayer) {
        self.player = player
      }

      /// Live song changes arrive here as timed in-band ICY metadata (the shared player is built with
      /// an ICY-enabled data source — see SharedAudioPlayer). `IcyInfo.title` is the whole
      /// "ARTIST - TITLE" line, which the coordinator splits with MetadataParser.
      ///
      /// Metadata is read ONLY from this callback, never from `onMediaMetadataChanged`: our own
      /// now-playing writeback (platformUpdateNowPlaying → replaceMediaItem) re-fires
      /// `onMediaMetadataChanged` but not `onMetadata`, so consuming ICY here avoids the writeback
      /// echo entirely.
      override func onMetadata(metadata: Metadata) {
        var index = 0
        while index < metadata.length() {
          if let icyInfo = metadata.get(index) as? IcyInfo,
            let title = icyInfo.title, !title.isEmpty
          {
            player.handleMetadataChanged(title)
          }
          index += 1
        }
      }

      override func onPlaybackStateChanged(playbackState: Int) {
        if playbackState == Player.STATE_READY {
          player.isPlaying = true
          player.onPlaybackStateChanged?(true)
        } else if playbackState == Player.STATE_ENDED || playbackState == Player.STATE_IDLE {
          player.isPlaying = false
          player.onPlaybackStateChanged?(false)
        }
      }

      override func onIsPlayingChanged(isCurrentlyPlaying: Bool) {
        player.isPlaying = isCurrentlyPlaying
        player.onPlaybackStateChanged?(isCurrentlyPlaying)
      }

      override func onPlayWhenReadyChanged(playWhenReady: Bool, reason: Int) {
        if !playWhenReady && (reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS
          || reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY)
        {
          player.isPlaying = false
          player.onPlaybackStateChanged?(false)
          player.onInterruption?(true)
        }
      }

      override func onPlaybackSuppressionReasonChanged(playbackSuppressionReason: Int) {
        if playbackSuppressionReason == Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS {
          player.isPlaying = false
          player.onPlaybackStateChanged?(false)
          player.onInterruption?(true)
        } else if playbackSuppressionReason == Player.PLAYBACK_SUPPRESSION_REASON_NONE && player._exoPlayer?.playWhenReady == true {
          player.isPlaying = true
          player.onPlaybackStateChanged?(true)
          player.onInterruption?(false)
        }
      }
    }

    // MARK: - ExoPlayerStreamPlayer (Android Implementation)

    extension AudioStreamPlayer {

      // MARK: - Private Storage (stored in the class, accessible from extension)
      // Note: These are declared as vars in the class body via a separate section below.

      private var context: Context {
        ProcessInfo.processInfo.androidContext
      }

      // MARK: - Playback Control

      func androidPlay(url streamUrl: String) {
        let ctx = context
        let exoPlayer = SharedAudioPlayer.shared(context: ctx)
        self._exoPlayer = exoPlayer

        // Configure ExoPlayer to manage audio focus internally. This is idempotent — calling it
        // again on the same player instance with the same attributes is a no-op. ExoPlayer will
        // request focus on play(), duck/pause on transient loss, and resume on regain. This
        // replaces the previous manual AudioFocusRequest management which could leave orphaned
        // focus requests that cause the system to immediately fire AUDIOFOCUS_LOSS back, wedging
        // the player permanently.
        if !_audioAttributesConfigured {
          let audioAttributes = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
            .build()
          exoPlayer.setAudioAttributes(audioAttributes, /* handleAudioFocusInternally: */ true)
          _audioAttributesConfigured = true
        }

        // Re-attach the metadata listener if it isn't currently on this player instance. The
        // listener reference is cleared on stop, and the shared player can be rebuilt after a full
        // teardown, so guarding on nil alone would leave a rebuilt player with no listener — which
        // stalls the coordinator in `.loading` (spinner never clears because no metadata arrives).
        if _metadataListener == nil {
          let listener = MetadataPlayerListener(player: self)
          self._metadataListener = listener
          exoPlayer.addListener(listener)
        }

        // If the player was merely paused (transient focus loss, user pause, becoming-noisy),
        // it still holds the live stream item in STATE_READY. Just flip playWhenReady back on —
        // ExoPlayer re-requests audio focus internally and resumes instantly. Reloading the media
        // item would reset the player to STATE_IDLE and force a full reconnect to the stream server.
        let currentState = exoPlayer.getPlaybackState()
        if currentState == Player.STATE_READY || currentState == Player.STATE_BUFFERING {
          exoPlayer.playWhenReady = true
          isPlaying = true
          onPlaybackStateChanged?(true)
        } else {
          // Cold start or player was in STATE_IDLE/STATE_ENDED: load the stream from scratch.
          let mediaItem = MediaItem.fromUri(streamUrl)
          exoPlayer.setMediaItem(mediaItem)
          exoPlayer.prepare()
          exoPlayer.playWhenReady = true
          isPlaying = true
          onPlaybackStateChanged?(true)
        }

        // Start the foreground MediaSessionService so the media notification appears and
        // playback survives Activity destruction (background / lock-screen). startForegroundService
        // is idempotent — if the service is already running, this just delivers a start command.
        let serviceIntent = android.content.Intent()
        serviceIntent.setClassName(ctx, "maxi80.services.Maxi80MediaService")
        ctx.startForegroundService(serviceIntent)
      }

      func androidStop() {
        // Pause, do NOT tear down. The player and the foreground service are long-lived (the
        // media3-canonical topology): a live-radio "pause" just halts output on the single shared
        // player. ExoPlayer internally abandons audio focus when playWhenReady becomes false.
        _exoPlayer?.playWhenReady = false
        isPlaying = false
        onPlaybackStateChanged?(false)
      }

      func androidSetVolume(_ newVolume: Double) {
        volume = newVolume
        _exoPlayer?.volume = Float(newVolume)
      }

      // MARK: - Metadata Handling

      func handleMetadataChanged(_ rawMetadata: String) {
        let callback = onMetadataChanged
        if let callback = callback {
          callback(rawMetadata)
        }
      }

      // MARK: - Private Storage

      var _exoPlayer: ExoPlayer? = nil
      var _metadataListener: MetadataPlayerListener? = nil
      var _audioAttributesConfigured: Bool = false
    }

  #else
    // iOS implementation is in AVPlayerStreamPlayer.swift
  #endif

#endif  // !SKIP_BRIDGE
