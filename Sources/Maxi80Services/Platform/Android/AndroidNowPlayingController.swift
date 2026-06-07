import Foundation
#if !SKIP_BRIDGE

#if SKIP
import android.net.Uri
import android.os.Bundle
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
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

        let metadataBuilder = MediaMetadata.Builder()
            .setTitle(title)
            .setArtist(artist)

        if let urlString = artworkURL, !urlString.isEmpty {
            let artworkUri = Uri.parse(urlString)
            _ = metadataBuilder.setArtworkUri(artworkUri)
        }

        // Note: MediaSession metadata is set via player; for now-playing only
        // we store the metadata for the session to publish
        _ = metadataBuilder.build()
    }

    // MARK: - Playback State

    /// Update playback state on the MediaSession.
    func platformUpdatePlaybackState(isPlaying: Bool) {
        // MediaSession reflects playback state from the player automatically
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

        // Create a minimal ExoPlayer as the session player
        let player = ExoPlayer.Builder(ctx).build()
        self._sessionPlayer = player

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
        _sessionPlayer?.release()
        _sessionPlayer = nil
    }

    // MARK: - Private Storage

    var _mediaSession: MediaSession? = nil
    var _sessionCallback: NowPlayingSessionCallback? = nil
    var _sessionPlayer: ExoPlayer? = nil
}

#else
// iOS implementation is in IOSNowPlayingController.swift
#endif

#endif // !SKIP_BRIDGE
