package com.hatdagger.localhero.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.TimeZone
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.pow
import kotlin.math.sin
import kotlin.random.Random

class CoreTest {
    private val sr = 22050

    /** A drum-ish click every beat plus a sustained chord. */
    private fun synth(bpm: Double, seconds: Int, chordHz: List<Double>, clickGain: Double = 0.8): FloatArray {
        val n = sr * seconds
        val out = FloatArray(n)
        val beat = 60.0 / bpm
        val rnd = Random(1)
        for (i in 0 until n) {
            val t = i.toDouble() / sr
            var s = 0.0
            for (f in chordHz) s += 0.12 * sin(2 * PI * f * t)
            val sinceBeat = t % beat
            if (sinceBeat < 0.05) s += clickGain * exp(-sinceBeat * 80) * (rnd.nextDouble() * 2 - 1)
            out[i] = s.coerceIn(-1.0, 1.0).toFloat()
        }
        return out
    }

    private fun note(midi: Int) = 440.0 * 2.0.pow((midi - 69) / 12.0)

    @Test fun fftFindsSine() {
        val n = 1024
        val re = DoubleArray(n) { sin(2 * PI * 50 * it / n) }
        val im = DoubleArray(n)
        Fft.transform(re, im)
        val mags = (0 until n / 2).map { re[it] * re[it] + im[it] * im[it] }
        assertEquals(50, mags.indices.maxByOrNull { mags[it] })
    }

    @Test fun tempoDetected() {
        for (bpm in listOf(90.0, 120.0, 150.0)) {
            val f = AudioAnalyzer.analyze(synth(bpm, 30, listOf(note(60), note(64), note(67))), sr)
            assertNotNull(f)
            val ratio = f!!.tempoBpm / bpm
            assertTrue("bpm $bpm got ${f.tempoBpm}", abs(ratio - 1) < 0.04 || abs(ratio - 2) < 0.08 || abs(ratio - 0.5) < 0.03)
        }
    }

    @Test fun majorVsMinor() {
        val maj = AudioAnalyzer.analyze(synth(100.0, 20, listOf(note(60), note(64), note(67), note(72)), 0.1), sr)!!
        val min = AudioAnalyzer.analyze(synth(100.0, 20, listOf(note(57), note(60), note(64), note(69)), 0.1), sr)!!
        assertTrue(maj.major); assertEquals(0, maj.key)
        assertFalse(min.major); assertEquals(9, min.key)
    }

    @Test fun featuresRoundTrip() {
        val f = AudioAnalyzer.analyze(synth(128.0, 20, listOf(note(62))), sr)!!
        val back = Features.fromCsv(f.toCsv())!!
        assertEquals(f.key, back.key)
        assertEquals(f.signature.size, back.signature.size)
        assertTrue(AudioAnalyzer.signatureSimilarity(f.signature, back.signature) > 0.999)
    }

    @Test fun loudFastIsEnergetic() {
        val loud = AudioAnalyzer.analyze(synth(170.0, 20, listOf(note(64), note(68), note(71)), 1.0).map { (it * 1.5f).coerceIn(-1f, 1f) }.toFloatArray(), sr)!!
        val soft = AudioAnalyzer.analyze(synth(70.0, 20, listOf(note(57), note(60), note(64)), 0.05).map { it * 0.15f }.toFloatArray(), sr)!!
        assertTrue(loud.energy > soft.energy)
        val loudMood = MoodModel.best(loud, "")
        val softMood = MoodModel.best(soft, "")
        assertTrue("loud=$loudMood", loudMood == Mood.ENERGETIC || loudMood == Mood.INTENSE || loudMood == Mood.UPBEAT)
        assertTrue("soft=$softMood", softMood == Mood.CHILL || softMood == Mood.MELANCHOLY || softMood == Mood.FOCUS)
        assertEquals(Mood.FOCUS, MoodModel.best(soft, "", Mood.FOCUS))
    }

    @Test fun cleanNames() {
        assertEquals("Song Name", Names.clean("Song Name (Official Music Video) [www.mp3site.com]"))
        assertEquals("Song Name", Names.clean("song_name_320kbps"))
        assertEquals("Hello World", Names.clean("HELLO WORLD - Copy"))
        assertEquals("Track", Names.clean("Track (1)"))
    }

    @Test fun guessFromFileNames() {
        var g = Names.guessFromFileName("03 - Daft Punk - One More Time (Official Video).mp3")
        assertEquals("Daft Punk", g.artist); assertEquals("One More Time", g.title); assertEquals(3, g.trackNo)
        g = Names.guessFromFileName("daft_punk_-_around_the_world.mp3")
        assertEquals("Daft Punk", g.artist); assertEquals("Around the World", g.title)
        g = Names.guessFromFileName("Daft Punk - Discovery - 07 - Superheroes.flac")
        assertEquals("Daft Punk", g.artist); assertEquals("Superheroes", g.title); assertEquals(7, g.trackNo)
        g = Names.guessFromFileName("05. Aerodynamic.mp3", "Music/Daft Punk/Discovery/")
        assertEquals("Daft Punk", g.artist); assertEquals("Aerodynamic", g.title)
        g = Names.guessFromFileName("Blur - Song 2.mp3")
        assertEquals("Blur", g.artist); assertEquals("Song 2", g.title)
        g = Names.guessFromFileName("2 Unlimited - No Limit.mp3")
        assertEquals("2 Unlimited", g.artist); assertEquals("No Limit", g.title)
    }

