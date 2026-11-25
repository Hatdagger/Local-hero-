package __PACKAGE__

import android.app.Activity
import android.app.ActivityOptions
import android.content.Intent
import android.graphics.Rect
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.webkit.MimeTypeMap
import java.io.File
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
    @Volatile private var browserKeys = false

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
                    "setBrowserKeys" -> {
                        browserKeys = call.argument<Boolean>("on") ?: false
                        result.success(null)
                    }
                    "hasAllFiles" -> result.success(hasAllFiles(activity))
                    "askAllFiles" -> {
                        askAllFiles(activity)
                        result.success(null)
                    }
                    "storageRoot" -> result.success(Environment.getExternalStorageDirectory().absolutePath)
                    "volumes" -> result.success(volumes(activity))
                    "openWith" -> {
                        val path = call.argument<String>("path") ?: ""
                        val pkg = call.argument<String>("package")
                        openWith(activity, path, pkg) { ok -> activity.runOnUiThread { result.success(ok) } }
                    }
                    "launchBounded" -> {
                        result.success(launchBounded(
                            activity,
                            call.argument<String>("package") ?: "",
                            call.argument<String>("url"),
                            Rect(
                                call.argument<Int>("left") ?: 0,
                                call.argument<Int>("top") ?: 0,
                                call.argument<Int>("right") ?: 0,
                                call.argument<Int>("bottom") ?: 0,
                            ),
                        ))
                    }
                    "shutdown" -> {
                        result.success(null)
                        shutdown(activity, call.argument<Boolean>("restart") ?: false)
                    }
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
        if (browserKeys) {
            val name = when {
                e.isCtrlPressed && !e.isAltPressed && e.keyCode == KeyEvent.KEYCODE_T -> "ctrlT"
                e.isCtrlPressed && !e.isAltPressed && e.keyCode == KeyEvent.KEYCODE_W -> "ctrlW"
                e.isCtrlPressed && !e.isAltPressed && e.keyCode == KeyEvent.KEYCODE_L -> "ctrlL"
                !e.isCtrlPressed && !e.isAltPressed && e.keyCode == KeyEvent.KEYCODE_F5 -> "f5"
                e.isAltPressed && e.keyCode == KeyEvent.KEYCODE_DPAD_LEFT -> "altLeft"
                e.isAltPressed && e.keyCode == KeyEvent.KEYCODE_DPAD_RIGHT -> "altRight"
                else -> null
            }
            if (name != null) {
                if (down && e.repeatCount == 0) send(name)
                return true
            }
        }
        if (!down) {
            // Swallow the release of keys we handled.
            return (e.isAltPressed && (e.keyCode == KeyEvent.KEYCODE_TAB || e.keyCode == KeyEvent.KEYCODE_SPACE ||
                e.keyCode == KeyEvent.KEYCODE_F4)) ||
                (e.isMetaPressed && (e.keyCode == KeyEvent.KEYCODE_M || e.keyCode == KeyEvent.KEYCODE_D ||
                    e.keyCode == KeyEvent.KEYCODE_R || e.keyCode == KeyEvent.KEYCODE_E))
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
                KeyEvent.KEYCODE_E -> { send("metaE"); return true }
            }
        }
        return false
    }

    /**
     * Shut Down: stops the AIM keep-alive service and ends the app's process.
     * If the desktop is the home screen, Android's home picker opens first,
     * otherwise Android would start the desktop again straight away.
     * Restart: same, then the desktop starts again.
     */
    private fun shutdown(activity: Activity, restart: Boolean) {
        try {
            activity.stopService(Intent(activity, AimConnectionService::class.java))
        } catch (_: Exception) {}
        if (restart) {
            val i = activity.packageManager.getLaunchIntentForPackage(activity.packageName)
            if (i != null) {
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                activity.startActivity(i)
            }
        } else if (isDefaultHome(activity)) {
            openHomeSettings(activity)
        }
        activity.finishAndRemoveTask()
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            android.os.Process.killProcess(android.os.Process.myPid())
        }, 400)
    }

    /** "All files access", which the file browser needs to see the whole device. */
    private fun hasAllFiles(activity: Activity): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            activity.checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true
        }

    private fun askAllFiles(activity: Activity) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                activity.startActivity(
                    Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:${activity.packageName}"))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } catch (e: Exception) {
                activity.startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            activity.requestPermissions(arrayOf(
                android.Manifest.permission.READ_EXTERNAL_STORAGE,
                android.Manifest.permission.WRITE_EXTERNAL_STORAGE,
            ), 52)
        }
    }

    /** Internal storage, SD cards and USB drives: (name, folder). */
    private fun volumes(activity: Activity): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val sm = activity.getSystemService(StorageManager::class.java)
            for (v in sm.storageVolumes) {
                val dir = v.directory ?: continue
                out.add(mapOf(
                    "name" to v.getDescription(activity),
                    "path" to dir.absolutePath,
                    "removable" to v.isRemovable,
                ))
            }
        }
        if (out.isEmpty()) {
            out.add(mapOf("name" to "Internal storage", "path" to Environment.getExternalStorageDirectory().absolutePath, "removable" to false))
        }
        return out
    }

    /**
     * Opens a file in [pkg] (or lets the user choose an app when [pkg] is null
     * or can't open it). Calls [done] with false if nothing could.
     */
    private fun openWith(activity: Activity, path: String, pkg: String?, done: (Boolean) -> Unit) {
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(File(path).extension.lowercase()) ?: "*/*"
        MediaScannerConnection.scanFile(activity.applicationContext, arrayOf(path), arrayOf(mime)) { _, scanned ->
            activity.runOnUiThread {
                val uri = scanned ?: run { done(false); return@runOnUiThread }
                val i = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                if (pkg != null) {
                    try {
                        activity.startActivity(Intent(i).setPackage(pkg))
                        done(true)
                        return@runOnUiThread
                    } catch (_: Exception) {}
                }
                try {
                    activity.startActivity(Intent.createChooser(i, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    done(true)
                } catch (e: Exception) {
                    done(false)
                }
            }
        }
    }

    /**
     * Starts another app (Brave) as a floating window over the desktop area.
     * Android only honours the size when desktop / freeform windows are on.
     */
    private fun launchBounded(activity: Activity, pkg: String, url: String?, bounds: Rect): Boolean {
        val i = if (url != null) {
            Intent(Intent.ACTION_VIEW, Uri.parse(url)).setPackage(pkg)
        } else {
            activity.packageManager.getLaunchIntentForPackage(pkg)
        } ?: return false
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
        return try {
            val opts = ActivityOptions.makeBasic()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && bounds.width() > 0 && bounds.height() > 0) {
                opts.setLaunchBounds(bounds)
            }
            activity.startActivity(i, opts.toBundle())
            true
        } catch (e: Exception) {
            try {
                activity.startActivity(i)
                true
            } catch (e2: Exception) {
                false
            }
        }
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
