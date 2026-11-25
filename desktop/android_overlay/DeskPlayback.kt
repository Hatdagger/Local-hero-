package __PACKAGE__

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.MediaMetadataRetriever
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Size
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.util.concurrent.Executors

/**
 * Lock-screen and notification controls for the desktop's Media Player.
 *
 * Dart tells us what's playing ("update" on channel desk/playback); we keep an
 * Android media session and a media notification up to date, and send the
 * buttons pressed there (lock screen, notification shade, headphones,
 * Bluetooth) back to Dart as "action" calls. A foreground service holds the
 * notification, which also keeps music going while the desktop is in the
 * background.
 */
object DeskPlayback {
    const val NOTIFY_ID = 4711
    private const val CHANNEL_ID = "desk_playback"

    const val ACTION_PLAY_PAUSE = "desk.playback.PLAY_PAUSE"
    const val ACTION_NEXT = "desk.playback.NEXT"
    const val ACTION_PREVIOUS = "desk.playback.PREVIOUS"
    const val ACTION_STOP = "desk.playback.STOP"

    private val main = Handler(Looper.getMainLooper())
    private val artWorker = Executors.newSingleThreadExecutor()

    private var channel: MethodChannel? = null
    private var activity = WeakReference<Activity>(null)
    private lateinit var app: Context
    private var session: MediaSession? = null

    // What's playing.
    private var title = ""
    private var artist = ""
    private var album = ""
    var playing = false
        private set
    private var positionMs = 0L
    private var durationMs = 0L
    private var artKey = ""
    private var art: Bitmap? = null

    var serviceRunning = false

    fun register(act: Activity, engine: FlutterEngine) {
        app = act.applicationContext
        activity = WeakReference(act)
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "desk/playback")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "update" -> {
                        update(
                            call.argument<String>("title") ?: "",
                            call.argument<String>("artist") ?: "",
                            call.argument<String>("album") ?: "",
                            call.argument<Boolean>("playing") ?: false,
                            (call.argument<Number>("position") ?: 0).toLong(),
                            (call.argument<Number>("duration") ?: 0).toLong(),
                            call.argument<String>("uri") ?: "",
                            call.argument<String>("path") ?: "",
                        )
                        result.success(null)
                    }
                    "stop" -> {
                        release()
                        result.success(null)
                    }
                    "askNotifications" -> {
                        val a = activity.get()
                        if (a != null && Build.VERSION.SDK_INT >= 33 &&
                            a.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) {
                            a.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 42)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("playback", e.message, null)
            }
        }
    }

    /** A button was pressed somewhere outside the app: tell the Media Player. */
    fun send(name: String, ms: Long = 0) {
        main.post { channel?.invokeMethod("action", mapOf("name" to name, "ms" to ms)) }
    }

    private fun ensureSession(): MediaSession {
        session?.let { return it }
        val s = MediaSession(app, "ClassicDesk")
        s.setCallback(object : MediaSession.Callback() {
            override fun onPlay() = send("play")
            override fun onPause() = send("pause")
            override fun onSkipToNext() = send("next")
            override fun onSkipToPrevious() = send("previous")
            override fun onStop() = send("stop")
            override fun onSeekTo(pos: Long) = send("seek", pos)
        })
        s.setSessionActivity(openAppIntent())
        s.isActive = true
        session = s
        return s
    }

    private fun update(
        t: String, ar: String, al: String, play: Boolean, pos: Long, dur: Long, uri: String, path: String,
    ) {
        title = t
        artist = ar
        album = al
        playing = play
        positionMs = pos
        durationMs = dur
        val key = uri.ifEmpty { path }
        if (key != artKey) {
            artKey = key
            art = null
            artWorker.execute {
                val bmp = try { loadArt(uri, path) } catch (e: Throwable) { null }
                main.post {
                    if (artKey == key && session != null) {
                        art = bmp
                        publish()
                    }
                }
            }
        }
        ensureSession()
        publish()
    }

    /** Pushes the current song to the session and the notification. */
    private fun publish() {
        val s = session ?: return
        val meta = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
            .putString(MediaMetadata.METADATA_KEY_ALBUM, album)
            .putLong(MediaMetadata.METADATA_KEY_DURATION, durationMs)
        art?.let { meta.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it) }
        s.setMetadata(meta.build())
        s.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or
                        PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                        PlaybackState.ACTION_SEEK_TO or PlaybackState.ACTION_STOP
                )
                .setState(
                    if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    positionMs, if (playing) 1f else 0f, SystemClock.elapsedRealtime()
                )
                .build()
        )
        if (serviceRunning) {
            try {
                (app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .notify(NOTIFY_ID, notification(app))
            } catch (_: Exception) {}
        } else {
            val i = Intent(app, DeskPlaybackService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= 26) app.startForegroundService(i) else app.startService(i)
            } catch (_: Exception) {
                // Android won't start it from the background; the session still
                // works for headphone and Bluetooth buttons.
            }
        }
    }

    /** Takes the controls away (Stop, or the player was closed). */
    fun release() {
        session?.let {
            it.isActive = false
            it.release()
        }
        session = null
        artKey = ""
        art = null
        playing = false
        if (::app.isInitialized) app.stopService(Intent(app, DeskPlaybackService::class.java))
    }

    fun hasSession() = session != null

    private fun openAppIntent(): PendingIntent {
        val i = app.packageManager.getLaunchIntentForPackage(app.packageName)
            ?: Intent(app, MainActivity::class.java)
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(app, 30, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun button(ctx: Context, action: String, code: Int): PendingIntent =
        PendingIntent.getService(
            ctx, code, Intent(ctx, DeskPlaybackService::class.java).setAction(action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    fun notification(ctx: Context): Notification {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val b = if (Build.VERSION.SDK_INT >= 26) {
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Media Player", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "Play, pause and skip from the lock screen and notifications"
                        setShowBadge(false)
                    }
                )
            }
            Notification.Builder(ctx, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(ctx)
        }
        @Suppress("DEPRECATION")
        val prev = Notification.Action.Builder(android.R.drawable.ic_media_previous, "Previous",
            button(ctx, ACTION_PREVIOUS, 31)).build()
        @Suppress("DEPRECATION")
        val toggle = if (playing)
            Notification.Action.Builder(android.R.drawable.ic_media_pause, "Pause", button(ctx, ACTION_PLAY_PAUSE, 32)).build()
        else
            Notification.Action.Builder(android.R.drawable.ic_media_play, "Play", button(ctx, ACTION_PLAY_PAUSE, 32)).build()
        @Suppress("DEPRECATION")
        val next = Notification.Action.Builder(android.R.drawable.ic_media_next, "Next",
            button(ctx, ACTION_NEXT, 33)).build()
        @Suppress("DEPRECATION")
        val stop = Notification.Action.Builder(android.R.drawable.ic_menu_close_clear_cancel, "Stop",
            button(ctx, ACTION_STOP, 34)).build()

        val style = Notification.MediaStyle().setShowActionsInCompactView(0, 1, 2)
        session?.let { style.setMediaSession(it.sessionToken) }
        b.setSmallIcon(if (playing) android.R.drawable.ic_media_play else android.R.drawable.ic_media_pause)
            .setContentTitle(title.ifEmpty { "Media Player" })
            .setContentText(listOf(artist, album).filter { it.isNotEmpty() }.joinToString(" - "))
            .setContentIntent(openAppIntent())
            .setDeleteIntent(button(ctx, ACTION_STOP, 35))
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setOngoing(playing)
            .addAction(prev)
            .addAction(toggle)
            .addAction(next)
            .addAction(stop)
            .setStyle(style)
        art?.let { b.setLargeIcon(it) }
        if (Build.VERSION.SDK_INT >= 31) b.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        return b.build()
    }

    /** The album art (or a video frame) for the lock screen. */
    private fun loadArt(uri: String, path: String): Bitmap? {
        if (uri.isNotEmpty() && Build.VERSION.SDK_INT >= 29) {
            try {
                return app.contentResolver.loadThumbnail(Uri.parse(uri), Size(512, 512), null)
            } catch (_: Exception) {}
        }
        val r = MediaMetadataRetriever()
        try {
            if (uri.isNotEmpty()) r.setDataSource(app, Uri.parse(uri)) else if (path.isNotEmpty()) r.setDataSource(path) else return null
            val pic = r.embeddedPicture ?: return null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(pic, 0, pic.size, bounds)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= 512 && bounds.outHeight / (sample * 2) >= 512) sample *= 2
            return BitmapFactory.decodeByteArray(pic, 0, pic.size, BitmapFactory.Options().apply { inSampleSize = sample })
        } catch (_: Exception) {
            return null
        } finally {
            try { r.release() } catch (_: Exception) {}
        }
    }
}

