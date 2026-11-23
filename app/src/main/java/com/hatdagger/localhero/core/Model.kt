package com.hatdagger.localhero.core

/** One song file on the device, as the library sees it (tags may be overridden by the user). */
data class Track(
    val id: Long,
    val title: String,
    val artist: String,
    val album: String,
    val genre: String = "",
    val year: Int = 0,
    val trackNo: Int = 0,
    val durationMs: Long = 0,
    val sizeBytes: Long = 0,
    val bitrate: Int = 0,          // bits per second, 0 = unknown
    val mimeType: String = "",
    val displayName: String = "",  // file name, e.g. "01 track.mp3"
    val folder: String = "",       // relative folder, e.g. "Music/Downloads/"
    val dateAddedSec: Long = 0,
    val albumId: Long = 0,
) {
    val extension: String get() = displayName.substringAfterLast('.', "").lowercase()
    val isLossless: Boolean
        get() = extension in setOf("flac", "wav", "alac", "aiff", "aif", "ape") ||
            mimeType.contains("flac") || mimeType.contains("wav")
}

/** One time a song was played (or skipped). */
data class PlayEvent(
    val trackId: Long,
    val startedAtMs: Long,
    val playedMs: Long,
    val durationMs: Long,
    val completed: Boolean,
) {
    /** Skipped = abandoned early: under 30 s, or under a quarter of the song, without finishing. */
    val skipped: Boolean
        get() = !completed && (playedMs < 30_000 || (durationMs > 0 && playedMs < durationMs / 4))
}

enum class Mood(val label: String, val emoji: String) {
    ENERGETIC("Energetic", "⚡"),
    UPBEAT("Upbeat", "☀"),
    CHILL("Chill", "☁"),
    MELANCHOLY("Melancholy", "☂"),
    INTENSE("Intense", "🔥"),
    FOCUS("Focus", "◎"),
}

/** What the audio analysis found for one song. All 0..1 values unless noted. */
data class Features(
    val energy: Double,          // loudness + punch
    val tempoBpm: Double,        // beats per minute (0 = no clear beat)
    val beatStrength: Double,    // how clear/regular the beat is
    val brightness: Double,      // treble vs bass balance
    val onsetRate: Double,       // note/drum hits per second
    val dynamics: Double,        // quiet-to-loud spread
    val key: Int,                // 0 = C … 11 = B
    val major: Boolean,
    val modeStrength: Double,    // how sure the key/mode guess is
    val signature: DoubleArray,  // short "sound print" used to spot duplicates
) {
    override fun equals(other: Any?) = other is Features && other.toCsv() == toCsv()
    override fun hashCode() = toCsv().hashCode()

    fun toCsv(): String = buildString {
        append(listOf(energy, tempoBpm, beatStrength, brightness, onsetRate, dynamics).joinToString(",") { "%.4f".format(java.util.Locale.US, it) })
        append(",").append(key).append(",").append(if (major) 1 else 0).append(",")
        append("%.4f".format(java.util.Locale.US, modeStrength))
        append(";").append(signature.joinToString(",") { "%.4f".format(java.util.Locale.US, it) })
    }

    companion object {
        fun fromCsv(s: String): Features? = try {
            val (a, b) = s.split(";", limit = 2)
            val p = a.split(",")
            Features(
                p[0].toDouble(), p[1].toDouble(), p[2].toDouble(), p[3].toDouble(), p[4].toDouble(), p[5].toDouble(),
                p[6].toInt(), p[7] == "1", p[8].toDouble(),
                if (b.isBlank()) DoubleArray(0) else b.split(",").map { it.toDouble() }.toDoubleArray(),
            )
        } catch (e: Exception) { null }
    }
}
