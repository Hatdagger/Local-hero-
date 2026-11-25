package __PACKAGE__

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.provider.Settings
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

    fun register(activity: Activity, engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "desk/platform")
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
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("desk", e.message, null)
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
