import Foundation

#if !SKIP_BRIDGE

  #if SKIP
    import android.content.Context
    import android.database.ContentObserver
    import android.media.AudioManager
    import android.os.Handler
    import android.os.Looper
    import android.provider.Settings
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

    // MARK: - Named ContentObserver for System Volume Changes

    /// Observes changes to the system audio settings and reports the current STREAM_MUSIC level
    /// back to the player. This is what lets the in-app volume bar track the hardware volume
    /// buttons (and any other source that changes the media volume, e.g. the system volume panel):
    /// the buttons adjust STREAM_MUSIC, this observer fires, and the player forwards the new level.
    class VolumeContentObserver: ContentObserver {
      private let player: AudioStreamPlayer

      init(player: AudioStreamPlayer, handler: Handler) {
        self.player = player
        super.init(handler)
      }

      override func onChange(selfChange: Bool) {
        player.handleSystemVolumeChanged()
      }
    }

    // MARK: - ExoPlayerStreamPlayer (Android Implementation)

    extension AudioStreamPlayer {

      // MARK: - Private Storage (stored in the class, accessible from extension)
      // Note: These are declared as vars in the class body via a separate section below.

      private var context: Context {
        ProcessInfo.processInfo.androidContext
      }

      private var audioManager: AudioManager {
        context.getSystemService(Context.AUDIO_SERVICE) as! AudioManager
      }

      // MARK: - Playback Control

      func androidPlay(url streamUrl: String) {
        let ctx = context
        let exoPlayer = SharedAudioPlayer.shared(context: ctx)

        // Defensive (same reachability caveat as androidStop below): if the shared player had been
        // torn down (releaseShared()) while the process survived, our cached _metadataListener would
        // point at the RELEASED player while shared() above rebuilt a fresh one. Detect that by
        // IDENTITY (not nil — current is non-nil again after the rebuild) and drop the stale listener,
        // so the `_metadataListener == nil` guard below re-attaches it to the new player instead of
        // leaving the coordinator stalled in `.loading`. Not reachable in the current design (the sole
        // releaseShared() caller, onTaskRemoved, kills the process); kept as defense-in-depth.
        if _exoPlayer !== exoPlayer {
          _metadataListener = nil
        }
        self._exoPlayer = exoPlayer

        // Configure ExoPlayer to manage audio focus internally. Called unconditionally on every
        // play: setAudioAttributes with unchanged attributes is idempotent, and doing it here
        // guarantees focus handling is (re)wired against whatever ExoPlayer instance is current —
        // even one rebuilt after SharedAudioPlayer.releaseShared(). A per-AudioStreamPlayer
        // "already configured" flag could go stale against a fresh player and silently skip this,
        // bringing back the permanent-wedge bug. ExoPlayer then requests focus on play(), ducks/
        // pauses on transient loss, and resumes on regain — replacing the manual AudioFocusRequest
        // management that could leave orphaned requests, making the system immediately fire
        // AUDIOFOCUS_LOSS back and wedge the player permanently.
        let audioAttributes = AudioAttributes.Builder()
          .setUsage(C.USAGE_MEDIA)
          .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
          .build()
        exoPlayer.setAudioAttributes(audioAttributes, /* handleAudioFocusInternally: */ true)

        // Attach the metadata listener once. The shared player can be rebuilt after a full teardown
        // (SharedAudioPlayer.releaseShared()), so we guard on nil rather than assuming it's always
        // present: a rebuilt player with no listener would stall the coordinator in `.loading` (the
        // spinner never clears because no ICY metadata arrives).
        if _metadataListener == nil {
          let listener = MetadataPlayerListener(player: self)
          self._metadataListener = listener
          exoPlayer.addListener(listener)
        }

        // Live radio: ALWAYS (re)load the stream so play reconnects to the LIVE edge. We must not
        // reuse a buffered STATE_READY player — for a live stream its retained buffer is whatever
        // was playing when the user stopped, so resuming it plays a stale track (e.g. Android kept
        // playing an old song while the live stream had moved on). `androidStop()` clears the media
        // item and drops the player to STATE_IDLE precisely so this path always does a fresh
        // setMediaItem + prepare, matching the Apple side (which replaces the AVPlayerItem on play).
        // ExoPlayer re-requests audio focus internally on prepare/play.
        let mediaItem = MediaItem.fromUri(streamUrl)
        exoPlayer.setMediaItem(mediaItem)
        exoPlayer.prepare()
        exoPlayer.playWhenReady = true
        isPlaying = true
        onPlaybackStateChanged?(true)

        // Start the foreground MediaSessionService so the media notification appears and
        // playback survives Activity destruction (background / lock-screen). startForegroundService
        // is idempotent — if the service is already running, this just delivers a start command.
        let serviceIntent = android.content.Intent()
        serviceIntent.setClassName(ctx, "maxi80.services.Maxi80MediaService")
        ctx.startForegroundService(serviceIntent)
      }

      func androidStop() {
        // Live radio: a "stop" must truly STOP, not pause. `stop()` halts loading and releases the
        // buffer; `clearMediaItems()` drops the player to STATE_IDLE so there is no retained stream
        // to resume. The next `androidPlay()` therefore always reloads and reconnects to the live
        // edge instead of resuming a now-stale buffer. ExoPlayer internally abandons audio focus
        // when playback stops. The shared player instance and the foreground service stay alive
        // (media3-canonical topology) — only the media item/buffer is cleared.
        //
        // Defensive: guard against a cached _exoPlayer that references a RELEASED instance — the
        // static player being nil, or rebuilt to a DIFFERENT instance by a later shared() call —
        // where calling stop() would throw "sending message to a Handler on a dead thread".
        //
        // In the CURRENT design this is not reachable: the only caller of releaseShared() is the
        // service's onTaskRemoved, which kills the process on the next line, so no warm process
        // outlives a released player to reach here. This guard is kept purely as defense-in-depth —
        // killProcess() is best-effort, and a future second caller of releaseShared() could
        // reintroduce warm teardown. Operate ONLY when our cache is still the live shared player
        // (identity match); otherwise drop the stale references and just reconcile local state.
        if let cached = _exoPlayer, cached === SharedAudioPlayer.current {
          cached.stop()
          cached.clearMediaItems()
        } else {
          _exoPlayer = nil
          _metadataListener = nil
        }
        isPlaying = false
        onPlaybackStateChanged?(false)
      }

      // MARK: - System Volume (STREAM_MUSIC)
      //
      // The in-app slider controls the system media volume (STREAM_MUSIC), NOT ExoPlayer's private
      // volume attenuation. This mirrors iOS's MPVolumeView (which drives the system output level)
      // and means the hardware volume buttons and the in-app bar are the SAME volume — so they
      // always agree. ExoPlayer's own `volume` stays at 1.0 and is used only for transient ducking.

      func androidSetVolume(_ newVolume: Double) {
        // Clamp to the valid 0.0–1.0 range (and treat NaN as 0) so the stream-step conversion below
        // can never produce a negative, out-of-range, or NaN index — Int(NaN) traps, and an
        // out-of-range step makes setStreamVolume clamp unpredictably.
        let clamped = newVolume.isNaN ? 0.0 : min(max(newVolume, 0.0), 1.0)
        volume = clamped
        let am = audioManager
        let maxVolume = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        let target = Int((clamped * Double(maxVolume)).rounded())
        // No FLAG_SHOW_UI: the app has its own on-screen bar, so suppress the system volume panel
        // to avoid showing two indicators at once when the user drags the in-app slider.
        am.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
      }

      /// The current STREAM_MUSIC level as a 0.0–1.0 fraction of its maximum.
      func androidCurrentVolume() -> Double {
        let am = audioManager
        let maxVolume = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        guard maxVolume > 0 else { return 0 }
        return Double(am.getStreamVolume(AudioManager.STREAM_MUSIC)) / Double(maxVolume)
      }

      /// Called by the ContentObserver when the system media volume changes (hardware buttons,
      /// system panel, etc.). Reads the fresh level and forwards it to the UI via onVolumeChanged.
      func handleSystemVolumeChanged() {
        let newVolume = androidCurrentVolume()
        // The observer is registered on Settings.System.CONTENT_URI, which fires for ANY system
        // setting (brightness, rotation, …), not just STREAM_MUSIC. Skip the callback when the media
        // volume hasn't actually moved to avoid needless Observation invalidations and UI re-renders.
        guard newVolume != volume else { return }
        volume = newVolume
        onVolumeChanged?(newVolume)
      }

      func androidStartObservingVolume() {
        guard _volumeObserver == nil else { return }
        let handler = Handler(Looper.getMainLooper())
        let observer = VolumeContentObserver(player: self, handler: handler)
        self._volumeObserver = observer
        context.getContentResolver().registerContentObserver(
          Settings.System.CONTENT_URI, true, observer)
      }

      func androidStopObservingVolume() {
        guard let observer = _volumeObserver else { return }
        context.getContentResolver().unregisterContentObserver(observer)
        _volumeObserver = nil
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
      var _volumeObserver: VolumeContentObserver? = nil
    }

  #else
    // iOS implementation is in AVPlayerStreamPlayer.swift
  #endif

#endif  // !SKIP_BRIDGE
