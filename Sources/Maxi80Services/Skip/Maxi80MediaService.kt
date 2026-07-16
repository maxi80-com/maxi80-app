package maxi80.services

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaSession
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
        private const val CHANNEL_ID = "maxi80_media_playback"
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
                    .setIsBrowsable(false)
                    .setIsPlayable(true)
                    .setMediaType(MediaMetadata.MEDIA_TYPE_RADIO_STATION)
                    .build()
            )
            .build()

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
            val resolved = mediaItems.map { item ->
                // Any item from our browse tree (root or stream) maps to the live stream.
                if (item.mediaId == ROOT_ID || item.mediaId == STREAM_ITEM_ID || item.mediaId.isEmpty()) {
                    buildStreamItem()
                } else {
                    item
                }
            }.toMutableList()
            return Futures.immediateFuture(resolved)
        }
    }

    // ---------------------------------------------------------------------------
    // Service lifecycle
    // ---------------------------------------------------------------------------

    override fun onCreate() {
        super.onCreate()

        // Create notification channel (required API 26+).
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Maxi 80 Playback",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Media playback controls"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }

        // Post an initial foreground notification immediately (within the 5-second ANR window).
        // Media3 DefaultMediaNotificationProvider replaces this with the rich media card once
        // the session is active and playing.
        val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("Maxi 80")
                .setContentText("Starting playback…")
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setContentTitle("Maxi 80")
                .setContentText("Starting playback…")
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setOngoing(true)
                .build()
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        val player = SharedAudioPlayer.shared(applicationContext)
        session = MediaLibrarySession.Builder(this, player, libraryCallback).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession? {
        return session
    }

    override fun onDestroy() {
        session?.release()
        session = null
        SharedAudioPlayer.releaseShared()
        super.onDestroy()
    }
}
