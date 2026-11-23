package com.hatdagger.localhero.core

import kotlin.math.abs

/** Cleans up messy names and guesses artist/title from file names. */
object Names {
    private val junkPatterns = listOf(
        Regex("""[\[(【]\s*(www\.|https?://)?[\w-]+\.(com|net|org|ru|info|me|io|co|to|cc|biz|mobi|in|pk|xyz)[^\])】]*[\])】]""", RegexOption.IGNORE_CASE),
        Regex("""\b(www\.)[\w-]+\.(com|net|org|ru|info|me|io|co|to|cc|biz|mobi|in|pk|xyz)\b""", RegexOption.IGNORE_CASE),
        Regex("""[\[(]\s*(official\s*)?(music\s*|lyric\s*|lyrics\s*|hd\s*|hq\s*|4k\s*)?(video|audio|visuali[sz]er|lyrics?|clip)(\s*hd|\s*hq|\s*4k)?\s*[\])]""", RegexOption.IGNORE_CASE),
        Regex("""[\[(]\s*(hd|hq|4k|1080p|720p|high quality|explicit|clean|free download|download|full song|mp3|audio only)\s*[\])]""", RegexOption.IGNORE_CASE),
        Regex("""[\[(]?\s*\d{2,3}\s*kbps\s*[\])]?""", RegexOption.IGNORE_CASE),
        Regex("""[\[(]\s*[A-Za-z0-9_-]{11}\s*[\])]$"""), // YouTube id in brackets
        Regex("""\s+-\s*copy(\s*\(\d+\))?$""", RegexOption.IGNORE_CASE),
        Regex("""\s+copy(\s*\(\d+\))?$""", RegexOption.IGNORE_CASE),
        Regex("""\s*\(\d\)$"""),                                   // "song (1)"
        Regex("""\s+\[\d\]$"""),
    )
    private val unknownWords = setOf("", "unknown", "<unknown>", "unknown artist", "unknown album", "untitled", "artist", "title", "various", "various artists", "va", "track")

    fun stripExtension(name: String): String {
        val dot = name.lastIndexOf('.')
        return if (dot > 0 && name.length - dot <= 5) name.substring(0, dot) else name
    }

    /** Removes site names, "(Official Video)", bitrates, "copy (2)" etc. */
    fun clean(s: String): String {
        var t = s.replace('_', ' ').replace(Regex("""\s+"""), " ").trim()
        // Dots used as spaces ("artist.song.name") – only if there are no spaces at all.
        if (!t.contains(' ') && t.count { it == '.' } >= 2) t = t.replace('.', ' ')
        repeat(2) { for (p in junkPatterns) t = t.replace(p, " ") }
        t = t.replace(Regex("""\s+"""), " ").trim().trim('-', '–', '—', '.', ' ', '_', '|')
        return fixCase(t)
    }

    /** "ALL CAPS NAME" or "all lower name" → "All Caps Name". Mixed case is left alone. */
    fun fixCase(s: String): String {
        val letters = s.filter { it.isLetter() }
        if (letters.length < 3) return s
        val allUpper = letters.all { it.isUpperCase() }
        val allLower = letters.all { it.isLowerCase() }
        if (!allUpper && !allLower) return s
        if (letters.any { it.code > 0x2FF }) return s // leave non-Latin scripts alone
        val small = setOf("a", "an", "and", "the", "of", "in", "on", "at", "to", "for", "or", "vs", "feat", "ft", "de", "la", "le")
        return s.lowercase().split(' ').mapIndexed { i, w ->
            if (i > 0 && w in small) w else w.replaceFirstChar { it.uppercaseChar() }
        }.joinToString(" ")
    }

    fun isUnknown(s: String): Boolean = s.trim().lowercase() in unknownWords

    /** True when a tag value looks like garbage and shouldn't be trusted. */
    fun looksBad(value: String, fileName: String): Boolean {
        val v = value.trim()
        if (isUnknown(v)) return true
        if (Regex("""^(track|audio|piste|titel|pista)\s*\d+$""", RegexOption.IGNORE_CASE).matches(v)) return true
        if (Regex("""^\d+$""").matches(v)) return true
        if (Regex("""(www\.|https?://|\.com\b|\.mp3$|\.m4a$|\.flac$)""", RegexOption.IGNORE_CASE).containsMatchIn(v)) return true
        if (v.count { it == '_' } >= 2) return true
        if (v.equals(stripExtension(fileName), ignoreCase = true) && Regex("""\s-\s|_""").containsMatchIn(v)) return true
        return false
    }

