import Foundation

#if !SKIP_BRIDGE

#if SKIP
import androidx.media3.exoplayer.ExoPlayer

/// Holds the ONE long-lived ExoPlayer for the app's Android audio. Created once, kept for the
/// service/process lifetime, and shared by playback (`AudioStreamPlayer`) and the media session/
/// service — the media3-canonical topology so the car/notification control the audible player.
enum SharedAudioPlayer {
    private static var player: ExoPlayer? = nil

    /// The single ExoPlayer, created on first use against the app context.
    static func shared(context: android.content.Context) -> ExoPlayer {
        if let existing = player { return existing }
        let created = ExoPlayer.Builder(context).build()
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
