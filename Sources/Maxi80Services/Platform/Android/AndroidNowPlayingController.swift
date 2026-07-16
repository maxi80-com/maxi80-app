import Foundation
#if !SKIP_BRIDGE

#if SKIP
import android.net.Uri
import android.os.Bundle
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import skip.foundation.ProcessInfo

// MARK: - Named Callback for MediaSession

class NowPlayingSessionCallback: MediaSession.Callback {
    var controller: NowPlayingController?

    init(controller: NowPlayingController) {
        self.controller = controller
    }

    override func onConnect(session: MediaSession, controllerInfo: MediaSession.ControllerInfo) -> MediaSession.ConnectionResult {
        return MediaSession.ConnectionResult.AcceptedResultBuilder(session).build()
    }

    override func onCustomCommand(
        session: MediaSession,
        controllerInfo: MediaSession.ControllerInfo,
        customCommand: SessionCommand,
        args: Bundle
    ) -> ListenableFuture<SessionResult> {
        let action = customCommand.customAction
        if action == "play" || action == "pause" || action == "togglePlayPause" {
            controller?.handleRemoteCommand(action)
        }
        return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
    }
}

// MARK: - AndroidNowPlayingController (Android Implementation)

extension NowPlayingController {

    private var context: android.content.Context {
        ProcessInfo.processInfo.androidContext
    }

    // MARK: - Now Playing Metadata

    /// Update the MediaSession metadata with current track information.
    func platformUpdateNowPlaying(artist: String, title: String, artworkURL: String?, isPlaying: Bool) {
        ensureMediaSession()
        let metadata = MediaMetadata.Builder()
            .setTitle(title)
            .setArtist(artist)
        if let urlString = artworkURL, !urlString.isEmpty {
            _ = metadata.setArtworkUri(Uri.parse(urlString))
        }
        // Apply to the shared player's current item so controllers (notification, lock screen,
        // later the car) see live metadata; the session reflects the player's mediaMetadata.
        // Rebuild the current MediaItem with the new metadata (no-op if nothing is loaded yet —
        // ExoPlayerStreamPlayer sets the item on play, and the next metadata update re-applies).
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

    /// Ensure the MediaSession is created.
    private func ensureMediaSession() {
        guard _mediaSession == nil else { return }
        let ctx = context
        let callback = NowPlayingSessionCallback(controller: self)
        self._sessionCallback = callback
        let player = SharedAudioPlayer.shared(context: ctx)
        let session = MediaSession.Builder(ctx, player)
            .setCallback(callback)
            .build()
        self._mediaSession = session
    }

    /// Release the MediaSession and clean up resources.
    func platformTearDown() {
        _mediaSession?.release()
        _mediaSession = nil
        _sessionCallback = nil
        // The shared player is released by SharedAudioPlayer.releaseShared() (service onDestroy),
        // NOT here — the session no longer owns a player of its own.
    }

    // MARK: - Private Storage

    var _mediaSession: MediaSession? = nil
    var _sessionCallback: NowPlayingSessionCallback? = nil
}

#else
// iOS implementation is in IOSNowPlayingController.swift
#endif

#endif // !SKIP_BRIDGE
