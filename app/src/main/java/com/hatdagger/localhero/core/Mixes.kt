package com.hatdagger.localhero.core

import java.util.Calendar
import java.util.TimeZone
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.random.Random

/** What the listening history says about each song. */
class Habits(events: List<PlayEvent>, private val nowMs: Long, private val tz: TimeZone = TimeZone.getDefault()) {
    class Stat {
        var plays = 0; var completes = 0; var skips = 0
        var lastPlayedMs = 0L; var firstPlayedMs = Long.MAX_VALUE
        var affinity = 0.0        // decayed like/dislike signal
        var recent = 0.0          // plays in the last ~2 weeks, decayed
        val hours = DoubleArray(24)
        val days = DoubleArray(7)
    }

    val byTrack: Map<Long, Stat>
    /** Overall share of listening per hour of day, 0..1 sums to 1. */
    val hourShare = DoubleArray(24)

    init {
        val m = HashMap<Long, Stat>()
        val cal = Calendar.getInstance(tz)
        var total = 0.0
        for (e in events) {
            val s = m.getOrPut(e.trackId) { Stat() }
            val ageDays = max(0.0, (nowMs - e.startedAtMs) / 86_400_000.0)
            val decay = exp(-ageDays * ln(2.0) / 45)            // 45-day half-life
            s.plays++
            if (e.completed) s.completes++
            if (e.skipped) s.skips++
            s.lastPlayedMs = max(s.lastPlayedMs, e.startedAtMs)
            s.firstPlayedMs = minOf(s.firstPlayedMs, e.startedAtMs)
            val signal = when {
                e.completed -> 1.0
                e.skipped -> -1.0
                else -> 0.4
            }
            s.affinity += signal * decay
            s.recent += if (e.skipped) 0.0 else exp(-ageDays * ln(2.0) / 7)
            if (!e.skipped) {
                cal.timeInMillis = e.startedAtMs
                val h = cal.get(Calendar.HOUR_OF_DAY)
                s.hours[h] += 1.0
                s.days[cal.get(Calendar.DAY_OF_WEEK) - 1] += 1.0
                hourShare[h] += 1.0; total += 1.0
            }
        }
        if (total > 0) for (i in 0 until 24) hourShare[i] /= total
        byTrack = m
    }

    operator fun get(id: Long): Stat? = byTrack[id]

    fun skipRate(id: Long): Double = byTrack[id]?.let { if (it.plays == 0) 0.0 else it.skips.toDouble() / it.plays } ?: 0.0

    /** How much this song fits a given hour (±1 h smoothing), 0..1. */
    fun hourFit(id: Long, hour: Int): Double {
        val s = byTrack[id] ?: return 0.0
        val n = s.hours.sum()
        if (n < 1) return 0.0
        val near = s.hours[hour] + 0.5 * s.hours[(hour + 23) % 24] + 0.5 * s.hours[(hour + 1) % 24]
        return (near / n).coerceIn(0.0, 1.0)
    }
}

/** A generated playlist. */
data class Mix(val key: String, val title: String, val subtitle: String, val tracks: List<Track>)

