import Foundation

#if !SKIP_BRIDGE

/// Platform-agnostic, unit-testable "which player era are we in" counter. `public` so the
/// test target resolves it across the transpiled module boundary (internal `@testable` access
/// does not resolve on the Android test build). Pure value logic — no Android types.
public struct SharedPlayerGeneration {
    private var value: Int = 0
    public init() {}
    public mutating func reset() { value += 1 }
    public func current() -> Int { value }
}

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
