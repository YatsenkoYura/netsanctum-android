package com.example.netoutpost

import android.app.*
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class OutpostSyncService : Service() {

    companion object {
        const val CHANNEL_ID = "outpost_sync_channel"
        const val NOTIFICATION_ID = 1001

        const val ACTION_START = "START"
        const val ACTION_UPDATE = "UPDATE"
        const val ACTION_STOP = "STOP"

        const val EXTRA_TITLE = "title"
        const val EXTRA_PROGRESS = "progress"
        const val EXTRA_SPEED = "speed"
        const val EXTRA_REMAINING = "remaining"
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent != null) {
            when (intent.action) {
                ACTION_START -> {
                    val title = intent.getStringExtra(EXTRA_TITLE) ?: "Downloading..."
                    startForeground(NOTIFICATION_ID, buildNotification(title, 0, "", ""))
                }
                ACTION_UPDATE -> {
                    val title = intent.getStringExtra(EXTRA_TITLE) ?: "Downloading..."
                    val progress = intent.getIntExtra(EXTRA_PROGRESS, 0)
                    val speed = intent.getStringExtra(EXTRA_SPEED) ?: ""
                    val remaining = intent.getStringExtra(EXTRA_REMAINING) ?: ""
                    
                    val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    notificationManager.notify(NOTIFICATION_ID, buildNotification(title, progress, speed, remaining))
                }
                ACTION_STOP -> {
                    stopForeground(true)
                    stopSelf()
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                CHANNEL_ID,
                "NetOutpost Sync Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows offline synchronization progress"
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(serviceChannel)
        }
    }

    private fun buildNotification(title: String, progress: Int, speed: String, remaining: String): Notification {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT else PendingIntent.FLAG_UPDATE_CURRENT
        )

        val contentText = StringBuilder()
        if (speed.isNotEmpty()) contentText.append(speed)
        if (remaining.isNotEmpty()) {
            if (contentText.isNotEmpty()) contentText.append(" • ")
            contentText.append(remaining)
        }
        if (contentText.isEmpty()) {
            contentText.append("Syncing files...")
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(contentText.toString())
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .setProgress(100, progress, false)
            .setOnlyAlertOnce(true)
            .build()
    }
}
