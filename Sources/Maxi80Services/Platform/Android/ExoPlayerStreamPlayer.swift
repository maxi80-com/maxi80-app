import Foundation
#if !SKIP_BRIDGE

#if SKIP
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import skip.foundation.ProcessInfo

// MARK: - Named Listener for Metadata Changes

class MetadataPlayerListener: Player.Listener {
    private let player: AudioStreamPlayer

    init(player: AudioStreamPlayer) {
        self.player = player
    }

    override func onMediaMetadataChanged(mediaMetadata: MediaMetadata) {
        // Ignore our own writeback echo. The ICY stream only ever fills `title` (the whole
        // "ARTIST - TITLE", which MetadataParser then splits) and never `artist`; the only thing
        // that sets `artist` is our own now-playing writeback (platformUpdateNowPlaying, which
        // replaceMediaItem's the parsed split values back onto the player for the notification/car).
        // That write re-fires this callback, so a change carrying an artist is our echo — skipping
        // it prevents re-parsing a bare split title as a new artist-less song (which fell back to
        // the station name "Maxi 80" and broke cover + history reconciliation).
        if let artist = mediaMetadata.artist?.toString(), !artist.isEmpty { return }
        guard let title = mediaMetadata.title?.toString() else { return }
        player.handleMetadataChanged(title)
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
}

// MARK: - Named BroadcastReceiver for Audio Becoming Noisy

class BecomingNoisyReceiver: BroadcastReceiver {
    private let player: AudioStreamPlayer

    init(player: AudioStreamPlayer) {
        self.player = player
    }

    override func onReceive(context: Context?, intent: Intent?) {
        guard let action = intent?.action else { return }
        if action == AudioManager.ACTION_AUDIO_BECOMING_NOISY {
            player.handleBecomingNoisy()
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

    private var audioManager: AudioManager {
        context.getSystemService(Context.AUDIO_SERVICE) as! AudioManager
    }

    // MARK: - Playback Control

    func androidPlay(url streamUrl: String) {
        let ctx = context
        let exoPlayer = SharedAudioPlayer.shared(context: ctx)
        self._exoPlayer = exoPlayer

        // Attach the metadata listener once per player instance.
        if _metadataListener == nil {
            let listener = MetadataPlayerListener(player: self)
            self._metadataListener = listener
            exoPlayer.addListener(listener)
        }

        let mediaItem = MediaItem.fromUri(streamUrl)
        exoPlayer.setMediaItem(mediaItem)

        if requestAudioFocus() {
            exoPlayer.prepare()
            exoPlayer.play()
            isPlaying = true
            onPlaybackStateChanged?(true)
        }

        registerNoisyReceiver()

        // Start the foreground MediaSessionService so the media notification appears and
        // playback survives Activity destruction (background / lock-screen).
        let serviceIntent = android.content.Intent()
        serviceIntent.setClassName(ctx, "maxi80.services.Maxi80MediaService")
        ctx.startForegroundService(serviceIntent)
    }

    func androidStop() {
        unregisterNoisyReceiver()
        abandonAudioFocus()

        _exoPlayer?.stop()
        _exoPlayer?.clearMediaItems()
        isPlaying = false
        onPlaybackStateChanged?(false)

        // Stop the foreground media service; it will release the session and player in onDestroy.
        let ctx = context
        let serviceIntent = android.content.Intent()
        serviceIntent.setClassName(ctx, "maxi80.services.Maxi80MediaService")
        ctx.stopService(serviceIntent)
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

    // MARK: - Audio Becoming Noisy

    func handleBecomingNoisy() {
        // Headphones disconnected — pause playback
        _exoPlayer?.pause()
        isPlaying = false
        onPlaybackStateChanged?(false)
        onInterruption?(true)
    }

    // MARK: - Audio Focus

    private func requestAudioFocus() -> Bool {
        let audioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()

        let focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(audioAttributes)
            .setOnAudioFocusChangeListener { focusChange in
                self.handleAudioFocusChange(focusChange)
            }
            .build()

        self._audioFocusRequest = focusRequest

        let result = audioManager.requestAudioFocus(focusRequest)
        return result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private func abandonAudioFocus() {
        guard let focusRequest = _audioFocusRequest else { return }
        audioManager.abandonAudioFocusRequest(focusRequest)
        _audioFocusRequest = nil
    }

    private func handleAudioFocusChange(_ focusChange: Int) {
        switch focusChange {
        case AudioManager.AUDIOFOCUS_LOSS:
            // Permanent loss — stop playback
            _exoPlayer?.pause()
            isPlaying = false
            onPlaybackStateChanged?(false)
            onInterruption?(true)

        case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT:
            // Transient loss — pause, expect to resume
            _exoPlayer?.pause()
            isPlaying = false
            onPlaybackStateChanged?(false)
            onInterruption?(true)

        case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK:
            // Duck volume temporarily
            _exoPlayer?.volume = Float(0.2)

        case AudioManager.AUDIOFOCUS_GAIN:
            // Regained focus — resume playback
            _exoPlayer?.volume = Float(volume)
            _exoPlayer?.play()
            isPlaying = true
            onPlaybackStateChanged?(true)
            onInterruption?(false)

        default:
            break
        }
    }

    // MARK: - Becoming Noisy Receiver

    private func registerNoisyReceiver() {
        let receiver = BecomingNoisyReceiver(player: self)
        self._noisyReceiver = receiver

        let filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        context.registerReceiver(receiver, filter)
    }

    private func unregisterNoisyReceiver() {
        guard let receiver = _noisyReceiver else { return }
        do {
            context.unregisterReceiver(receiver)
        } catch {
            // Receiver may not have been registered
        }
        _noisyReceiver = nil
    }

    // MARK: - Private Storage

    var _exoPlayer: ExoPlayer? = nil
    var _metadataListener: MetadataPlayerListener? = nil
    var _audioFocusRequest: AudioFocusRequest? = nil
    var _noisyReceiver: BecomingNoisyReceiver? = nil
}

#else
// iOS implementation is in AVPlayerStreamPlayer.swift
#endif

#endif // !SKIP_BRIDGE