    data class Guess(val artist: String, val title: String, val trackNo: Int)

    // "05 Song", "5. Song", "5 - Song", "cd1-05 Song". A lone single digit + space ("2 Unlimited") is kept.
    private val numPrefix = Regex("""^\s*(?:cd\s*\d+\s*[-.]?\s*)?(\d{1,3}(?=\s*[.\-_)])|\d{2,3}(?=\s))\s*[.\-_)]?\s*""", RegexOption.IGNORE_CASE)

    /** Guesses artist/title from a file name like "03 - Artist - Song (Official Video) [www.x.com].mp3". */
    fun guessFromFileName(fileName: String, folder: String = ""): Guess {
        var base = clean(stripExtension(fileName))
        var no = 0
        numPrefix.find(base)?.let { m ->
            val rest = base.substring(m.range.last + 1)
            if (rest.isNotBlank() && !Regex("""^\d""").containsMatchIn(rest.trimStart())) {
                no = m.groupValues[1].toInt(); base = rest.trim()
            }
        }
        val parts = base.split(Regex("""\s+[-–—|]\s+|\s*[–—]\s*|\s-(?=\S)|(?<=\S)-\s""")).map { it.trim() }.filter { it.isNotEmpty() }
        var artist = ""; var title = base
        when {
            parts.size == 2 -> { artist = parts[0]; title = parts[1] }
            parts.size >= 3 -> {
                val numIdx = parts.indexOfFirst { Regex("""^\d{1,3}$""").matches(it) }
                if (numIdx in 1 until parts.size - 1) {
                    no = parts[numIdx].toInt(); artist = parts[0]; title = parts.subList(numIdx + 1, parts.size).joinToString(" - ")
                } else {
                    artist = parts[0]; title = parts.subList(1, parts.size).joinToString(" - ")
                }
            }
        }
        if (artist.isEmpty()) artist = artistFromFolder(folder)
        return Guess(fixCase(artist.trim()), fixCase(title.trim()), no)
    }

    /** ".../Artist/Album/" or ".../Artist - Album/" → Artist (ignores generic folder names). */
    fun artistFromFolder(folder: String): String {
        val generic = Regex("""^(music|download|downloads|audio|songs|mp3|media|sdcard|storage|emulated|0|telegram|whatsapp|bluetooth|documents|new folder|misc|other|ringtones|recordings|podcasts|.*\bcd ?\d+)$""", RegexOption.IGNORE_CASE)
        val segs = folder.trim('/').split('/').filter { it.isNotBlank() && !generic.matches(it.trim()) }
        if (segs.isEmpty()) return ""
        val last = segs.last()
        val dash = last.split(Regex("""\s+-\s+"""))
        if (dash.size >= 2) return clean(dash[0])
        return if (segs.size >= 2) clean(segs[segs.size - 2]) else ""
    }

    /** Safe for a file name on Android's shared storage. */
    fun safeFileName(s: String): String =
        s.replace(Regex("""[\\/:*?"<>|\u0000-\u001F]"""), " ").replace(Regex("""\s+"""), " ").trim().trim('.').take(120)

    /** Lowercase, no punctuation, no "feat. X", for matching. */
    fun matchKey(s: String): String {
        var t = clean(s).lowercase()
        t = t.replace(Regex("""[(\[]?\s*\b(feat|ft|featuring|with)\b\.?\s[^)\]]*[)\]]?"""), " ")
        t = t.replace(Regex("""^(the|a)\s+"""), "")
        t = t.replace("&", " and ")
        t = t.replace(Regex("""[^\p{L}\p{N}]+"""), " ").trim()
        return t
    }
}

/** A suggested fix for one song's name / tags / file. */
data class NameFix(
    val track: Track,
    val artist: String,
    val title: String,
    val album: String,
    val newFileName: String,
    val newFolder: String?,      // null = leave where it is
    val reasons: List<String>,
) {
    val changesFile: Boolean get() = newFileName != track.displayName || (newFolder != null && newFolder != track.folder)
    val changesTags: Boolean get() = artist != track.artist || title != track.title || album != track.album
}

