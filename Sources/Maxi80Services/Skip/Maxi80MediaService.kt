package maxi80.services

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Process
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaController
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionToken
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.MoreExecutors

/**
 * Process-singleton `MediaController` connected to `Maxi80MediaService`'s session, and the app's
 * sole entry point for starting/stopping Android playback.
 *
 * WHY a controller and not the raw ExoPlayer (issue #13): media3 only promotes the service to the
 * foreground and posts its `DefaultMediaNotificationProvider` card when playback flows through the
 * session via a connected `MediaController`. Driving the shared ExoPlayer directly (the previous
 * design) meant nothing ever connected on the phone-only path, so media3 never called
 * `startForeground()` — which both (a) left the app crashing with
 * `ForegroundServiceDidNotStartInTimeException` (a stray `startForegroundService()` armed the 5s
 * contract that nothing satisfied) and (b) posted no notification. Android Auto "worked" only
 * because Auto connects as a controller. An in-app, same-process controller triggers the exact same
 * media3 foreground/notification path, so the phone now behaves like the Auto path.
 *
 * Building the controller binds+starts the service, so no `startForegroundService()` is needed
 * (and it must NOT be re-added — that reintroduces the crash). `startForeground()` fires only when
 * playback becomes playing, which the user triggers from the foreground, so #18
 * (ForegroundServiceStartNotAllowedException on a background bind) does not regress.
 *
 * ICY live-song metadata is unaffected: `onMetadata`/`IcyInfo` does not cross the controller IPC
 * boundary, but the `MetadataPlayerListener` attached directly to the shared ExoPlayer (same
 * process) still receives it — see ExoPlayerStreamPlayer.
 */
@OptIn(UnstableApi::class)
object MediaControllerHolder {
    private var controller: MediaController? = null
    private var connecting: Boolean = false
    // A play/stop requested before the async connect finished runs here as soon as it does.
    private var pendingAction: ((MediaController) -> Unit)? = null

    private const val STREAM_URL = "https://audio1.maxi80.com"

