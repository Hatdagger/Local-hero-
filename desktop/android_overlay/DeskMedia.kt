package __PACKAGE__

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.service.notification.NotificationListenerService
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * Android only lets an app see other apps' "now playing" sessions if the user
 * has given it notification access. This empty listener is what they switch on.
 */
class DeskMediaListener : NotificationListenerService()

/**
 * The mini player's link to Local Hero (or whatever else is playing): reads
 * the song, artwork and position, and sends play/pause/next/previous/seek.
 */
object DeskMedia {
    const val LOCAL_HERO = "com.hatdagger.localhero"

    private var channel: MethodChannel? = null
    private var app: Context? = null
    private var manager: MediaSessionManager? = null
    private var controller: MediaController? = null
    private var listening = false
    private var lastArtKey: Any? = null
    private var lastArt: ByteArray? = null
    private val main = Handler(Looper.getMainLooper())

    private val sessionsChanged = MediaSessionManager.OnActiveSessionsChangedListener { list ->
        pick(list ?: emptyList())
    }

    private val callback = object : MediaController.Callback() {
        override fun onPlaybackStateChanged(state: PlaybackState?) = push()
        override fun onMetadataChanged(metadata: MediaMetadata?) = push()
        override fun onSessionDestroyed() {
            controller = null
            refresh()
        }
    }

    fun register(activity: Activity, engine: FlutterEngine) {
        app = activity.applicationContext
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "desk/media")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                val c = controller?.transportControls
                when (call.method) {
                    "hasAccess" -> result.success(hasAccess(activity))
                    "askAccess" -> {
                        askAccess(activity)
                        result.success(null)
                    }
                    "start" -> {
                        start()
                        result.success(null)
                    }
                    "stop" -> {
                        stop()
                        result.success(null)
                    }
                    "play" -> { c?.play(); result.success(null) }
                    "pause" -> { c?.pause(); result.success(null) }
                    "next" -> { c?.skipToNext(); result.success(null) }
                    "previous" -> { c?.skipToPrevious(); result.success(null) }
                    "seek" -> {
                        c?.seekTo((call.argument<Number>("ms") ?: 0).toLong())
                        result.success(null)
                    }
                    "openPlayer" -> {
                        val pkg = controller?.packageName ?: LOCAL_HERO
                        val i = activity.packageManager.getLaunchIntentForPackage(pkg)
                        if (i != null) {
                            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            activity.startActivity(i)
                        }
                        result.success(i != null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("media", e.message, null)
            }
        }
    }

    private fun component(ctx: Context) = ComponentName(ctx, DeskMediaListener::class.java)

    fun hasAccess(ctx: Context): Boolean {
        val flat = Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners") ?: return false
        val me = component(ctx)
        return flat.split(':').any {
            val cn = ComponentName.unflattenFromString(it)
            cn != null && cn == me
        }
    }

    private fun askAccess(activity: Activity) {
        val detail = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, component(activity).flattenToString())
        } else null
        try {
            activity.startActivity((detail ?: Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: Exception) {
            activity.startActivity(Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    private fun start() {
        val ctx = app ?: return
        if (!hasAccess(ctx)) {
            send(mapOf("access" to false))
            return
        }
        val m = manager ?: (ctx.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager).also { manager = it }
        if (!listening) {
            try {
                m.addOnActiveSessionsChangedListener(sessionsChanged, component(ctx), main)
                listening = true
            } catch (e: SecurityException) {
                send(mapOf("access" to false))
                return
            }
        }
        refresh()
    }

    private fun stop() {
        if (listening) {
            try { manager?.removeOnActiveSessionsChangedListener(sessionsChanged) } catch (_: Exception) {}
            listening = false
        }
        controller?.unregisterCallback(callback)
        controller = null
    }

    private fun refresh() {
        val ctx = app ?: return
        val list = try {
            manager?.getActiveSessions(component(ctx)) ?: emptyList()
        } catch (e: SecurityException) {
            send(mapOf("access" to false))
            return
        }
        pick(list)
    }

    /** Local Hero first; otherwise whatever is playing; otherwise the first one. */
    private fun pick(list: List<MediaController>) {
        val best = list.firstOrNull { it.packageName == LOCAL_HERO }
            ?: list.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
            ?: list.firstOrNull()
        if (best?.sessionToken != controller?.sessionToken) {
            controller?.unregisterCallback(callback)
            controller = best
            best?.registerCallback(callback, main)
        }
        push()
    }

    private fun art(md: MediaMetadata?): ByteArray? {
        val bmp: Bitmap = md?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: md?.getBitmap(MediaMetadata.METADATA_KEY_ART)
            ?: return null
        if (bmp === lastArtKey) return lastArt
        val scaled = if (bmp.width > 256 || bmp.height > 256) {
            val s = 256f / maxOf(bmp.width, bmp.height)
            Bitmap.createScaledBitmap(bmp, (bmp.width * s).toInt().coerceAtLeast(1), (bmp.height * s).toInt().coerceAtLeast(1), true)
        } else bmp
        val out = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.PNG, 100, out)
        lastArtKey = bmp
        lastArt = out.toByteArray()
        return lastArt
    }

    private fun push() {
        val c = controller
        if (c == null) {
            send(mapOf("access" to true, "active" to false))
            return
        }
        val md = c.metadata
        val st = c.playbackState
        val label = try {
            val pm = app!!.packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(c.packageName, 0)).toString()
        } catch (e: Exception) {
            c.packageName
        }
        send(mapOf(
            "access" to true,
            "active" to true,
            "package" to c.packageName,
            "app" to label,
            "title" to (md?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: ""),
            "artist" to (md?.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: ""),
            "album" to (md?.getString(MediaMetadata.METADATA_KEY_ALBUM) ?: ""),
            "duration" to (md?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L),
            "art" to art(md),
            "playing" to (st?.state == PlaybackState.STATE_PLAYING || st?.state == PlaybackState.STATE_BUFFERING),
            "position" to (st?.position ?: 0L),
            "speed" to (st?.playbackSpeed?.toDouble() ?: 1.0),
            "updated" to (st?.lastPositionUpdateTime ?: 0L),
            "now" to android.os.SystemClock.elapsedRealtime(),
        ))
    }

    private fun send(m: Map<String, Any?>) {
        main.post { channel?.invokeMethod("state", m) }
    }
}