object NameFixer {
    /** What the song's artist/title/album really are, best guess. */
    fun bestTags(t: Track): Triple<String, String, String> {
        val guess = Names.guessFromFileName(t.displayName, t.folder)
        val badTitle = Names.looksBad(t.title, t.displayName)
        val badArtist = Names.looksBad(t.artist, t.displayName)
        var title = if (badTitle) guess.title else Names.clean(t.title)
        var artist = if (badArtist) guess.artist else Names.clean(t.artist)
        // Title tag contains "Artist - Title" itself.
        if (!badTitle && (badArtist || artist.isEmpty())) {
            val g2 = Names.guessFromFileName(t.title + ".x")
            if (g2.artist.isNotEmpty()) { artist = g2.artist; title = g2.title }
        }
        // Title repeats the artist: "Artist - Title" while artist tag is set.
        if (artist.isNotEmpty() && title.startsWith("$artist - ", ignoreCase = true)) title = title.substring(artist.length + 3).trim()
        val album = if (Names.looksBad(t.album, t.displayName) || t.album.equals(t.folder.trim('/').substringAfterLast('/'), true) && Names.isUnknown(t.artist)) "" else Names.clean(t.album)
        if (title.isBlank()) title = Names.clean(Names.stripExtension(t.displayName)).ifBlank { t.displayName }
        return Triple(artist, title, album)
    }

    /**
     * Suggests fixes. [organize] also proposes moving into Music/Artist/Album/.
     * Songs that are already fine are not returned.
     */
    fun plan(tracks: List<Track>, organize: Boolean): List<NameFix> {
        val out = ArrayList<NameFix>()
        val taken = HashSet<String>()
        for (t in tracks) taken.add((t.folder + t.displayName).lowercase())
        for (t in tracks) {
            val (artist, title, album) = bestTags(t)
            val reasons = ArrayList<String>()
            if (artist != t.artist) reasons.add(if (Names.looksBad(t.artist, t.displayName)) "artist missing or junk" else "artist tidied")
            if (title != t.title) reasons.add(if (Names.looksBad(t.title, t.displayName)) "title missing or junk" else "title tidied")
            if (album != t.album) reasons.add("album tidied")
            val ext = t.extension.ifEmpty { "mp3" }
            val stem = Names.safeFileName(if (artist.isNotBlank()) "$artist - $title" else title)
            var fileName = if (stem.isBlank()) t.displayName else "$stem.$ext"
            val folder = if (organize) {
                val a = Names.safeFileName(artist).ifBlank { "Unknown Artist" }
                val al = Names.safeFileName(album).ifBlank { "Singles" }
                "Music/$a/$al/"
            } else null
            val targetFolder = folder ?: t.folder
            if (!fileName.equals(t.displayName, ignoreCase = false)) {
                // Avoid clashing with another file in the same target folder.
                var n = 2
                val base = fileName.substringBeforeLast('.')
                while ((targetFolder + fileName).lowercase() in taken && (targetFolder + fileName).lowercase() != (t.folder + t.displayName).lowercase()) {
                    fileName = "$base ($n).$ext"; n++
                }
                reasons.add("rename file")
            }
            if (folder != null && folder != t.folder) reasons.add("move to $folder")
            val fix = NameFix(t, artist, title, album, fileName, folder, reasons)
            if (fix.changesFile || fix.changesTags) {
                taken.remove((t.folder + t.displayName).lowercase())
                taken.add((targetFolder + fileName).lowercase())
                out.add(fix)
            }
        }
        return out
    }
}

/** A set of files that are the same song. */
data class DuplicateGroup(
    val reason: String,
    val keep: Track,
    val extras: List<Track>,
    val sure: Boolean,          // false = "probably", don't pre-select for removal
)

object Duplicates {
    private val junkFolder = Regex("""(download|whatsapp|telegram|bluetooth|temp|tmp|cache|backup|copy|old|\.thumb|recycle)""", RegexOption.IGNORE_CASE)