    /** The live-stream MediaItem with station metadata, matching Maxi80MediaService.buildStreamItem().
     *  The service's onAddMediaItems re-resolves whatever we set to its own buildStreamItem(), so the
     *  concrete URI/metadata here is the pre-connect seed the notification shows before ICY arrives. */
    private fun streamItem(context: Context): MediaItem =
        MediaItem.Builder()
            .setUri(STREAM_URL)
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle("Maxi 80")
                    .setArtist("Live")
                    .setArtworkUri(
                        android.net.Uri.parse(
                            "android.resource://${context.packageName}/mipmap/ic_launcher"
                        )
                    )
                    .setIsPlayable(true)
                    .setMediaType(MediaMetadata.MEDIA_TYPE_RADIO_STATION)
                    .build()
            )
            .build()

    /** Start (or restart at the live edge) playback through the controller, connecting on first use. */
    fun play(context: Context) {
        val ctx = context.applicationContext
        runWhenConnected(ctx) { c ->
            // Live radio: always reload so play reconnects to the live edge (never resume a stale buffer).
            c.setMediaItem(streamItem(ctx))
            c.prepare()
            c.play()
        }
    }

    /** Stop playback (true stop, not pause): the next play() reconnects to the live edge. */
    fun stop() {
        val c = controller
        if (c != null && c.isConnected) {
            c.stop()
            c.clearMediaItems()
        } else {
            // Not yet connected: cancel any queued play so a late connect doesn't start audio.
            pendingAction = null
        }
    }

    private fun runWhenConnected(context: Context, action: (MediaController) -> Unit) {
        val existing = controller
        if (existing != null && existing.isConnected) {
            action(existing)
            return
        }
        pendingAction = action
        if (connecting) return
        connecting = true
        val token = SessionToken(context, ComponentName(context, Maxi80MediaService::class.java))
        val future = MediaController.Builder(context, token).buildAsync()
        future.addListener(
            {
                connecting = false
                try {
                    val c = future.get()
                    controller = c
                    val queued = pendingAction
                    pendingAction = null
                    if (queued != null) queued(c)
                } catch (t: Throwable) {
                    // Connect failed (service gone / interrupted). Drop the queued action; a later
                    // play() retries the whole connect. Nothing to foreground, so nothing crashes.
                    pendingAction = null
                }
            },
            MoreExecutors.directExecutor()
        )
    }

    /** Release the controller on full teardown (task removal). */
    fun release() {
        pendingAction = null
        connecting = false
        controller?.release()
        controller = null
    }
}

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

        // NOTE: we deliberately do NOT call startForeground() here, and there is no
        // startForegroundService() anywhere in the app anymore (see MediaControllerHolder). media3
        // owns foreground promotion + the notification: its MediaNotificationManager calls
        // startForeground() and posts the DefaultMediaNotificationProvider card (set above) when the
        // session's player becomes playing, which happens because playback is driven THROUGH an
        // in-app MediaController connected to this session (MediaControllerHolder.play).
        //
        // #18: this onCreate also runs on a cold *bind* — Android Auto or the media-app scanner (the
        // phone's "Personnaliser le lanceur" list) connecting to browse while backgrounded. That bind
        // starts no playback, so media3 never foregrounds on it, so it cannot throw
        // ForegroundServiceStartNotAllowedException (API 31+, this app targets API 36) and Auto still
        // lists the app. Playback-triggered foregrounding always originates from a foreground UI tap.
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession? {
        return session
    }

    /**
     * The user swiped the app away (task removed). Fully tear down playback, drop the media
     * notification, and kill the process so the next launch is a guaranteed cold start.
     *
     * Order matters: release the session FIRST, then the shared ExoPlayer. The session wraps the
     * player, so if we released the player first the session would briefly reference a released
     * ExoPlayer — and stopSelf()'s onDestroy runs asynchronously, so that window is real. Any
     * controller/system access to the session during it would forward to a released player and
     * crash. Releasing the session here also makes onDestroy's session?.release() a safe no-op.
     *
     * Releasing the shared player here is safe precisely because this fires ONLY on genuine task
     * removal — unlike onDestroy, which media3 also invokes on every pause (see onDestroy below,
     * which deliberately does NOT release the player). This path does not affect pause/resume.
     *
     * Why kill the process: Android caches the app process after task removal, so the native
     * coordinator/view-model singletons (playback state, carousel position) would survive with
     * stale state, and a warm relaunch would show a pause button over dead audio and a carousel
     * parked on an old cover. Killing the process makes "swipe away = exit" a true exit — the next
     * launch always starts fresh. Everything is already torn down above, so this loses nothing.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        MediaControllerHolder.release()
        session?.release()
        session = null
        SharedAudioPlayer.releaseShared()
        stopSelf()
        // Called for framework-contract completeness only; the process dies on the next line, so any
        // async teardown super schedules will not run — that is intentional.
        super.onTaskRemoved(rootIntent)
        // Terminate the cached process. This is the whole app's process (the service is not in a
        // separate process), so the UI/singletons die with it and the next icon tap cold-starts.
        Process.killProcess(Process.myPid())
    }

    /**
     * Pin non-sticky restart. Notification/foreground promotion is owned entirely by media3.
     *
     * media3's MediaSessionService returns START_STICKY by default — after onTaskRemoved's
     * killProcess(), a sticky service can be recreated by the system with a null intent,
     * resurrecting playback we just tore down. Returning START_NOT_STICKY guarantees
     * "swipe away = exit" stays a true exit.
     *
     * We deliberately do NOT call startForeground() here, and the app no longer calls
     * startForegroundService() at all (playback is driven through MediaControllerHolder, whose
     * MediaController.Builder binds+starts this service). media3 owns foreground promotion + the
     * DefaultMediaNotificationProvider card: it foregrounds when the session's player becomes
     * playing via the connected controller — the SAME machinery that renders the card under Android
     * Auto. An earlier fix hand-posted a STATIC NotificationCompat on the provider's NOTIFICATION_ID
     * (1001), clobbering media3's live card on OEM shades that latch the first startForeground
     * content (e.g. Samsung One UI); a later attempt deleted that but left a stray
     * startForegroundService() with nothing calling startForeground(), which crashed with
     * ForegroundServiceDidNotStartInTimeException. The controller topology fixes both (issue #13).
     *
     * #18 does NOT regress: a cold *bind* (Auto discovery / the "Personnaliser le lanceur" scanner)
     * starts no playback, so media3 never foregrounds on it and cannot throw
     * ForegroundServiceStartNotAllowedException on API 31+; playback-triggered foregrounding always
     * originates from a foreground UI tap. A system-recreated null intent likewise starts no
     * playback — safe, since we are START_NOT_STICKY. (This override may not even run in the
     * controller topology, since we no longer startService() with an intent; it is kept to pin
     * START_NOT_STICKY so a killed+recreated service never resurrects playback after onTaskRemoved.)
     */
    @OptIn(UnstableApi::class)
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        return START_NOT_STICKY
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
