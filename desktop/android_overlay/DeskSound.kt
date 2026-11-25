package __PACKAGE__

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

// Local Hero's sound analysis (core/Analysis.kt + android/Hero.kt Decoder),
// copied for ClassicDesk's Auto Mixes. Decodes 40 s from 30% into a song and
// works out energy, tempo, brightness and key. The mood maths is in Dart
// (lib/desk/mixes.dart).

/** In-place radix-2 FFT. re/im length must be a power of two. */
object DeskFft {
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
object DeskAnalyzer {
    const val FRAME = 2048
    const val HOP = 1024

    // Krumhansl–Kessler key profiles.
    private val MAJOR = doubleArrayOf(6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88)
    private val MINOR = doubleArrayOf(6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17)

    fun analyze(samples: FloatArray, sampleRate: Int): Map<String, Any>? {
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
            DeskFft.transform(re, im)
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

        return mapOf(
            "energy" to energy, "tempo" to tempoFixed, "beat" to beatStrength, "bright" to brightness,
            "onsets" to onsetRate, "dyn" to dynamics, "key" to bestKey, "major" to bestMajor, "modeStr" to modeStrength,
        )
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

}


object DeskSound {
    private const val WINDOW_US = 40_000_000L

    fun analyze(ctx: Context, uri: Uri, durationMs: Long): Map<String, Any>? {
        val ex = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            ex.setDataSource(ctx, uri, null)
            var trackIdx = -1
            var fmt: MediaFormat? = null
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                if ((f.getString(MediaFormat.KEY_MIME) ?: "").startsWith("audio/")) { trackIdx = i; fmt = f; break }
            }
            if (trackIdx < 0 || fmt == null) return null
            ex.selectTrack(trackIdx)
            val durUs = if (fmt.containsKey(MediaFormat.KEY_DURATION)) fmt.getLong(MediaFormat.KEY_DURATION) else durationMs * 1000
            val startUs = if (durUs > WINDOW_US + 10_000_000) minOf((durUs * 0.3).toLong(), durUs - WINDOW_US - 5_000_000) else 0L
            if (startUs > 0) ex.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

            val mime = fmt.getString(MediaFormat.KEY_MIME)!!
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(fmt, null, null, 0)
            codec.start()

            var rate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var isFloat = false
            val info = MediaCodec.BufferInfo()
            var out = FloatArray(0)
            var n = 0
            var inputDone = false
            var firstPtsUs = -1L
            val deadline = System.currentTimeMillis() + 20_000

            while (System.currentTimeMillis() < deadline) {
                if (!inputDone) {
                    val inIdx = codec.dequeueInputBuffer(5_000)
                    if (inIdx >= 0) {
                        val buf = codec.getInputBuffer(inIdx)!!
                        val size = ex.readSampleData(buf, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputDone = true
                        } else {
                            codec.queueInputBuffer(inIdx, 0, size, ex.sampleTime, 0); ex.advance()
                        }
                    }
                }
                val outIdx = codec.dequeueOutputBuffer(info, 5_000)
                if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val of = codec.outputFormat
                    rate = of.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = of.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    isFloat = of.containsKey(MediaFormat.KEY_PCM_ENCODING) && of.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                } else if (outIdx >= 0) {
                    if (firstPtsUs < 0) firstPtsUs = info.presentationTimeUs
                    if (out.isEmpty()) out = FloatArray((rate * (WINDOW_US / 1_000_000)).toInt() + rate)
                    val buf = codec.getOutputBuffer(outIdx)!!.order(ByteOrder.LITTLE_ENDIAN)
                    buf.position(info.offset); buf.limit(info.offset + info.size)
                    val ch = maxOf(1, channels)
                    if (isFloat) {
                        val fb = buf.asFloatBuffer()
                        val frames = fb.remaining() / ch
                        for (i in 0 until frames) {
                            if (n >= out.size) break
                            var s = 0f
                            for (c in 0 until ch) s += fb.get(i * ch + c)
                            out[n++] = s / ch
                        }
                    } else {
                        val sb = buf.asShortBuffer()
                        val frames = sb.remaining() / ch
                        for (i in 0 until frames) {
                            if (n >= out.size) break
                            var s = 0f
                            for (c in 0 until ch) s += sb.get(i * ch + c) / 32768f
                            out[n++] = s / ch
                        }
                    }
                    codec.releaseOutputBuffer(outIdx, false)
                    if (n >= out.size || info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
            if (n < rate * 8) return null
            // Halve high sample rates to keep the maths quick.
            var samples = out.copyOf(n)
            var sr = rate
            while (sr > 32000) {
                val half = FloatArray(samples.size / 2) { (samples[2 * it] + samples[2 * it + 1]) * 0.5f }
                samples = half; sr /= 2
            }
            return DeskAnalyzer.analyze(samples, sr)
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            ex.release()
        }
    }

    // ---------------------------------------------------------------- visualizer

    const val SPECTRUM_FPS = 30
    const val SPECTRUM_BANDS = 24
    private const val SPEC_FFT = 1024

