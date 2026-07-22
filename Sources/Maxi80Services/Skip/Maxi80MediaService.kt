package maxi80.services

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import androidx.annotation.OptIn
import androidx.core.app.NotificationCompat
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaStyleNotificationHelper
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

/**
 * Foreground MediaLibraryService hosting the app's single MediaLibrarySession on the shared
 * ExoPlayer, so playback survives Activity destruction (background, lock-screen) and provides
 * the binding point Android Auto uses for browse/playback.
 *
 * This is a raw Kotlin file (not transpiled from Swift) because Kotlin requires the `()`
 * call syntax for abstract Android framework superclass constructors, which Skip's emitter
 * omits — see Task 1 spike for details.
 */
class Maxi80MediaService : MediaLibraryService() {

    private var session: MediaLibrarySession? = null

    companion object {
        // Versioned channel ID. Android freezes a channel's importance at creation time: once a
        // channel exists, later createNotificationChannel() calls with a lower/higher importance are
        // ignored. The v1 channel shipped at IMPORTANCE_LOW (beta 5.0.0.2026071902), which suppresses
        // lock-screen visibility on many OEMs. Bumping the suffix creates a fresh channel at the new
        // IMPORTANCE_DEFAULT for upgraders; the stale v1 channel is deleted in onCreate().
        private const val CHANNEL_ID = "maxi80_media_playback_v2"
        private const val LEGACY_CHANNEL_ID = "maxi80_media_playback"
        private const val NOTIFICATION_ID = 1001

        // Stream URL for the Maxi 80 live audio feed.
        // TODO: ideally this would come from a shared station-config object accessible from
        // the Maxi80Services module (e.g. exposed via SharedAudioPlayer or a constants file)
        // so there is only one authoritative copy. The native RadioPlayerCoordinator holds the
        // same URL but cannot be imported by this transpiled module (dependency direction is
        // native → transpiled). Keep in sync with RadioPlayerCoordinator.streamURL.
        private const val STREAM_URL = "https://audio1.maxi80.com"

        private const val ROOT_ID = "root"
        private const val STREAM_ITEM_ID = "maxi80_live"
    }

    // ---------------------------------------------------------------------------
    // Browse tree helpers
    // ---------------------------------------------------------------------------

