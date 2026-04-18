package com.davenicoll.snorelore

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Minimal microphone-type foreground service. Its only job is to keep the
 * process alive while SnoreLore is listening; all recording logic stays in
 * the Flutter main isolate.
 *
 * Holds a PARTIAL_WAKE_LOCK for the duration of the session. Without it,
 * Doze-mode CPU throttling can pause the audio stream when the screen is
 * off — even though the foreground service keeps the process alive. The
 * wake lock keeps the CPU on; it does not keep the screen on.
 */
class RecordingService : Service() {

    companion object {
        const val ACTION_START = "com.davenicoll.snorelore.START"
        const val ACTION_STOP = "com.davenicoll.snorelore.STOP"
        const val ACTION_UPDATE = "com.davenicoll.snorelore.UPDATE"
        const val EXTRA_TITLE = "title"
        const val EXTRA_CONTENT = "content"
        private const val CHANNEL_ID = "snorelore_recording"
        private const val CHANNEL_NAME = "SnoreLore recording"
        private const val NOTIFICATION_ID = 1001
        private const val WAKE_LOCK_TAG = "snorelore:recording"
        private const val DEFAULT_TITLE = "SnoreLore is listening"
        private const val DEFAULT_CONTENT = "Keeps recording until you tap stop"
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var currentTitle: String = DEFAULT_TITLE
    private var currentContent: String = DEFAULT_CONTENT

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                releaseWakeLock()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_UPDATE -> {
                intent.getStringExtra(EXTRA_TITLE)?.let { currentTitle = it }
                intent.getStringExtra(EXTRA_CONTENT)?.let { currentContent = it }
                // Only push the update if the service is already running —
                // UPDATE should never be what first promotes us to foreground.
                if (wakeLock?.isHeld == true) {
                    val manager = getSystemService(NotificationManager::class.java)
                    manager?.notify(NOTIFICATION_ID, buildNotification())
                }
                return START_STICKY
            }
            else -> {
                ensureChannel()
                val notification = buildNotification()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
                acquireWakeLock()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        val lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
        lock.setReferenceCounted(false)
        try {
            lock.acquire()
        } catch (_: Throwable) {}
        wakeLock = lock
    }

    private fun releaseWakeLock() {
        val lock = wakeLock ?: return
        wakeLock = null
        try {
            if (lock.isHeld) lock.release()
        } catch (_: Throwable) {}
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW
        )
        channel.description = "Keeps SnoreLore listening overnight"
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pi = if (launch != null) {
            PendingIntent.getActivity(
                this,
                0,
                launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else null

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setContentTitle(currentTitle)
            .setContentText(currentContent)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
        if (pi != null) builder.setContentIntent(pi)
        return builder.build()
    }
}