    private fun t(id: Long, title: String, artist: String, name: String, dur: Long = 200_000, size: Long = id * 1000, folder: String = "Music/", bitrate: Int = 128_000, album: String = "") =
        Track(id, title, artist, album, durationMs = dur, sizeBytes = size, displayName = name, folder = folder, bitrate = bitrate)

    @Test fun planFixesBadNames() {
        val tracks = listOf(
            t(1, "Track 01", "<unknown>", "01 - Blur - Song 2 [www.free.com].mp3"),
            t(2, "Song 2", "Blur", "Blur - Song 2.mp3"),
            t(3, "Girls & Boys", "Blur", "girls.mp3"),
        )
        val plan = NameFixer.plan(tracks, organize = false)
        val p1 = plan.first { it.track.id == 1L }
        assertEquals("Blur", p1.artist); assertEquals("Song 2", p1.title)
        assertEquals("Blur - Song 2 (2).mp3", p1.newFileName) // clash with track 2 avoided
        assertTrue(plan.none { it.track.id == 2L })
        assertEquals("Blur - Girls & Boys.mp3", plan.first { it.track.id == 3L }.newFileName)
        val org = NameFixer.plan(listOf(tracks[1].copy(album = "Blur")), organize = true)
        assertEquals("Music/Blur/Blur/", org.single().newFolder)
    }

    @Test fun findsDuplicates() {
        val tracks = listOf(
            t(1, "Song 2", "Blur", "Blur - Song 2.mp3", 122_000, 5_000_000, "Music/Blur/", 320_000, "Blur"),
            t(2, "Track 01", "", "blur_-_song_2_(official_video).mp3", 121_000, 2_000_000, "Download/", 128_000),
            t(3, "Song 2", "Blur", "Blur - Song 2 - Copy.mp3", 122_000, 5_000_000, "Music/Old/", 320_000, "Blur"),
            t(4, "Song 2 (Live)", "Blur", "Blur - Song 2 Live.mp3", 150_000, 6_000_000),
            t(5, "Beetlebum", "Blur", "beetlebum.mp3", 305_000, 7_000_000),
        )
        val groups = Duplicates.find(tracks)
        val ids = groups.flatMap { listOf(it.keep) + it.extras }.map { it.id }.toSet()
        assertEquals(setOf(1L, 2L, 3L), ids)
        assertTrue(groups.all { it.keep.id == 1L })
    }

    @Test fun habitsAndMixes() {
        val now = 1_700_000_000_000L
        val day = 86_400_000L
        val lib = (1L..20L).map { t(it, "Song $it", "Artist ${it % 5}", "s$it.mp3", dur = 200_000).copy(dateAddedSec = it) }
        val events = ArrayList<PlayEvent>()
        repeat(6) { events.add(PlayEvent(1, now - it * day, 200_000, 200_000, true)) }   // loved, recent
        repeat(4) { events.add(PlayEvent(2, now - 60 * day - it * day, 200_000, 200_000, true)) } // loved, old
        repeat(5) { events.add(PlayEvent(3, now - it * day, 5_000, 200_000, false)) }      // always skipped
        val h = Habits(events, now, TimeZone.getTimeZone("UTC"))
        assertTrue(h.skipRate(3) > 0.9)
        val mm = MixMaker(lib, emptyMap(), h, random = Random(3))
        assertEquals(1L, mm.onRepeat().tracks.first().id)
        assertEquals(listOf(2L), mm.forgottenFavorites(now).tracks.map { it.id })
        assertTrue(mm.freshFinds().tracks.none { it.id in setOf(1L, 2L, 3L) })
        val spread = mm.spreadArtists(lib)
        for (i in 1 until spread.size) assertFalse(spread[i].artist == spread[i - 1].artist)
    }

    @Test fun moodMixUsesFeatures() {
        val calm = AudioAnalyzer.analyze(synth(70.0, 20, listOf(note(57), note(60), note(64)), 0.05).map { it * 0.15f }.toFloatArray(), sr)!!
        val loud = AudioAnalyzer.analyze(synth(170.0, 20, listOf(note(64), note(68), note(71)), 1.0), sr)!!
        val lib = (1L..10L).map { t(it, "S$it", "A$it", "s$it.mp3") }
        val feats = lib.associate { it.id to if (it.id <= 5) calm else loud }
        val mm = MixMaker(lib, feats, Habits(emptyList(), 0), random = Random(1))
        val chill = mm.moodMix(Mood.MELANCHOLY).tracks.map { it.id }
        assertTrue(chill.isNotEmpty() && chill.all { it <= 5 })
        val energetic = mm.moodMix(Mood.ENERGETIC).tracks.map { it.id }
        assertTrue(energetic.isNotEmpty() && energetic.all { it > 5 })
    }
}