/** Builds playlists from the library, the audio features and listening habits. */
class MixMaker(
    private val library: List<Track>,
    private val features: Map<Long, Features>,
    private val habits: Habits,
    private val userMoods: Map<Long, Mood> = emptyMap(),
    private val random: Random = Random.Default,
) {
    private val dayMs = 86_400_000L

    fun moodScore(t: Track, mood: Mood): Double =
        MoodModel.scores(features[t.id], t.genre, userMoods[t.id])[mood] ?: 0.0

    /** Positive if the user tends to finish it, negative if they skip it. */
    private fun liking(t: Track): Double {
        val s = habits[t.id] ?: return 0.0
        return (s.affinity / 4).coerceIn(-1.0, 1.0)
    }

    fun moodMix(mood: Mood, size: Int = 40): Mix {
        val scored = library.map { t ->
            val m = moodScore(t, mood)
            val known = features.containsKey(t.id) || userMoods.containsKey(t.id)
            t to (m + 0.25 * liking(t) - 0.4 * habits.skipRate(t.id) + if (known) 0.0 else -0.3) + random.nextDouble() * 0.12
        }.filter { it.second > 0.35 }
            .sortedByDescending { it.second }
            .take(size)
            .map { it.first }
        val ordered = if (mood == Mood.ENERGETIC || mood == Mood.INTENSE) flow(scored, rising = true) else flow(scored, rising = false)
        return Mix("mood:${mood.name}", "${mood.emoji} ${mood.label}", "${ordered.size} songs picked by sound", ordered)
    }

    /** Songs played a lot lately. */
    fun onRepeat(size: Int = 30): Mix {
        val list = library.filter { (habits[it.id]?.recent ?: 0.0) > 0.5 }
            .sortedByDescending { (habits[it.id]?.recent ?: 0.0) + 0.3 * liking(it) }
            .take(size)
        return Mix("habit:repeat", "On repeat", "What you've played most lately", spreadArtists(list))
    }

    /** Liked songs you haven't heard in a while. */
    fun forgottenFavorites(nowMs: Long, size: Int = 30): Mix {
        val list = library.filter {
            val s = habits[it.id] ?: return@filter false
            s.completes >= 2 && nowMs - s.lastPlayedMs > 30 * dayMs && s.skips * 2 < s.plays
        }.sortedByDescending { (habits[it.id]!!.completes.toDouble()) + random.nextDouble() }
            .take(size)
        return Mix("habit:forgotten", "Forgotten favourites", "Songs you loved but haven't played in a month+", spreadArtists(list))
    }

    /** Fits what you usually play at this time of day. */
    fun rightNow(hour: Int, size: Int = 30): Mix {
        // What moods do you usually play at this hour?
        val moodWeight = HashMap<Mood, Double>()
        for (t in library) {
            val fit = habits.hourFit(t.id, hour)
            if (fit <= 0) continue
            val s = MoodModel.scores(features[t.id], t.genre, userMoods[t.id])
            for ((m, v) in s) moodWeight[m] = (moodWeight[m] ?: 0.0) + fit * v
        }
        val total = moodWeight.values.sum()
        val list = library.map { t ->
            val direct = habits.hourFit(t.id, hour)
            val moodFit = if (total > 0) {
                val s = MoodModel.scores(features[t.id], t.genre, userMoods[t.id])
                s.entries.sumOf { (m, v) -> v * (moodWeight[m] ?: 0.0) } / total
            } else 0.0
            t to (1.2 * direct + 0.6 * moodFit + 0.2 * liking(t) - 0.5 * habits.skipRate(t.id) + random.nextDouble() * 0.15)
        }.sortedByDescending { it.second }.take(size).map { it.first }
        val label = when (hour) {
            in 5..11 -> "Morning"; in 12..16 -> "Afternoon"; in 17..21 -> "Evening"; else -> "Late night"
        }
        return Mix("habit:now", "$label mix", "Based on what you play around this time", spreadArtists(list))
    }

    /** Never played, newest first. */
    fun freshFinds(size: Int = 40): Mix {
        val list = library.filter { habits[it.id] == null }
            .sortedByDescending { it.dateAddedSec }.take(size)
        return Mix("habit:fresh", "Fresh finds", "In your library but never played", spreadArtists(list))
    }

    /** Songs that sound like the given one, weighted toward ones you like. */
    fun soundsLike(seed: Track, size: Int = 30): Mix {
        val sf = features[seed.id]
        val sp = sf?.let { MoodModel.point(it) }
        val list = library.filter { it.id != seed.id }.map { t ->
            val f = features[t.id]
            var score = 0.0
            if (sf != null && f != null && sp != null) {
                val p = MoodModel.point(f)
                val d = abs(p.arousal - sp.arousal) + abs(p.valence - sp.valence)
                val tempoClose = if (sf.tempoBpm > 0 && f.tempoBpm > 0) 1 - (abs(ln(f.tempoBpm / sf.tempoBpm)) / ln(2.0)).coerceIn(0.0, 1.0) else 0.5
                score = 1.2 - d + 0.3 * tempoClose
            }
            if (t.artist.equals(seed.artist, true) && t.artist.isNotBlank()) score += 0.25
            if (t.genre.equals(seed.genre, true) && t.genre.isNotBlank()) score += 0.2
            t to (score + 0.15 * liking(t) + random.nextDouble() * 0.1)
        }.sortedByDescending { it.second }.take(size - 1).map { it.first }
        return Mix("like:${seed.id}", "Like “${seed.title}”", "Songs that sound similar", listOf(seed) + spreadArtists(list))
    }

    fun all(nowMs: Long, hour: Int): List<Mix> {
        val habitMixes = listOf(rightNow(hour), onRepeat(), forgottenFavorites(nowMs), freshFinds())
        val moodMixes = Mood.values().map { moodMix(it) }
        return (habitMixes + moodMixes).filter { it.tracks.size >= 3 }
    }

    /** Orders songs so energy changes gently instead of jumping around. */
    fun flow(list: List<Track>, rising: Boolean): List<Track> {
        if (list.size < 3) return list
        val withE = list.map { it to (features[it.id]?.energy ?: 0.5) }
        val sorted = if (rising) withE.sortedBy { it.second } else withE.sortedByDescending { it.second }
        // Interleave lightly so it's not a perfectly monotone ramp, then fix artist repeats.
        val out = ArrayList<Track>(list.size)
        val chunks = sorted.chunked(4)
        for (c in chunks) out.addAll(c.shuffled(random).map { it.first })
        return spreadArtists(out)
    }

    /** Avoid the same artist twice in a row where possible. */
    fun spreadArtists(list: List<Track>): List<Track> {
        val pool = list.toMutableList()
        val out = ArrayList<Track>(list.size)
        while (pool.isNotEmpty()) {
            val last = out.lastOrNull()?.artist
            val idx = pool.indexOfFirst { last == null || !it.artist.equals(last, true) || it.artist.isBlank() }
            out.add(pool.removeAt(if (idx >= 0) idx else 0))
        }
        return out
    }
}
