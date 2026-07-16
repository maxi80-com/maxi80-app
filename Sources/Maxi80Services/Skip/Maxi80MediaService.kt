package maxi80.services

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/**
 * Foreground MediaSessionService hosting the app's single MediaSession on the shared ExoPlayer,
 * so playback survives Activity destruction (background, lock-screen) and provides the
 * binding point Android Auto later uses.
 *
 * This is a raw Kotlin file (not transpiled from Swift) because Kotlin requires the `()`
 * call syntax for abstract Android framework superclass constructors, which Skip's emitter
 * omits — see Task 1 spike for details.
 */
class Maxi80MediaService : MediaSessionService() {

    private var session: MediaSession? = null

    companion object {
        private const val CHANNEL_ID = "maxi80_media_playback"
        private const val NOTIFICATION_ID = 1001
    }

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
        session = MediaSession.Builder(applicationContext, player).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        return session
    }

    override fun onDestroy() {
        session?.release()
        session = null
        SharedAudioPlayer.releaseShared()
        super.onDestroy()
    }
}
