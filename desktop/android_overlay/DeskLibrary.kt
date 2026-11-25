package __PACKAGE__

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Size
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * The media player's library: songs and videos from Android's media index
 * (the same scan Local Hero uses), plus album art thumbnails.
 */
object DeskLibrary {
    private val worker = Executors.newSingleThreadExecutor()
    private val artWorker = Executors.newFixedThreadPool(2)

    fun register(activity: Activity, engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "desk/library")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> result.success(allowed(activity))
                "askPermission" -> {
                    ask(activity)
                    result.success(null)
                }
                "scan" -> worker.execute {
                    val out: Map<String, Any?> = try {
                        mapOf("permission" to allowed(activity), "audio" to audio(activity), "video" to video(activity))
                    } catch (e: SecurityException) {
                        mapOf("permission" to false, "audio" to emptyList<Any>(), "video" to emptyList<Any>())
                    } catch (e: Exception) {
                        mapOf("permission" to allowed(activity), "audio" to emptyList<Any>(), "video" to emptyList<Any>(),
                            "error" to e.message)
                    }
                    activity.runOnUiThread { result.success(out) }
                }
                "art" -> {
                    val uri = call.argument<String>("uri") ?: ""
                    val size = call.argument<Int>("size") ?: 256
                    artWorker.execute {
                        val bytes = try { art(activity, Uri.parse(uri), size) } catch (e: Throwable) { null }
                        activity.runOnUiThread { result.success(bytes) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun granted(activity: Activity, p: String) =
        Build.VERSION.SDK_INT < 23 || activity.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    private fun allowed(activity: Activity): Boolean {
        if (Build.VERSION.SDK_INT >= 30 && android.os.Environment.isExternalStorageManager()) return true
        return if (Build.VERSION.SDK_INT >= 33) {
            granted(activity, Manifest.permission.READ_MEDIA_AUDIO)
        } else {
            granted(activity, Manifest.permission.READ_EXTERNAL_STORAGE)
        }
    }

    private fun ask(activity: Activity) {
        if (Build.VERSION.SDK_INT < 23) return
        val list = if (Build.VERSION.SDK_INT >= 33) {
            arrayOf(Manifest.permission.READ_MEDIA_AUDIO, Manifest.permission.READ_MEDIA_VIDEO)
        } else {
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
        activity.requestPermissions(list, 63)
    }

    /** Same filter as Local Hero: music, or anything over a minute; no ringtones/alarms. */
    private fun audio(activity: Activity): List<Map<String, Any?>> {
        val base = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val new = Build.VERSION.SDK_INT >= 30
        val cols = mutableListOf(
            MediaStore.Audio.Media._ID, MediaStore.Audio.Media.TITLE, MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM, MediaStore.Audio.Media.ALBUM_ID, MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.SIZE, MediaStore.Audio.Media.MIME_TYPE, MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.DATE_ADDED, MediaStore.Audio.Media.TRACK, MediaStore.Audio.Media.YEAR,
            MediaStore.Audio.Media.DATA,
        )
        if (Build.VERSION.SDK_INT >= 29) cols.add(MediaStore.Audio.Media.RELATIVE_PATH)
        if (new) cols.add(MediaStore.Audio.Media.GENRE)
        val sel = "(${MediaStore.Audio.Media.IS_MUSIC} != 0 OR ${MediaStore.Audio.Media.DURATION} > 60000) AND " +
            "${MediaStore.Audio.Media.IS_RINGTONE} = 0 AND ${MediaStore.Audio.Media.IS_NOTIFICATION} = 0 AND " +
            "${MediaStore.Audio.Media.IS_ALARM} = 0 AND ${MediaStore.Audio.Media.DURATION} > 15000"
        val out = ArrayList<Map<String, Any?>>()
        activity.contentResolver.query(base, cols.toTypedArray(), sel, null, null)?.use { c ->
            fun idx(name: String) = c.getColumnIndex(name)
            val iRel = idx(MediaStore.Audio.Media.RELATIVE_PATH)
            val iGenre = idx(MediaStore.Audio.Media.GENRE)
            while (c.moveToNext()) {
                fun s(i: Int) = if (i < 0) "" else (c.getString(i) ?: "")
                val id = c.getLong(0)
                val artist = s(2).let { if (it == "<unknown>") "" else it }
                out.add(mapOf(
                    "id" to id,
                    "title" to s(1),
                    "artist" to artist,
                    "album" to s(3),
                    "albumId" to c.getLong(4),
                    "duration" to c.getLong(5),
                    "size" to c.getLong(6),
                    "mime" to s(7),
                    "name" to s(8),
                    "added" to c.getLong(9),
                    "track" to c.getInt(10) % 1000,
                    "year" to c.getInt(11),
                    "path" to s(12),
                    "folder" to s(iRel),
                    "genre" to s(iGenre),
                    "uri" to ContentUris.withAppendedId(base, id).toString(),
                ))
            }
        }
        return out
    }

    private fun video(activity: Activity): List<Map<String, Any?>> {
        val base = MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        val cols = mutableListOf(
            MediaStore.Video.Media._ID, MediaStore.Video.Media.TITLE, MediaStore.Video.Media.DURATION,
            MediaStore.Video.Media.SIZE, MediaStore.Video.Media.DISPLAY_NAME, MediaStore.Video.Media.DATE_ADDED,
            MediaStore.Video.Media.DATA,
        )
        if (Build.VERSION.SDK_INT >= 29) cols.add(MediaStore.Video.Media.RELATIVE_PATH)
        val out = ArrayList<Map<String, Any?>>()
        activity.contentResolver.query(base, cols.toTypedArray(), null, null, null)?.use { c ->
            val iRel = c.getColumnIndex(MediaStore.Video.Media.RELATIVE_PATH)
            while (c.moveToNext()) {
                fun s(i: Int) = if (i < 0) "" else (c.getString(i) ?: "")
                val id = c.getLong(0)
                out.add(mapOf(
                    "id" to id,
                    "title" to s(1),
                    "duration" to c.getLong(2),
                    "size" to c.getLong(3),
                    "name" to s(4),
                    "added" to c.getLong(5),
                    "path" to s(6),
                    "folder" to s(iRel),
                    "uri" to ContentUris.withAppendedId(base, id).toString(),
                ))
            }
        }
        return out
    }

    /** A small picture for a song (its album art) or a video (a frame). PNG/JPEG bytes. */
    private fun art(activity: Activity, uri: Uri, size: Int): ByteArray? {
        if (Build.VERSION.SDK_INT < 29) return null
        val bmp: Bitmap = activity.contentResolver.loadThumbnail(uri, Size(size, size), null)
        val bos = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 88, bos)
        return bos.toByteArray()
    }
}
