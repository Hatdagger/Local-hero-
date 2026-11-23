package com.hatdagger.localhero.android

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import com.hatdagger.localhero.core.Features
import com.hatdagger.localhero.core.Mood
import com.hatdagger.localhero.core.PlayEvent

/** The app's own database: play history, analysis results, moods, playlists, name fixes. */
class Store(ctx: Context) : SQLiteOpenHelper(ctx, "localhero.db", null, 1) {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE plays (track_id INTEGER, started_at INTEGER, played_ms INTEGER, duration_ms INTEGER, completed INTEGER)")
        db.execSQL("CREATE INDEX plays_track ON plays(track_id)")
        db.execSQL("CREATE TABLE features (track_id INTEGER PRIMARY KEY, size INTEGER, data TEXT)")
        db.execSQL("CREATE TABLE moods (track_id INTEGER PRIMARY KEY, mood TEXT)")
        db.execSQL("CREATE TABLE playlists (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, created INTEGER)")
        db.execSQL("CREATE TABLE playlist_items (playlist_id INTEGER, pos INTEGER, track_id INTEGER)")
        db.execSQL("CREATE TABLE overrides (track_id INTEGER PRIMARY KEY, title TEXT, artist TEXT, album TEXT)")
        db.execSQL("CREATE TABLE renames (id INTEGER PRIMARY KEY AUTOINCREMENT, track_id INTEGER, old_name TEXT, old_folder TEXT, new_name TEXT, new_folder TEXT, at INTEGER)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {}

    // ---- plays
    fun addPlay(e: PlayEvent) {
        writableDatabase.insert("plays", null, ContentValues().apply {
            put("track_id", e.trackId); put("started_at", e.startedAtMs); put("played_ms", e.playedMs)
            put("duration_ms", e.durationMs); put("completed", if (e.completed) 1 else 0)
        })
    }

    fun plays(): List<PlayEvent> {
        val out = ArrayList<PlayEvent>()
        readableDatabase.rawQuery("SELECT track_id, started_at, played_ms, duration_ms, completed FROM plays", null).use { c ->
            while (c.moveToNext()) out.add(PlayEvent(c.getLong(0), c.getLong(1), c.getLong(2), c.getLong(3), c.getInt(4) == 1))
        }
        return out
    }

    // ---- features (size is stored so a changed file gets re-analysed)
    fun putFeatures(id: Long, size: Long, f: Features?) {
        writableDatabase.insertWithOnConflict("features", null, ContentValues().apply {
            put("track_id", id); put("size", size); put("data", f?.toCsv() ?: "")
        }, SQLiteDatabase.CONFLICT_REPLACE)
    }

    /** id → (size, features or null if the file couldn't be decoded). */
    fun features(): Map<Long, Pair<Long, Features?>> {
        val out = HashMap<Long, Pair<Long, Features?>>()
        readableDatabase.rawQuery("SELECT track_id, size, data FROM features", null).use { c ->
            while (c.moveToNext()) {
                val d = c.getString(2) ?: ""
                out[c.getLong(0)] = c.getLong(1) to (if (d.isEmpty()) null else Features.fromCsv(d))
            }
        }
        return out
    }

    // ---- user mood tags
    fun setMood(id: Long, mood: Mood?) {
        if (mood == null) writableDatabase.delete("moods", "track_id=?", arrayOf(id.toString()))
        else writableDatabase.insertWithOnConflict("moods", null, ContentValues().apply { put("track_id", id); put("mood", mood.name) }, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun moods(): Map<Long, Mood> {
        val out = HashMap<Long, Mood>()
        readableDatabase.rawQuery("SELECT track_id, mood FROM moods", null).use { c ->
            while (c.moveToNext()) runCatching { Mood.valueOf(c.getString(1)) }.getOrNull()?.let { out[c.getLong(0)] = it }
        }
        return out
    }

    // ---- tag overrides (cleaned names shown in the app)
    data class Override(val title: String, val artist: String, val album: String)

    fun setOverride(id: Long, o: Override?) {
        if (o == null) writableDatabase.delete("overrides", "track_id=?", arrayOf(id.toString()))
        else writableDatabase.insertWithOnConflict("overrides", null, ContentValues().apply {
            put("track_id", id); put("title", o.title); put("artist", o.artist); put("album", o.album)
        }, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun overrides(): Map<Long, Override> {
        val out = HashMap<Long, Override>()
        readableDatabase.rawQuery("SELECT track_id, title, artist, album FROM overrides", null).use { c ->
            while (c.moveToNext()) out[c.getLong(0)] = Override(c.getString(1) ?: "", c.getString(2) ?: "", c.getString(3) ?: "")
        }
        return out
    }

    // ---- playlists
    data class Playlist(val id: Long, val name: String, val trackIds: List<Long>)

    fun playlists(): List<Playlist> {
        val items = HashMap<Long, MutableList<Long>>()
        readableDatabase.rawQuery("SELECT playlist_id, track_id FROM playlist_items ORDER BY playlist_id, pos", null).use { c ->
            while (c.moveToNext()) items.getOrPut(c.getLong(0)) { ArrayList() }.add(c.getLong(1))
        }
        val out = ArrayList<Playlist>()
        readableDatabase.rawQuery("SELECT id, name FROM playlists ORDER BY created DESC", null).use { c ->
            while (c.moveToNext()) out.add(Playlist(c.getLong(0), c.getString(1), items[c.getLong(0)] ?: emptyList()))
        }
        return out
    }

    fun createPlaylist(name: String, ids: List<Long>): Long {
        val id = writableDatabase.insert("playlists", null, ContentValues().apply { put("name", name); put("created", System.currentTimeMillis()) })
        setPlaylistTracks(id, ids)
        return id
    }

    fun setPlaylistTracks(id: Long, ids: List<Long>) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.delete("playlist_items", "playlist_id=?", arrayOf(id.toString()))
            ids.forEachIndexed { i, t ->
                db.insert("playlist_items", null, ContentValues().apply { put("playlist_id", id); put("pos", i); put("track_id", t) })
            }
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }

    fun renamePlaylist(id: Long, name: String) {
        writableDatabase.update("playlists", ContentValues().apply { put("name", name) }, "id=?", arrayOf(id.toString()))
    }

    fun deletePlaylist(id: Long) {
        writableDatabase.delete("playlist_items", "playlist_id=?", arrayOf(id.toString()))
        writableDatabase.delete("playlists", "id=?", arrayOf(id.toString()))
    }

    // ---- rename log (for undo)
    data class Rename(val id: Long, val trackId: Long, val oldName: String, val oldFolder: String, val newName: String, val newFolder: String, val at: Long)

    fun logRename(trackId: Long, oldName: String, oldFolder: String, newName: String, newFolder: String, at: Long) {
        writableDatabase.insert("renames", null, ContentValues().apply {
            put("track_id", trackId); put("old_name", oldName); put("old_folder", oldFolder)
            put("new_name", newName); put("new_folder", newFolder); put("at", at)
        })
    }

    fun renames(): List<Rename> {
        val out = ArrayList<Rename>()
        readableDatabase.rawQuery("SELECT id, track_id, old_name, old_folder, new_name, new_folder, at FROM renames ORDER BY id DESC", null).use { c ->
            while (c.moveToNext()) out.add(Rename(c.getLong(0), c.getLong(1), c.getString(2), c.getString(3), c.getString(4), c.getString(5), c.getLong(6)))
        }
        return out
    }

    fun deleteRenames(ids: Collection<Long>) {
        for (id in ids) writableDatabase.delete("renames", "id=?", arrayOf(id.toString()))
    }
}
