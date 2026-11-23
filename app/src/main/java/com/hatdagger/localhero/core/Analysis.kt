package com.hatdagger.localhero.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/** In-place radix-2 FFT. re/im length must be a power of two. */
object Fft {
    fun transform(re: DoubleArray, im: DoubleArray) {
        val n = re.size
        var j = 0
        for (i in 1 until n) {
            var bit = n shr 1
            while (j and bit != 0) { j = j xor bit; bit = bit shr 1 }
            j = j xor bit
            if (i < j) {
                var t = re[i]; re[i] = re[j]; re[j] = t
                t = im[i]; im[i] = im[j]; im[j] = t
            }
        }
        var len = 2
        while (len <= n) {
            val ang = -2 * PI / len
            val wr = cos(ang); val wi = sin(ang)
            var i = 0
            while (i < n) {
                var cr = 1.0; var ci = 0.0
                for (k in 0 until len / 2) {
                    val a = i + k; val b = a + len / 2
                    val xr = re[b] * cr - im[b] * ci
                    val xi = re[b] * ci + im[b] * cr
                    re[b] = re[a] - xr; im[b] = im[a] - xi
                    re[a] += xr; im[a] += xi
                    val ncr = cr * wr - ci * wi
                    ci = cr * wi + ci * wr; cr = ncr
                }
                i += len
            }
            len = len shl 1
        }
    }
}

/**
 * Works out tempo, energy, brightness, key and a duplicate "sound print" from a slice of
 * mono audio (about 30–60 s is plenty). Samples are -1..1.
 */
object AudioAnalyzer {
    const val FRAME = 2048
    const val HOP = 1024
    const val SIGNATURE_SEGMENTS = 16

    // Krumhansl–Kessler key profiles.
    private val MAJOR = doubleArrayOf(6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88)
    private val MINOR = doubleArrayOf(6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17)