/** Holds the media notification, and takes its button presses. */
class DeskPlaybackService : Service() {
    private var noisyRegistered = false

    /** Headphones pulled out: pause, like any music player. */
    private val noisy = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY && DeskPlayback.playing) {
                DeskPlayback.send("pause")
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        DeskPlayback.serviceRunning = true
        try {
            val f = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(noisy, f, Context.RECEIVER_NOT_EXPORTED) else registerReceiver(noisy, f)
            noisyRegistered = true
        } catch (_: Exception) {}
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Android wants startForeground() promptly every time, even if we're
        // about to stop again.
        try {
            val n = DeskPlayback.notification(this)
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(DeskPlayback.NOTIFY_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } else {
                startForeground(DeskPlayback.NOTIFY_ID, n)
            }
        } catch (_: Exception) {}
        if (intent == null || !DeskPlayback.hasSession()) {
            // Restarted by Android after the app was closed, or nothing playing.
            stopSelf()
            return START_NOT_STICKY
        }
        when (intent.action) {
            DeskPlayback.ACTION_PLAY_PAUSE -> DeskPlayback.send(if (DeskPlayback.playing) "pause" else "play")
            DeskPlayback.ACTION_NEXT -> DeskPlayback.send("next")
            DeskPlayback.ACTION_PREVIOUS -> DeskPlayback.send("previous")
            DeskPlayback.ACTION_STOP -> DeskPlayback.send("stop")
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        DeskPlayback.serviceRunning = false
        if (noisyRegistered) {
            try { unregisterReceiver(noisy) } catch (_: Exception) {}
        }
        super.onDestroy()
    }
}