    /** Browsable root node — Android Auto shows its children. */
    private fun buildRootItem(): MediaItem =
        MediaItem.Builder()
            .setMediaId(ROOT_ID)
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle("Maxi 80")
                    .setIsBrowsable(true)
                    .setIsPlayable(false)
                    .setMediaType(MediaMetadata.MEDIA_TYPE_FOLDER_MIXED)
                    .build()
            )
            .build()

    /** The single playable live-stream item surfaced to the car. */
    private fun buildStreamItem(): MediaItem =
        MediaItem.Builder()
            .setMediaId(STREAM_ITEM_ID)
            .setUri(STREAM_URL)
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle("Maxi 80")
                    .setArtist("Live")
                    .setArtworkUri(stationArtworkUri())
                    .setIsBrowsable(false)
                    .setIsPlayable(true)
                    .setMediaType(MediaMetadata.MEDIA_TYPE_RADIO_STATION)
                    .build()
            )
            .build()

    /**
     * The bundled launcher icon as an `android.resource://` URI so the car browse item shows the
     * station logo before any live cover arrives (live song artwork replaces it via the shared
     * player's metadata once playback starts). Built from the runtime package name so it resolves
     * for every build variant. There is no hosted station-artwork URL in the app config to use here.
     */
    private fun stationArtworkUri(): android.net.Uri =
        android.net.Uri.parse("android.resource://$packageName/mipmap/ic_launcher")

    // ---------------------------------------------------------------------------
    // MediaLibrarySession.Callback
    // ---------------------------------------------------------------------------

    private val libraryCallback = object : MediaLibrarySession.Callback {

        override fun onGetLibraryRoot(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            params: MediaLibraryService.LibraryParams?
        ): ListenableFuture<LibraryResult<MediaItem>> =
            Futures.immediateFuture(LibraryResult.ofItem(buildRootItem(), params))

        override fun onGetChildren(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            parentId: String,
            page: Int,
            pageSize: Int,
            params: MediaLibraryService.LibraryParams?
        ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> {
            if (parentId != ROOT_ID) {
                return Futures.immediateFuture(
                    LibraryResult.ofError(LibraryResult.RESULT_ERROR_BAD_VALUE)
                )
            }
            return Futures.immediateFuture(
                LibraryResult.ofItemList(ImmutableList.of(buildStreamItem()), params)
            )
        }

        override fun onGetItem(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            mediaId: String
        ): ListenableFuture<LibraryResult<MediaItem>> {
            val item = when (mediaId) {
                ROOT_ID -> buildRootItem()
                STREAM_ITEM_ID -> buildStreamItem()
                else -> return Futures.immediateFuture(
                    LibraryResult.ofError(LibraryResult.RESULT_ERROR_BAD_VALUE)
                )
            }
            return Futures.immediateFuture(LibraryResult.ofItem(item, null))
        }

        /**
         * Called when the car (or another controller) selects an item to play.
         * We resolve any recognised media ID to the live-stream item with a concrete URI,
         * so ExoPlayer can start streaming immediately via the shared player.
         */
        override fun onAddMediaItems(
            mediaSession: MediaSession,
            controller: MediaSession.ControllerInfo,
            mediaItems: MutableList<MediaItem>
        ): ListenableFuture<MutableList<MediaItem>> {
            // This app streams exactly ONE live station. Never trust a controller-supplied URI:
            // synthesize the stream item server-side for every requested item, ignoring whatever
            // mediaId/URI the caller sent. This prevents a malicious/foreign controller from making
            // the player load an arbitrary URI, and there is no legitimate case for any other item.
            val resolved = mediaItems.map { buildStreamItem() }.toMutableList()
            return Futures.immediateFuture(resolved)
        }
    }

    // ---------------------------------------------------------------------------
    // Service lifecycle
    // ---------------------------------------------------------------------------

    @OptIn(UnstableApi::class)
    override fun onCreate() {
        super.onCreate()

        // Create notification channel (required API 26+). Use IMPORTANCE_DEFAULT so the
        // notification appears on the lock screen and in the notification drawer. IMPORTANCE_LOW
        // was previously used but suppresses lock-screen visibility on many OEMs.
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Drop the stale IMPORTANCE_LOW v1 channel from beta installs. Its importance is frozen
            // and cannot be raised in place, so we migrate to a fresh CHANNEL_ID (see companion).
            manager.deleteNotificationChannel(LEGACY_CHANNEL_ID)

            val channel = NotificationChannel(
                CHANNEL_ID,
                "Maxi 80 Playback",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Media playback controls"
                setShowBadge(false)
                // Suppress sound/vibration — this is a media channel, not an alert.
                setSound(null, null)
                enableVibration(false)
            }
            manager.createNotificationChannel(channel)
        }

        val player = SharedAudioPlayer.shared(applicationContext)
        session = MediaLibrarySession.Builder(this, player, libraryCallback)
            .apply {
                // Tapping the notification / lock-screen card returns the user to the app — this was
                // the core usability complaint (issue #3). Resolve the launcher activity for our own
                // package so the intent survives the transpiled/native split without a hardcoded class.
                packageManager.getLaunchIntentForPackage(packageName)?.let { launchIntent ->
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                        (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
                    setSessionActivity(
                        PendingIntent.getActivity(this@Maxi80MediaService, 0, launchIntent, flags)
                    )
                }
            }
            .build()

        // Point Media3's automatic notification provider at OUR channel (IMPORTANCE_DEFAULT,
        // created above) instead of its own default channel, which it creates at IMPORTANCE_LOW.
        // This provider is what actually renders the rich lock-screen card — artwork, title/artist,
        // and the play/pause control — populated live from the MediaSession's current MediaItem
        // metadata (set via NowPlayingController.platformUpdateNowPlaying) and player commands.
        // Without pinning the channel, the visible media notification would inherit LOW importance
        // and be suppressed from the lock screen on many OEMs.
        setMediaNotificationProvider(
            DefaultMediaNotificationProvider.Builder(this)
                .setNotificationId(NOTIFICATION_ID)
                .setChannelId(CHANNEL_ID)
                .build()
        )

        // Post a MediaStyle foreground notification immediately (within the 5-second ANR window).
        // Attaching the session token marks this as a media notification, which the system shows
        // on the lock screen with playback controls. Media3's DefaultMediaNotificationProvider
        // replaces this with the full rich card once playback metadata arrives.
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Maxi 80")
            .setContentText("Starting playback…")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setStyle(MediaStyleNotificationHelper.MediaStyle(session!!))
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession? {
        return session
    }

    /**
     * The user swiped the app away (task removed). Fully tear down playback: stop and release the
     * shared ExoPlayer, then stopSelf() — which routes through onDestroy to release the session and
     * drop the media notification.
     *
     * Releasing the shared player here is safe precisely because this fires ONLY on genuine task
     * removal — unlike onDestroy, which media3 also invokes on every pause (see onDestroy below,
     * which deliberately does NOT release the player). This path does not affect pause/resume.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = SharedAudioPlayer.shared(applicationContext)
        player.stop()
        player.clearMediaItems()
        SharedAudioPlayer.releaseShared()
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        // Release ONLY the session, never the shared player. media3's MediaSessionService stops
        // (and destroys) the service whenever playback pauses; if this also released the shared
        // player, every pause would tear the player down and the next play would build a fresh one
        // whose audio starts while the old player's AudioTrack buffer is still draining — two
        // overlapping streams with a small offset. The player is a process singleton owned by
        // SharedAudioPlayer, not by this service, so it must outlive service destruction; the OS
        // reclaims it on process death.
        session?.release()
        session = null
        super.onDestroy()
    }
}