    fun analyze(samples: FloatArray, sampleRate: Int): Features? {
        val frames = (samples.size - FRAME) / HOP + 1
        if (frames < 32 || sampleRate < 8000) return null
        val window = DoubleArray(FRAME) { 0.5 - 0.5 * cos(2 * PI * it / (FRAME - 1)) }
        val bins = FRAME / 2
        val binHz = sampleRate.toDouble() / FRAME
        // Map each FFT bin to a pitch class (only 55 Hz – 5 kHz is musically useful).
        val pitchClass = IntArray(bins) { b ->
            val f = b * binHz
            if (f < 55 || f > 5000) -1 else (((12 * ln(f / 440.0) / ln(2.0)).let { Math.round(it).toInt() } + 9) % 12 + 12) % 12
        }

        val rms = DoubleArray(frames)
        val flux = DoubleArray(frames)
        val centroid = DoubleArray(frames)
        val chroma = DoubleArray(12)
        var prevMag = DoubleArray(bins)
        val re = DoubleArray(FRAME); val im = DoubleArray(FRAME)

        for (f in 0 until frames) {
            val off = f * HOP
            var sq = 0.0
            for (i in 0 until FRAME) {
                val s = samples[off + i].toDouble()
                sq += s * s
                re[i] = s * window[i]; im[i] = 0.0
            }
            rms[f] = sqrt(sq / FRAME)
            Fft.transform(re, im)
            val mag = DoubleArray(bins)
            var num = 0.0; var den = 0.0; var fl = 0.0
            for (b in 1 until bins) {
                val m = sqrt(re[b] * re[b] + im[b] * im[b])
                mag[b] = m
                num += m * b * binHz; den += m
                val lm = ln(1 + 100 * m); val lp = ln(1 + 100 * prevMag[b])
                if (lm > lp) fl += lm - lp
                val pc = pitchClass[b]
                if (pc >= 0) chroma[pc] += m * m
            }
            centroid[f] = if (den > 1e-9) num / den else 0.0
            flux[f] = fl
            prevMag = mag
        }

        // Loudness and dynamics.
        val db = rms.map { 20 * log10(max(it, 1e-5)) }.sorted()
        val loudDb = db[(db.size * 0.9).toInt().coerceAtMost(db.size - 1)]
        val quietDb = db[(db.size * 0.1).toInt()]
        val loudness = ((loudDb + 40) / 34).coerceIn(0.0, 1.0)        // -40 dB → 0, -6 dB → 1
        val dynamics = ((loudDb - quietDb) / 30).coerceIn(0.0, 1.0)

        // Onsets: peaks in the flux curve above a moving average.
        val fps = sampleRate.toDouble() / HOP
        val fluxMean = flux.average()
        val fluxStd = sqrt(flux.map { (it - fluxMean) * (it - fluxMean) }.average())
        val norm = DoubleArray(frames)
        var onsets = 0
        for (i in 0 until frames) {
            val lo = max(0, i - 8); val hi = min(frames - 1, i + 8)
            var avg = 0.0
            for (k in lo..hi) avg += flux[k]
            avg /= (hi - lo + 1)
            norm[i] = max(0.0, flux[i] - avg)
            val isPeak = i in 1 until frames - 1 && flux[i] > flux[i - 1] && flux[i] >= flux[i + 1]
            if (isPeak && flux[i] > avg + 0.5 * fluxStd) onsets++
        }
        val seconds = frames / fps
        val onsetRate = onsets / seconds

        // Tempo: autocorrelation of the onset curve between 60 and 190 BPM, with a mild
        // preference for 90–140 BPM where most music sits.
        val minLag = max(1, (fps * 60 / 190).toInt()); val maxLag = (fps * 60 / 60).toInt()
        var bestLag = 0; var bestScore = 0.0
        val zero = norm.sumOf { it * it }
        val scores = DoubleArray(maxLag + 2)
        if (zero > 1e-9 && maxLag < frames / 2) {
            for (lag in minLag..maxLag) {
                var s = 0.0
                for (i in 0 until frames - lag) s += norm[i] * norm[i + lag]
                scores[lag] = s / zero
            }
            for (lag in minLag..maxLag) {
                val bpm = 60 * fps / lag
                val pref = 1.0 - 0.25 * min(1.0, abs(ln(bpm / 118.0)) / ln(2.0))
                val sc = scores[lag] * pref
                if (sc > bestScore) { bestScore = sc; bestLag = lag }
            }
        }
        val tempo: Double
        val beatStrength: Double
        if (bestLag > 0) {
            // Refine with parabolic interpolation around the peak.
            val a = scores[bestLag - 1].takeIf { bestLag - 1 >= minLag } ?: scores[bestLag]
            val b = scores[bestLag]
            val c = scores[bestLag + 1].takeIf { bestLag + 1 <= maxLag } ?: scores[bestLag]
            val d = (a - c) / (2 * (a - 2 * b + c)).let { if (abs(it) < 1e-12) 1e12 else it }
            tempo = 60 * fps / (bestLag + d.coerceIn(-0.5, 0.5))
            beatStrength = (b * 2.5).coerceIn(0.0, 1.0)
        } else { tempo = 0.0; beatStrength = 0.0 }

        // Octave check: if hits come about twice as often as the beat we found, the real
        // tempo is probably double (common with sparse drums).
        val tempoFixed = if (tempo > 0 && onsetRate * 60 > 1.6 * tempo && tempo * 2 <= 200) tempo * 2 else tempo

        val avgCentroid = centroid.average()
        val brightness = ((avgCentroid - 800) / 2700).coerceIn(0.0, 1.0)

        // Key and major/minor.
        val chromaSum = chroma.sum()
        var bestKey = 0; var bestMajor = true; var bestCorr = -2.0; var secondCorr = -2.0
        if (chromaSum > 1e-9) {
            val c = DoubleArray(12) { chroma[it] / chromaSum }
            for (k in 0 until 12) for (maj in listOf(true, false)) {
                val prof = if (maj) MAJOR else MINOR
                val r = correlation(c) { prof[(it - k + 12) % 12] }
                if (r > bestCorr) { secondCorr = bestCorr; bestCorr = r; bestKey = k; bestMajor = maj }
                else if (r > secondCorr) secondCorr = r
            }
        }
        val modeStrength = ((bestCorr - secondCorr) * 6 + max(0.0, bestCorr) * 0.5).coerceIn(0.0, 1.0)

        val onsetNorm = (onsetRate / 6).coerceIn(0.0, 1.0)
        val energy = (0.55 * loudness + 0.3 * onsetNorm + 0.15 * brightness).coerceIn(0.0, 1.0)

        // Sound print: loudness shape over 16 segments + pitch balance + brightness.
        val sig = DoubleArray(SIGNATURE_SEGMENTS + 12 + 1)
        val seg = frames / SIGNATURE_SEGMENTS
        val rmsMax = rms.maxOrNull()?.takeIf { it > 1e-9 } ?: 1.0
        for (s in 0 until SIGNATURE_SEGMENTS) {
            var t = 0.0
            for (i in s * seg until (s + 1) * seg) t += rms[i]
            sig[s] = t / max(1, seg) / rmsMax
        }
        for (k in 0 until 12) sig[SIGNATURE_SEGMENTS + k] = if (chromaSum > 0) chroma[k] / chromaSum * 4 else 0.0
        sig[SIGNATURE_SEGMENTS + 12] = brightness

        return Features(energy, tempoFixed, beatStrength, brightness, onsetRate, dynamics, bestKey, bestMajor, modeStrength, sig)
    }