    /**
     * Decodes the whole song and returns its spectrum over time for the visualizer:
     * [SPECTRUM_BANDS] bytes (0..255, log-spaced 40 Hz - 16 kHz) per 1/30 s, so the
     * desktop can draw bars in step with playback without microphone permission.
     */
    fun spectrum(ctx: Context, uri: Uri): ByteArray? {
        val ex = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            ex.setDataSource(ctx, uri, null)
            var fmt: MediaFormat? = null
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                if ((f.getString(MediaFormat.KEY_MIME) ?: "").startsWith("audio/")) { ex.selectTrack(i); fmt = f; break }
            }
            if (fmt == null) return null
            val durUs = if (fmt.containsKey(MediaFormat.KEY_DURATION)) fmt.getLong(MediaFormat.KEY_DURATION) else 0L
            if (durUs > 20L * 60 * 1_000_000) return null // very long mixes: skip
            codec = MediaCodec.createDecoderByType(fmt.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(fmt, null, null, 0)
            codec.start()

            var rate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var isFloat = false
            val out = java.io.ByteArrayOutputStream()
            val win = DoubleArray(SPEC_FFT) { 0.5 - 0.5 * cos(2 * PI * it / (SPEC_FFT - 1)) }
            val ring = FloatArray(SPEC_FFT)
            var ringPos = 0
            var filled = 0
            var sinceFrame = 0.0
            var hop = 0.0
            var edges = IntArray(0)
            var level = 0.0 // running loudest band, for scaling
            val re = DoubleArray(SPEC_FFT); val im = DoubleArray(SPEC_FFT)
            // Halve high sample rates on the fly.
            var decim = 1
            var acc = 0f; var accN = 0

            fun setup() {
                decim = 1
                while (rate / decim > 32000) decim *= 2
                val sr = rate.toDouble() / decim
                hop = sr / SPECTRUM_FPS
                val binHz = sr / SPEC_FFT
                val top = min(16000.0, sr / 2 * 0.95)
                edges = IntArray(SPECTRUM_BANDS + 1) { b ->
                    val f = 40.0 * Math.pow(top / 40.0, b.toDouble() / SPECTRUM_BANDS)
                    max(1, (f / binHz).toInt())
                }
                for (b in 1..SPECTRUM_BANDS) if (edges[b] <= edges[b - 1]) edges[b] = edges[b - 1] + 1
            }
            setup()

            fun frame() {
                for (i in 0 until SPEC_FFT) {
                    re[i] = ring[(ringPos + i) % SPEC_FFT] * win[i]; im[i] = 0.0
                }
                DeskFft.transform(re, im)
                val bands = DoubleArray(SPECTRUM_BANDS)
                for (b in 0 until SPECTRUM_BANDS) {
                    var m = 0.0
                    val hi = min(edges[b + 1], SPEC_FFT / 2)
                    for (k in edges[b] until hi) m = max(m, sqrt(re[k] * re[k] + im[k] * im[k]))
                    // Tilt up the treble a little so the right side isn't always flat.
                    bands[b] = 20 * log10(max(m * (1 + b * 0.08), 1e-4))
                }
                val loud = bands.maxOrNull() ?: -80.0
                level = if (loud > level) loud else level - 0.02 // slow decay
                for (b in 0 until SPECTRUM_BANDS) {
                    val v = ((bands[b] - (level - 50)) / 50).coerceIn(0.0, 1.0)
                    out.write((v * 255).toInt())
                }
            }

            fun push(sample: Float) {
                acc += sample; accN++
                if (accN < decim) return
                ring[ringPos] = acc / accN
                ringPos = (ringPos + 1) % SPEC_FFT
                acc = 0f; accN = 0
                if (filled < SPEC_FFT) filled++
                sinceFrame += 1.0
                if (sinceFrame >= hop) {
                    sinceFrame -= hop
                    frame()
                }
            }

            val info = MediaCodec.BufferInfo()
            var inputDone = false
            val deadline = System.currentTimeMillis() + 45_000
            while (System.currentTimeMillis() < deadline) {
                if (!inputDone) {
                    val inIdx = codec.dequeueInputBuffer(5_000)
                    if (inIdx >= 0) {
                        val buf = codec.getInputBuffer(inIdx)!!
                        val size = ex.readSampleData(buf, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputDone = true
                        } else {
                            codec.queueInputBuffer(inIdx, 0, size, ex.sampleTime, 0); ex.advance()
                        }
                    }
                }
                val outIdx = codec.dequeueOutputBuffer(info, 5_000)
                if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val of = codec.outputFormat
                    rate = of.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = of.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    isFloat = of.containsKey(MediaFormat.KEY_PCM_ENCODING) && of.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                    setup()
                } else if (outIdx >= 0) {
                    val buf = codec.getOutputBuffer(outIdx)!!.order(ByteOrder.LITTLE_ENDIAN)
                    buf.position(info.offset); buf.limit(info.offset + info.size)
                    val ch = maxOf(1, channels)
                    if (isFloat) {
                        val fb = buf.asFloatBuffer()
                        val frames = fb.remaining() / ch
                        for (i in 0 until frames) {
                            var s = 0f
                            for (c in 0 until ch) s += fb.get(i * ch + c)
                            push(s / ch)
                        }
                    } else {
                        val sb = buf.asShortBuffer()
                        val frames = sb.remaining() / ch
                        for (i in 0 until frames) {
                            var s = 0f
                            for (c in 0 until ch) s += sb.get(i * ch + c) / 32768f
                            push(s / ch)
                        }
                    }
                    codec.releaseOutputBuffer(outIdx, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
            return if (out.size() >= SPECTRUM_BANDS * SPECTRUM_FPS) out.toByteArray() else null
        } catch (e: Exception) {
            return null
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            ex.release()
        }
    }
}
