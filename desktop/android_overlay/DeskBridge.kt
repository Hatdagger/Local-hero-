package __PACKAGE__

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.provider.Settings
import android.view.KeyEvent
import android.view.View
import android.webkit.WebView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * The desktop's own link to Android: the list of installed apps (for the
 * Start menu and the Run box), launching them, and the home-app picker that
 * Log Off and the "Switch to Desktop" widget open.
 */
object DeskBridge {
    private val worker = Executors.newSingleThreadExecutor()
    private var channel: MethodChannel? = null
    private var metaAlone = false

    fun register(activity: Activity, engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "desk/platform")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "listApps" -> worker.execute {
                        val list = try { listApps(activity) } catch (e: Exception) { emptyList() }
                        activity.runOnUiThread { result.success(list) }
                    }
                    "launchApp" -> {
                        val pkg = call.argument<String>("package") ?: ""
                        val i = activity.packageManager.getLaunchIntentForPackage(pkg)
                        if (i == null) {
                            result.success(false)
                        } else {
                            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            activity.startActivity(i)
                            result.success(true)
                        }
                    }
                    "homeSettings" -> {
                        openHomeSettings(activity)
                        result.success(null)
                    }
                    "isDefaultHome" -> result.success(isDefaultHome(activity))
                    "focusDesktop" -> {
                        val fv = activity.findViewById<View>(FlutterActivity.FLUTTER_VIEW_ID)
                        val cur = activity.currentFocus
                        if (cur != null && cur !== fv) cur.clearFocus()
                        fv?.requestFocus()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("desk", e.message, null)
            }
        }
    }

    private fun inWebView(v: View?): Boolean {
        var cur: View? = v
        while (cur != null) {
            if (cur is WebView) return true
            cur = cur.parent as? View
        }
        return false
    }

    private fun send(name: String, shift: Boolean = false) {
        channel?.invokeMethod("shortcut", mapOf("name" to name, "shift" to shift))
    }

    /**
     * Called for every key. When a web page has the keyboard, the desktop's
     * shortcuts would never reach the desktop, so they are passed over here.
     */
    fun interceptKey(activity: Activity, e: KeyEvent): Boolean {
        if (!inWebView(activity.currentFocus)) return false
        val down = e.action == KeyEvent.ACTION_DOWN
        val up = e.action == KeyEvent.ACTION_UP
        when (e.keyCode) {
            KeyEvent.KEYCODE_META_LEFT, KeyEvent.KEYCODE_META_RIGHT -> {
                if (down && e.repeatCount == 0) metaAlone = true
                if (up) {
                    if (metaAlone) send("meta")
                    metaAlone = false
                }
                return true
            }
            KeyEvent.KEYCODE_ALT_LEFT, KeyEvent.KEYCODE_ALT_RIGHT -> {
                if (up) send("altUp")
                return false
            }
        }
        if (e.isMetaPressed) metaAlone = false
        if (!down) {
            // Swallow the release of keys we handled.
            return (e.isAltPressed && (e.keyCode == KeyEvent.KEYCODE_TAB || e.keyCode == KeyEvent.KEYCODE_SPACE ||
                e.keyCode == KeyEvent.KEYCODE_F4)) ||
                (e.isMetaPressed && (e.keyCode == KeyEvent.KEYCODE_M || e.keyCode == KeyEvent.KEYCODE_D ||
                    e.keyCode == KeyEvent.KEYCODE_R))
        }
        if (e.isAltPressed) {
            when (e.keyCode) {
                KeyEvent.KEYCODE_TAB -> { send("altTab", e.isShiftPressed); return true }
                KeyEvent.KEYCODE_SPACE -> { send("altSpace"); return true }
                KeyEvent.KEYCODE_F4 -> { send("altF4"); return true }
            }
        }
        if (e.isMetaPressed) {
            when (e.keyCode) {
                KeyEvent.KEYCODE_M -> { send("metaM", e.isShiftPressed); return true }
                KeyEvent.KEYCODE_D -> { send("metaD"); return true }
                KeyEvent.KEYCODE_R -> { send("metaR"); return true }
            }
        }
        return false
    }

    fun openHomeSettings(activity: Activity) {
        try {
            activity.startActivity(Intent(Settings.ACTION_HOME_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: Exception) {
            activity.startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    private fun isDefaultHome(activity: Activity): Boolean {
        val i = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val info = activity.packageManager.resolveActivity(i, PackageManager.MATCH_DEFAULT_ONLY)
        return info?.activityInfo?.packageName == activity.packageName
    }

    private fun listApps(activity: Activity): List<Map<String, Any>> {
        val pm = activity.packageManager
        val i = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val out = mutableListOf<Map<String, Any>>()
        val seen = HashSet<String>()
        for (ri in pm.queryIntentActivities(i, 0)) {
            val pkg = ri.activityInfo.packageName
            if (pkg == activity.packageName || !seen.add(pkg)) continue
            val label = ri.loadLabel(pm).toString()
            val icon = try {
                val d = ri.loadIcon(pm)
                val size = 64
                val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
                val c = Canvas(bmp)
                d.setBounds(0, 0, size, size)
                d.draw(c)
                val bos = ByteArrayOutputStream()
                bmp.compress(Bitmap.CompressFormat.PNG, 100, bos)
                bos.toByteArray()
            } catch (e: Exception) {
                ByteArray(0)
            }
            out.add(mapOf("label" to label, "package" to pkg, "icon" to icon))
        }
        out.sortBy { (it["label"] as String).lowercase() }
        return out
    }
}