    private fun correlation(x: DoubleArray, y: (Int) -> Double): Double {
        val mx = x.average()
        var my = 0.0
        for (i in 0 until 12) my += y(i)
        my /= 12
        var sxy = 0.0; var sxx = 0.0; var syy = 0.0
        for (i in 0 until 12) {
            val dx = x[i] - mx; val dy = y(i) - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        return if (sxx < 1e-12 || syy < 1e-12) 0.0 else sxy / sqrt(sxx * syy)
    }

    /** 0..1 likeness of two sound prints (1 = same recording). */
    fun signatureSimilarity(a: DoubleArray, b: DoubleArray): Double {
        if (a.isEmpty() || a.size != b.size) return 0.0
        var dot = 0.0; var na = 0.0; var nb = 0.0
        for (i in a.indices) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        if (na < 1e-12 || nb < 1e-12) return 0.0
        return (dot / sqrt(na * nb)).coerceIn(0.0, 1.0)
    }
}

/** Turns features (+ genre words, + the user's own tags) into mood scores. */
object MoodModel {
    data class Point(val arousal: Double, val valence: Double)

    fun point(f: Features): Point {
        val tempoNorm = if (f.tempoBpm <= 0) 0.3 else ((f.tempoBpm - 60) / 120).coerceIn(0.0, 1.0)
        val arousal = (0.55 * f.energy + 0.25 * tempoNorm * (0.5 + 0.5 * f.beatStrength) + 0.2 * (f.onsetRate / 6).coerceIn(0.0, 1.0)).coerceIn(0.0, 1.0)
        val modeTerm = if (f.major) 0.5 + 0.5 * f.modeStrength else 0.5 - 0.5 * f.modeStrength
        val valence = (0.5 * modeTerm + 0.3 * f.brightness + 0.2 * tempoNorm).coerceIn(0.0, 1.0)
        return Point(arousal, valence)
    }

    private val genreHints: List<Pair<Regex, Map<Mood, Double>>> = listOf(
        Regex("metal|hardcore|punk|grind|industrial|drill|dubstep|thrash") to mapOf(Mood.INTENSE to 0.35, Mood.ENERGETIC to 0.1),
        Regex("rock|grunge") to mapOf(Mood.ENERGETIC to 0.15, Mood.INTENSE to 0.1),
        Regex("dance|edm|house|techno|trance|electro|disco|drum ?(and|&|n) ?bass|dnb|eurobeat") to mapOf(Mood.ENERGETIC to 0.3, Mood.UPBEAT to 0.1),
        Regex("pop|funk|soul|motown|reggae|ska|k-?pop|j-?pop") to mapOf(Mood.UPBEAT to 0.25),
        Regex("hip ?hop|rap|trap") to mapOf(Mood.ENERGETIC to 0.15, Mood.INTENSE to 0.1),
        Regex("ambient|chill|lo-?fi|downtempo|new age|lounge|trip ?hop|bossa") to mapOf(Mood.CHILL to 0.3, Mood.FOCUS to 0.15),
        Regex("classical|piano|instrumental|soundtrack|score|orchestral|baroque|post-?rock|game") to mapOf(Mood.FOCUS to 0.3, Mood.CHILL to 0.05),
        Regex("jazz|acoustic|folk|singer|country") to mapOf(Mood.CHILL to 0.15, Mood.UPBEAT to 0.05),
        Regex("blues|emo|sad|slowcore|shoegaze|goth|darkwave") to mapOf(Mood.MELANCHOLY to 0.3),
    )

    /** Mood → score 0..1. A user tag wins outright. */
    fun scores(f: Features?, genre: String, userMood: Mood? = null): Map<Mood, Double> {
        val out = HashMap<Mood, Double>()
        if (f != null) {
            val p = point(f)
            fun near(a: Double, v: Double, spread: Double = 0.28): Double {
                val d2 = (p.arousal - a) * (p.arousal - a) + (p.valence - v) * (p.valence - v)
                return kotlin.math.exp(-d2 / (2 * spread * spread))
            }
            out[Mood.ENERGETIC] = near(0.85, 0.6)
            out[Mood.UPBEAT] = near(0.6, 0.8)
            out[Mood.CHILL] = near(0.25, 0.6)
            out[Mood.MELANCHOLY] = near(0.25, 0.2)
            out[Mood.INTENSE] = near(0.85, 0.25)
            // Focus: calm-to-medium, steady, not too dynamic.
            out[Mood.FOCUS] = 0.85 * near(0.35, 0.45, 0.25) * (1 - 0.4 * f.dynamics)
        } else {
            for (m in Mood.values()) out[m] = 0.2
        }
        val g = genre.lowercase()
        if (g.isNotBlank()) for ((re, hints) in genreHints) if (re.containsMatchIn(g)) {
            for ((m, add) in hints) out[m] = (out[m] ?: 0.0) + add
        }
        if (userMood != null) {
            for (m in Mood.values()) out[m] = (out[m] ?: 0.0) * 0.3
            out[userMood] = 2.0
        }
        return out.mapValues { it.value.coerceIn(0.0, 2.0) }
    }

    fun best(f: Features?, genre: String, userMood: Mood? = null): Mood? {
        if (f == null && userMood == null && genre.isBlank()) return null
        val s = scores(f, genre, userMood)
        val top = s.maxByOrNull { it.value } ?: return null
        return if (f == null && userMood == null && top.value <= 0.21) null else top.key
    }
}
