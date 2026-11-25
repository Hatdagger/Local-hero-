package __PACKAGE__

import android.app.Activity
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteOrder
import java.util.concurrent.Executors
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.tanh
import kotlin.random.Random

/**
 * Penis Music: plays really fast drums and cartoon sound effects live, in time with the
 * song the Media Player is playing. Nothing is written to the music files.
 *
 * "beat"  - finds a song's tempo and where its beats fall (decodes 30 s from 30% in).
 * "start" / "sync" / "stop" - the effects engine follows the player's position.
 */
object DeskPenis {
    private val worker = Executors.newSingleThreadExecutor()

    fun register(activity: Activity, engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "desk/penis")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "beat" -> {
                    val uri = call.argument<String>("uri") ?: ""
                    val duration = (call.argument<Number>("duration") ?: 0).toLong()
                    worker.execute {
                        val r = try { findBeat(activity, Uri.parse(uri), duration) } catch (e: Throwable) { null }
                        activity.runOnUiThread { result.success(r) }
                    }
                }
                "sync" -> {
                    Engine.sync(
                        bpm = (call.argument<Number>("bpm") ?: 0).toDouble(),
                        beat0Ms = (call.argument<Number>("beat0") ?: 0).toDouble(),
                        posMs = (call.argument<Number>("pos") ?: 0).toDouble(),
                        playing = call.argument<Boolean>("playing") ?: false,
                        rate = (call.argument<Number>("rate") ?: 1).toDouble(),
                        drums = call.argument<Int>("drums") ?: 1,
                        sfx = call.argument<Int>("sfx") ?: 1,
                        bass = call.argument<Boolean>("bass") ?: true,
                        volume = (call.argument<Number>("volume") ?: 0.8).toDouble(),
                    )
                    result.success(null)
                }
                "stop" -> {
                    Engine.stop()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // ---------------------------------------------------------------- beat finding

    /** {bpm, beat0} where beat0 is the time (ms into the song) of one beat. */
    fun findBeat(ctx: Context, uri: Uri, durationMs: Long): Map<String, Any>? {
        val dec = decode(ctx, uri, durationMs, 30_000_000L) ?: return null
        val (samples, sr, startMs) = dec
        val hop = 256
        val frames = samples.size / hop - 1
        if (frames < 400) return null
        // Onset strength: rise in energy, low end weighted (kicks/bass), per hop.
        val env = DoubleArray(frames)
        var prev = 0.0
        var lp = 0.0
        val a = exp(-2 * PI * 200 / sr)
        for (f in 0 until frames) {
            var e = 0.0; var el = 0.0
            for (i in f * hop until (f + 1) * hop) {
                val s = samples[i].toDouble()
                lp = a * lp + (1 - a) * s
                e += s * s; el += lp * lp
            }
            val v = ln(1 + 1000 * (e + 3 * el) / hop)
            env[f] = max(0.0, v - prev)
            prev = v
        }
        // Remove the moving average so steady loudness doesn't count.
        val norm = DoubleArray(frames)
        for (i in 0 until frames) {
            val lo = max(0, i - 16); val hi = min(frames - 1, i + 16)
            var avg = 0.0
            for (k in lo..hi) avg += env[k]
            norm[i] = max(0.0, env[i] - avg / (hi - lo + 1))
        }
        val fps = sr.toDouble() / hop
        val minLag = (fps * 60 / 180).toInt(); val maxLag = (fps * 60 / 75).toInt()
        var bestLag = 0; var best = 0.0
        val scores = DoubleArray(maxLag + 2)
        for (lag in minLag..maxLag) {
            var s = 0.0
            for (i in 0 until frames - lag) s += norm[i] * norm[i + lag]
            scores[lag] = s
            val bpm = 60 * fps / lag
            val pref = 1.0 - 0.3 * min(1.0, abs(ln(bpm / 120.0)) / ln(2.0))
            if (s * pref > best) { best = s * pref; bestLag = lag }
        }
        if (bestLag == 0) return null
        // Refine the period a little.
        val l0 = scores[bestLag - 1]; val l1 = scores[bestLag]; val l2 = scores[bestLag + 1]
        val den = l0 - 2 * l1 + l2
        val period = bestLag + if (abs(den) > 1e-12) ((l0 - l2) / (2 * den)).coerceIn(-0.5, 0.5) else 0.0
        // Phase: the offset whose comb of beats lines up with the most onsets.
        var bestPhase = 0; var bestSum = -1.0
        for (p in 0 until bestLag) {
            var s = 0.0
            var t = p.toDouble()
            while (t < frames) {
                val i = t.toInt()
                s += norm[i] + 0.5 * (if (i + 1 < frames) norm[i + 1] else 0.0)
                t += period
            }
            if (s > bestSum) { bestSum = s; bestPhase = p }
        }
        val bpm = 60 * fps / period
        val beat0 = startMs + bestPhase * 1000.0 / fps
        return mapOf("bpm" to bpm, "beat0" to beat0)
    }

    private fun decode(ctx: Context, uri: Uri, durationMs: Long, windowUs: Long): Triple<FloatArray, Int, Double>? {
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
            val durUs = if (fmt.containsKey(MediaFormat.KEY_DURATION)) fmt.getLong(MediaFormat.KEY_DURATION) else durationMs * 1000
            val startUs = if (durUs > windowUs + 10_000_000) min((durUs * 0.3).toLong(), durUs - windowUs - 5_000_000) else 0L
            if (startUs > 0) ex.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            codec = MediaCodec.createDecoderByType(fmt.getString(MediaFormat.KEY_MIME)!!)
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
                    if (firstPtsUs < 0 && info.size > 0) firstPtsUs = info.presentationTimeUs
                    if (out.isEmpty()) out = FloatArray((rate * (windowUs / 1_000_000)).toInt())
                    val buf = codec.getOutputBuffer(outIdx)!!.order(ByteOrder.LITTLE_ENDIAN)
                    buf.position(info.offset); buf.limit(info.offset + info.size)
                    val ch = max(1, channels)
                    if (isFloat) {
                        val fb = buf.asFloatBuffer()
                        for (i in 0 until fb.remaining() / ch) {
                            if (n >= out.size) break
                            var s = 0f
                            for (c in 0 until ch) s += fb.get(i * ch + c)
                            out[n++] = s / ch
                        }
                    } else {
                        val sb = buf.asShortBuffer()
                        for (i in 0 until sb.remaining() / ch) {
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
            var samples = out.copyOf(n)
            var sr = rate
            while (sr > 24000) {
                samples = FloatArray(samples.size / 2) { (samples[2 * it] + samples[2 * it + 1]) * 0.5f }
                sr /= 2
            }
            return Triple(samples, sr, max(0L, firstPtsUs) / 1000.0)
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            ex.release()
        }
    }

    // ---------------------------------------------------------------- live engine

    private object Engine {
        const val SR = 44100
        const val CHUNK = 512

        @Volatile private var bpm = 0.0
        @Volatile private var beat0 = 0.0
        @Volatile private var anchorSong = 0.0      // song ms at anchorNs
        @Volatile private var anchorNs = 0L
        @Volatile private var playing = false
        @Volatile private var rate = 1.0
        @Volatile private var drums = 1             // 0 fast, 1 faster, 2 ludicrous
        @Volatile private var sfx = 1               // 0 none .. 3 chaos
        @Volatile private var bass = true
        @Volatile private var volume = 0.8
        @Volatile private var running = false
        private var thread: Thread? = null
        private var lastGrid = Long.MIN_VALUE

        fun sync(bpm: Double, beat0Ms: Double, posMs: Double, playing: Boolean, rate: Double,
                 drums: Int, sfx: Int, bass: Boolean, volume: Double) {
            val jump = abs(songNow() - posMs) > 120
            if (bpm != this.bpm || beat0Ms != this.beat0) lastGrid = Long.MIN_VALUE
            this.bpm = bpm; this.beat0 = beat0Ms; this.rate = rate
            this.drums = drums; this.sfx = sfx; this.bass = bass; this.volume = volume
            // Only re-anchor when we've drifted or jumped, to avoid jitter.
            if (jump || !this.playing || !playing) {
                anchorSong = posMs; anchorNs = System.nanoTime()
                if (jump) lastGrid = Long.MIN_VALUE
            }
            this.playing = playing
            if (!running) start()
        }

        fun songNow(): Double =
            if (!playing) anchorSong else anchorSong + (System.nanoTime() - anchorNs) / 1e6 * rate

        fun stop() {
            running = false
            thread = null
        }

        private fun start() {
            running = true
            val t = Thread({ loop() }, "penis-music")
            t.priority = Thread.MAX_PRIORITY
            thread = t
            t.start()
        }

        private fun loop() {
            val minBuf = AudioTrack.getMinBufferSize(SR, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
            val track = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                .setAudioFormat(AudioFormat.Builder()
                    .setSampleRate(SR).setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
                .setBufferSizeInBytes(max(minBuf, CHUNK * 4 * 4))
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            val bufFrames = max(minBuf, CHUNK * 4 * 4) / 4
            val latencyMs = bufFrames * 1000.0 / SR
            track.play()
            val pcm = ShortArray(CHUNK * 2)
            val voices = ArrayList<Voice>()
            val rnd = Random(System.nanoTime())
            try {
                while (running) {
                    val on = playing && bpm > 40
                    // The song time this chunk will actually be heard at.
                    val t0 = songNow() + latencyMs * rate
                    val msPerSample = 1000.0 / SR * rate
                    if (on) schedule(t0, t0 + CHUNK * msPerSample, msPerSample, voices, rnd)
                    val vol = volume
                    for (i in 0 until CHUNK) {
                        var l = 0.0; var r = 0.0
                        val it = voices.iterator()
                        while (it.hasNext()) {
                            val v = it.next()
                            if (v.delay > 0) { v.delay--; continue }
                            val s = v.next()
                            l += s * (1 - v.pan); r += s * (1 + v.pan)
                            if (v.done) it.remove()
                        }
                        pcm[2 * i] = (tanh(l * vol) * 30000).toInt().toShort()
                        pcm[2 * i + 1] = (tanh(r * vol) * 30000).toInt().toShort()
                    }
                    if (!on && voices.isEmpty()) {
                        // Silence while paused; keep the track primed.
                        java.util.Arrays.fill(pcm, 0)
                    }
                    track.write(pcm, 0, pcm.size)
                }
            } finally {
                track.stop(); track.release()
            }
        }

        /** Adds the hits that fall in song time [t0, t1). */
        private fun schedule(t0: Double, t1: Double, msPerSample: Double, voices: MutableList<Voice>, rnd: Random) {
            val beatMs = 60000.0 / bpm
            val div = if (drums >= 2) 8 else 4            // grid steps per beat
            val step = beatMs / div
            var g = Math.floor((t0 - beat0) / step).toLong()
            if (lastGrid != Long.MIN_VALUE && g <= lastGrid) g = lastGrid + 1
            while (true) {
                val t = beat0 + g * step
                if (t >= t1) break
                if (t >= t0 - step) {
                    lastGrid = g
                    val delay = max(0, ((t - t0) / msPerSample).toInt())
                    hits(g, div, delay, voices, rnd)
                }
                g++
            }
        }

        private fun hits(g: Long, div: Int, delay: Int, voices: MutableList<Voice>, rnd: Random) {
            val pos = Math.floorMod(g, (div * 16).toLong()).toInt()  // 4 bars
            val inBeat = pos % div
            val beat = pos / div                                     // 0..15
            val barBeat = beat % 4
            val lastBeatOf4Bars = beat == 15
            val half = div / 2
            // Kick: every beat; faster = every 8th; ludicrous = every 16th (gabber roll).
            val kickEvery = when (drums) { 0 -> div; 1 -> half; else -> div / 4 }
            if (inBeat % kickEvery == 0) voices.add(Voice.kick(delay))
            // Hi-hats on every step, accented on the 8ths.
            voices.add(Voice.hat(delay, if (inBeat % half == 0) 0.35 else 0.2, rnd))
            // Snare on 2 and 4, and a roll to end every 4 bars.
            if (inBeat == 0 && (barBeat == 1 || barBeat == 3)) voices.add(Voice.snare(delay, 0.8, rnd))
            if (lastBeatOf4Bars || (drums >= 1 && beat == 7 && inBeat >= half)) {
                voices.add(Voice.snare(delay, 0.35 + 0.5 * inBeat / div, rnd))
            }
            // Rubbery bass on the off-beats (the Rubber Band bounce).
            if (bass && inBeat == half) voices.add(Voice.rubber(delay, if (barBeat % 2 == 0) 98.0 else 73.4))
            // Cartoon sounds.
            if (sfx > 0 && inBeat == 0) {
                val chance = when (sfx) { 1 -> 0.12; 2 -> 0.3; else -> 0.6 }
                if ((barBeat == 0 || sfx >= 3) && rnd.nextDouble() < chance) voices.add(Voice.cartoon(delay, rnd))
            }
            if (voices.size > 64) voices.subList(0, voices.size - 64).clear()
        }
    }

    // ---------------------------------------------------------------- sounds

    private class Voice(val length: Int, var delay: Int, val pan: Double, val gen: (Int) -> Double) {
        var i = 0
        val done get() = i >= length
        fun next(): Double = if (i < length) gen(i++) else 0.0

        companion object {
            const val SR = 44100.0
            private fun t(i: Int) = i / SR

            fun kick(delay: Int): Voice {
                var ph = 0.0
                return Voice((0.22 * SR).toInt(), delay, 0.0) { i ->
                    val tt = t(i)
                    ph += 2 * PI * (48 + 140 * exp(-tt * 35)) / SR
                    sin(ph) * exp(-tt * 14) * 0.9 + (if (i < 60) 0.3 * (1 - i / 60.0) else 0.0)
                }
            }

            fun snare(delay: Int, amp: Double, rnd: Random): Voice {
                val seed = rnd.nextInt()
                val r = Random(seed)
                return Voice((0.16 * SR).toInt(), delay, 0.05) { i ->
                    val tt = t(i)
                    (r.nextDouble(-1.0, 1.0) * exp(-tt * 20) * 0.6 + sin(2 * PI * 190 * tt) * exp(-tt * 30) * 0.4) * amp
                }
            }

            fun hat(delay: Int, amp: Double, rnd: Random): Voice {
                val r = Random(rnd.nextInt())
                var prev = 0.0
                return Voice((0.04 * SR).toInt(), delay, 0.3) { i ->
                    val n = r.nextDouble(-1.0, 1.0)
                    val hp = n - prev; prev = n
                    hp * exp(-t(i) * 90) * amp
                }
            }

            /** A bouncy "boing-ish" bass note that bends down. */
            fun rubber(delay: Int, base: Double): Voice {
                var ph = 0.0
                return Voice((0.18 * SR).toInt(), delay, 0.0) { i ->
                    val tt = t(i)
                    val f = base * (1.6 - 0.6 * min(1.0, tt * 18)) * (1 + 0.04 * sin(2 * PI * 9 * tt))
                    ph += 2 * PI * f / SR
                    val wave = sin(ph) + 0.35 * sin(2 * ph) + 0.15 * sin(3 * ph)
                    wave * min(1.0, tt * 400) * exp(-tt * 9) * 0.55
                }
            }

            fun cartoon(delay: Int, rnd: Random): Voice = when (rnd.nextInt(6)) {
                0 -> boing(delay)
                1 -> slideWhistle(delay, up = true)
                2 -> slideWhistle(delay, up = false)
                3 -> honk(delay)
                4 -> pop(delay)
                else -> wobble(delay)
            }

            fun boing(delay: Int): Voice {
                var ph = 0.0
                return Voice((0.7 * SR).toInt(), delay, -0.2) { i ->
                    val tt = t(i)
                    val f = 180 * (1 + 0.6 * sin(2 * PI * 14 * tt) * exp(-tt * 4)) * (1 + tt)
                    ph += 2 * PI * f / SR
                    sin(ph) * exp(-tt * 4) * 0.6
                }
            }

            fun slideWhistle(delay: Int, up: Boolean): Voice {
                var ph = 0.0
                val len = 0.55
                return Voice((len * SR).toInt(), delay, 0.25) { i ->
                    val tt = t(i)
                    val x = tt / len
                    val f = (if (up) 600 + 1500 * x else 2100 - 1500 * x) * (1 + 0.015 * sin(2 * PI * 6 * tt))
                    ph += 2 * PI * f / SR
                    val env = min(1.0, tt * 30) * min(1.0, (len - tt) * 20)
                    (sin(ph) + 0.05 * sin(3 * ph)) * env * 0.35
                }
            }

            fun honk(delay: Int): Voice {
                var ph = 0.0
                return Voice((0.34 * SR).toInt(), delay, -0.3) { i ->
                    val tt = t(i)
                    val f = if (tt < 0.15) 330.0 else 415.0
                    ph += 2 * PI * f / SR
                    val wave = sin(ph) + 0.5 * sin(3 * ph) + 0.3 * sin(5 * ph) + 0.2 * sin(7 * ph)
                    val local = if (tt < 0.15) tt else tt - 0.17
                    val env = if (tt in 0.15..0.17) 0.0 else min(1.0, local * 80) * exp(-local * 6)
                    wave * env * 0.3
                }
            }

            fun pop(delay: Int): Voice {
                var ph = 0.0
                return Voice((0.06 * SR).toInt(), delay, 0.2) { i ->
                    val tt = t(i)
                    ph += 2 * PI * (1200 - 900 * tt / 0.06) / SR
                    sin(ph) * exp(-tt * 50) * 0.7
                }
            }

            fun wobble(delay: Int): Voice {
                var ph = 0.0
                return Voice((0.5 * SR).toInt(), delay, 0.0) { i ->
                    val tt = t(i)
                    val f = 90 + 50 * sin(2 * PI * 10 * tt)
                    ph += 2 * PI * f / SR
                    val wave = sin(ph) + 0.4 * sin(2 * ph)
                    wave * min(1.0, tt * 100) * exp(-tt * 3) * 0.5
                }
            }
        }
    }
}