    /** Higher = better copy to keep. */
    fun quality(t: Track): Double {
        var q = 0.0
        if (t.isLossless) q += 1000
        q += (if (t.bitrate > 0) t.bitrate else if (t.durationMs > 0) (t.sizeBytes * 8000 / t.durationMs).toInt() else 0) / 1000.0
        if (t.album.isNotBlank() && !Names.isUnknown(t.album)) q += 8
        if (t.year > 0) q += 3
        if (t.trackNo > 0) q += 3
        if (t.genre.isNotBlank()) q += 2
        if (!Names.looksBad(t.title, t.displayName)) q += 6
        if (!Names.looksBad(t.artist, t.displayName)) q += 6
        if (!junkFolder.containsMatchIn(t.folder)) q += 5
        if (!Regex("""copy|\(\d\)\.\w+$""", RegexOption.IGNORE_CASE).containsMatchIn(t.displayName)) q += 5
        q -= t.displayName.length / 100.0
        return q
    }

    fun find(tracks: List<Track>, features: Map<Long, Features> = emptyMap(), toleranceMs: Long = 3000): List<DuplicateGroup> {
        val groups = ArrayList<DuplicateGroup>()
        val used = HashSet<Long>()

        fun emit(cluster: List<Track>, reason: String, sure: Boolean) {
            val fresh = cluster.filter { it.id !in used }
            if (fresh.isEmpty()) return
            // Some of these are already in a group: add the new ones to that group.
            val existingIdx = groups.indexOfFirst { g -> cluster.any { c -> c.id == g.keep.id || g.extras.any { it.id == c.id } } }
            if (existingIdx >= 0) {
                val g = groups[existingIdx]
                val all = (listOf(g.keep) + g.extras + fresh).sortedByDescending { quality(it) }
                groups[existingIdx] = DuplicateGroup(g.reason, all.first(), all.drop(1), g.sure && sure)
                fresh.forEach { used.add(it.id) }
                return
            }
            if (fresh.size < 2) return
            val sorted = fresh.sortedByDescending { quality(it) }
            groups.add(DuplicateGroup(reason, sorted.first(), sorted.drop(1), sure))
            fresh.forEach { used.add(it.id) }
        }

        fun clusterByDuration(list: List<Track>, tol: Long): List<List<Track>> {
            val s = list.sortedBy { it.durationMs }
            val out = ArrayList<MutableList<Track>>()
            for (t in s) {
                val last = out.lastOrNull()
                if (last != null && abs(t.durationMs - last.first().durationMs) <= tol) last.add(t) else out.add(mutableListOf(t))
            }
            return out
        }

        // 1. Exact copies: same size and length.
        tracks.groupBy { it.sizeBytes }.values.filter { it.size > 1 && it[0].sizeBytes > 0 }.forEach { g ->
            clusterByDuration(g, 1000).forEach { emit(it, "Exact copy", true) }
        }

        // 2. Same artist + title (after cleanup), same length.
        val byName = HashMap<String, MutableList<Track>>()
        for (t in tracks) {
            val (artist, title, _) = NameFixer.bestTags(t)
            val k = Names.matchKey(artist) + "|" + Names.matchKey(title)
            if (Names.matchKey(title).length < 2) continue
            byName.getOrPut(k) { ArrayList() }.add(t)
        }
        for ((k, g) in byName) if (g.size > 1) {
            val noArtist = k.startsWith("|")
            clusterByDuration(g, toleranceMs).forEach { emit(it, if (noArtist) "Same title & length" else "Same song (name & length)", !noArtist) }
        }

        // 3. Sounds identical (needs analysis): same length, near-identical sound print & tempo.
        val analysed = tracks.filter { it.id !in used && features[it.id] != null }
        for (cl in clusterByDuration(analysed, 1500)) if (cl.size > 1) {
            val left = cl.toMutableList()
            while (left.size > 1) {
                val a = left.removeAt(0)
                val fa = features[a.id]!!
                val match = left.filter { b ->
                    val fb = features[b.id]!!
                    AudioAnalyzer.signatureSimilarity(fa.signature, fb.signature) > 0.992 &&
                        (fa.tempoBpm <= 0 || fb.tempoBpm <= 0 || abs(fa.tempoBpm - fb.tempoBpm) / fa.tempoBpm < 0.03) &&
                        fa.key == fb.key
                }
                if (match.isNotEmpty()) { emit(listOf(a) + match, "Sounds identical", false); left.removeAll(match) }
            }
        }
        return groups.sortedWith(compareByDescending<DuplicateGroup> { it.sure }.thenBy { it.keep.artist.lowercase() })
    }
}
