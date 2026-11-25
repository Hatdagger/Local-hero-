package __PACKAGE__

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
import android.net.wifi.WifiManager

/**
 * Keeps the app process alive (and the AIM connection up) while backgrounded.
 * While signed on it also holds a partial wake lock and a Wi-Fi lock: without
 * them the CPU sleeps when the screen goes off, the 50-second keep-alive pings
 * stop, and the server drops the connection.
 */
class AimConnectionService : Service() {
    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    @Suppress("DEPRECATION")
    private fun holdLocks() {
        if (wake == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "aim:connection").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (wifi == null) {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifi = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "aim:connection").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseLocks() {
        try { wake?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
        try { wifi?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
        wake = null
        wifi = null
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            // Restarted by the system after the app process died: nothing to keep alive.
            stopSelf()
            return START_NOT_STICKY
        }
        val text = intent?.getStringExtra("text") ?: "Signed on"
        val n = AimNotifications.serviceNotification(this, text)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(AimNotifications.SERVICE_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(AimNotifications.SERVICE_ID, n)
        }
        try { holdLocks() } catch (_: Exception) {}
        return START_NOT_STICKY
    }

    // Swiping the app away from Recents no longer signs you off: the app's
    // engine lives on (see MainActivity.provideFlutterEngine) as long as this
    // service keeps the process running. Sign Off stops it.

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }
}

object AimNotifications {
    const val SERVICE_ID = 5190
    const val UNREAD_ID = 5191
    private const val SERVICE_CHANNEL = "aim_connection"
    private const val MESSAGE_CHANNEL = "aim_messages"

    private fun ensureChannels(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(SERVICE_CHANNEL, "Connection", NotificationManager.IMPORTANCE_MIN).apply {
                description = "Shown while AIM stays signed on in the background"
                setShowBadge(false)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(MESSAGE_CHANNEL, "New messages", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Tells you how many new messages are waiting (no names or previews)"
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
        )
    }

    private fun openApp(ctx: Context): PendingIntent {
        val i = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            ?: Intent(ctx, MainActivity::class.java)
        i.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
        return PendingIntent.getActivity(ctx, 0, i, flags)
    }

    @Suppress("DEPRECATION")
    private fun builder(ctx: Context, channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(ctx, channel) else Notification.Builder(ctx)

    fun serviceNotification(ctx: Context, text: String): Notification {
        ensureChannels(ctx)
        return builder(ctx, SERVICE_CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle("AIM")
            .setContentText(text)
            .setOngoing(true)
            .setContentIntent(openApp(ctx))
            .build()
    }

    fun showUnread(ctx: Context, count: Int) {
        ensureChannels(ctx)
        val text = if (count == 1) "You have 1 new AIM message" else "You have $count new AIM messages"
        @Suppress("DEPRECATION")
        val n = builder(ctx, MESSAGE_CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle("AIM")
            .setContentText(text)
            .setNumber(count)
            .setAutoCancel(true)
            .setOnlyAlertOnce(false)
            .setPriority(Notification.PRIORITY_HIGH)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(openApp(ctx))
            .build()
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(UNREAD_ID, n)
    }

    fun clearUnread(ctx: Context) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(UNREAD_ID)
    }
}
