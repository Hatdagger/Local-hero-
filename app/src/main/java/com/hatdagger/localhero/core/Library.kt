package com.hatdagger.localhero.core

enum class SortBy(val label: String) {
    TITLE("Title"), ARTIST("Artist"), ALBUM("Album"), RECENT("Recently added"), MOST_PLAYED("Most played"), LENGTH("Length"), FOLDER("Folder")
}

enum class GroupBy(val label: String) { SONGS("Songs"), ALBUMS("Albums"), ARTISTS("Artists"), GENRES("Genres"), FOLDERS("Folders"), MOODS("Moods") }

/** A browsable bucket: one album, one artist, one folder... */
data class Bucket(val name: String, val sub: String, val tracks: List<Track>, val albumId: Long = 0)

object LibraryOps {
    private fun sortKey(s: String) = s.lowercase().removePrefix("the ").trim()

    fun sort(list: List<Track>, by: SortBy, plays: (Long) -> Int = { 0 }): List<Track> = when (by) {
        SortBy.TITLE -> list.sortedBy { sortKey(it.title) }
        SortBy.ARTIST -> list.sortedWith(compareBy<Track> { sortKey(it.artist) }.thenBy { sortKey(it.album) }.thenBy { it.trackNo }.thenBy { sortKey(it.title) })
        SortBy.ALBUM -> list.sortedWith(compareBy<Track> { sortKey(it.album) }.thenBy { it.trackNo }.thenBy { sortKey(it.title) })
        SortBy.RECENT -> list.sortedByDescending { it.dateAddedSec }
        SortBy.MOST_PLAYED -> list.sortedWith(compareByDescending<Track> { plays(it.id) }.thenBy { sortKey(it.title) })
        SortBy.LENGTH -> list.sortedByDescending { it.durationMs }
        SortBy.FOLDER -> list.sortedWith(compareBy<Track> { it.folder.lowercase() }.thenBy { it.displayName.lowercase() })
    }

    /** Every word must appear in title, artist, album, genre or file name. */
    fun search(list: List<Track>, query: String): List<Track> {
        val words = query.lowercase().split(Regex("""\s+""")).filter { it.isNotBlank() }
        if (words.isEmpty()) return list
        return list.filter { t ->
            val hay = "${t.title} ${t.artist} ${t.album} ${t.genre} ${t.displayName}".lowercase()
            words.all { hay.contains(it) }
        }
    }

    fun group(list: List<Track>, by: GroupBy, moodOf: (Track) -> Mood? = { null }): List<Bucket> = when (by) {
        GroupBy.SONGS -> emptyList()
        GroupBy.ALBUMS -> list.groupBy { it.album.ifBlank { "Unknown album" } to it.artist.lowercase() }
            .map { (k, v) -> Bucket(k.first, v.first().artist.ifBlank { "Unknown artist" } + " · ${v.size} songs", v.sortedWith(compareBy<Track> { it.trackNo }.thenBy { it.title.lowercase() }), v.first().albumId) }
            .sortedBy { sortKey(it.name) }
        GroupBy.ARTISTS -> list.groupBy { it.artist.ifBlank { "Unknown artist" }.lowercase() }
            .map { (_, v) -> Bucket(v.first().artist.ifBlank { "Unknown artist" }, "${v.map { it.album }.distinct().size} albums · ${v.size} songs", sort(v, SortBy.ARTIST)) }
            .sortedBy { sortKey(it.name) }
        GroupBy.GENRES -> list.groupBy { it.genre.ifBlank { "No genre" }.lowercase() }
            .map { (_, v) -> Bucket(v.first().genre.ifBlank { "No genre" }, "${v.size} songs", sort(v, SortBy.ARTIST)) }
            .sortedBy { sortKey(it.name) }
        GroupBy.FOLDERS -> list.groupBy { it.folder }
            .map { (k, v) -> Bucket(k.trimEnd('/').substringAfterLast('/').ifBlank { "/" }, k + " · ${v.size} songs", v.sortedBy { it.displayName.lowercase() }) }
            .sortedBy { it.sub.lowercase() }
        GroupBy.MOODS -> {
            val m = list.groupBy { moodOf(it) }
            Mood.values().mapNotNull { mood -> m[mood]?.let { Bucket("${mood.emoji} ${mood.label}", "${it.size} songs", sort(it, SortBy.ARTIST)) } } +
                listOfNotNull(m[null]?.let { Bucket("Not analysed yet", "${it.size} songs", sort(it, SortBy.ARTIST)) })
        }
    }

    fun formatTime(ms: Long): String {
        val s = ms / 1000
        return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
    }
}
