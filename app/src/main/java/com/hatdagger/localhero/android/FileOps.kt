package com.hatdagger.localhero.android

import android.app.Activity
import android.content.ContentValues
import android.net.Uri
import android.provider.MediaStore
import com.hatdagger.localhero.core.NameFix

/**
 * Changes to real files. Android asks the user to allow each batch (one system dialog), then we
 * rename / move through MediaStore. Deleting always goes to the system trash, which Android empties
 * after 30 days, so mistakes can be recovered from the Files app.
 */
class FileOps(private val activity: Activity) {
    companion object {
        const val REQ_WRITE = 41
        const val REQ_TRASH = 42
    }

    private var pending: ((Boolean) -> Unit)? = null

    fun onResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != REQ_WRITE && requestCode != REQ_TRASH) return false
        val cb = pending; pending = null
        cb?.invoke(resultCode == Activity.RESULT_OK)
        return true
    }

    /** Moves files to the system trash after the user confirms. */
    fun trash(ids: List<Long>, done: (Boolean) -> Unit) {
        if (ids.isEmpty()) { done(false); return }
        val pi = MediaStore.createTrashRequest(activity.contentResolver, ids.map { Hero.uriOf(it) }, true)
        pending = done
        activity.startIntentSenderForResult(pi.intentSender, REQ_TRASH, null, 0, 0, 0)
    }

    /** Asks once for permission to change these files. */
    fun requestWrite(ids: List<Long>, granted: () -> Unit) {
        if (ids.isEmpty()) return
        val pi = MediaStore.createWriteRequest(activity.contentResolver, ids.map { Hero.uriOf(it) })
        pending = { ok -> if (ok) granted() }
        activity.startIntentSenderForResult(pi.intentSender, REQ_WRITE, null, 0, 0, 0)
    }

    /** Renames/moves one file. Returns an error message, or null when it worked. */
    fun applyFileChange(id: Long, newName: String, newFolder: String?): String? {
        val cv = ContentValues()
        cv.put(MediaStore.MediaColumns.DISPLAY_NAME, newName)
        if (newFolder != null) cv.put(MediaStore.MediaColumns.RELATIVE_PATH, newFolder)
        return try {
            val n = activity.contentResolver.update(Hero.uriOf(id), cv, null, null)
            if (n > 0) null else "not changed"
        } catch (e: Exception) { e.message ?: e.javaClass.simpleName }
    }

    /** Applies the chosen fixes (call inside [requestWrite]'s granted callback). */
    fun applyFixes(fixes: List<NameFix>, renameFiles: Boolean): Pair<Int, List<String>> {
        var ok = 0
        val errors = ArrayList<String>()
        val now = System.currentTimeMillis()
        for (f in fixes) {
            Hero.store.setOverride(f.track.id, Store.Override(f.title, f.artist, f.album))
            if (renameFiles && f.changesFile) {
                val err = applyFileChange(f.track.id, f.newFileName, f.newFolder)
                if (err == null) {
                    Hero.store.logRename(f.track.id, f.track.displayName, f.track.folder, f.newFileName, f.newFolder ?: f.track.folder, now)
                    ok++
                } else errors.add("${f.track.displayName}: $err")
            } else ok++
        }
        return ok to errors
    }

    fun uris(ids: List<Long>): List<Uri> = ids.map { Hero.uriOf(it) }
}
