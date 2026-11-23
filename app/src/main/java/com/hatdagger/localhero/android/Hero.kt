package com.hatdagger.localhero.android

import android.content.ContentUris
import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.MediaStore
import com.hatdagger.localhero.core.AudioAnalyzer
import com.hatdagger.localhero.core.Features
import com.hatdagger.localhero.core.Habits
import com.hatdagger.localhero.core.MixMaker
import com.hatdagger.localhero.core.Mood
import com.hatdagger.localhero.core.MoodModel
import com.hatdagger.localhero.core.PlayEvent
import com.hatdagger.localhero.core.Track
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** App-wide state: the library, analysis, moods, habits. Lives as long as the process. */
object Hero {
    lateinit var app: Context; private set
    lateinit var store: Store; private set
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val analysisThread = Executors.newSingleThreadExecutor { r -> Thread { Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND); r.run() }.apply { name = "analyzer" } }

    /** Tags exactly as in the files (used by Tidy). */
    @Volatile var raw: List<Track> = emptyList(); private set
    /** Tags with the user's fixes applied (shown everywhere else). */
    @Volatile var tracks: List<Track> = emptyList(); private set
    @Volatile var byId: Map<Long, Track> = emptyMap(); private set
    val features = ConcurrentHashMap<Long, Features>()
    private val analysedSize = ConcurrentHashMap<Long, Long>()
    @Volatile var moods: Map<Long, Mood> = emptyMap(); private set
    @Volatile var habits: Habits = Habits(emptyList(), 0); private set
    @Volatile var scanned = false; private set

    @Volatile var analysing = false; private set
    @Volatile var analysisDone = 0; private set
    @Volatile var analysisTotal = 0; private set
    private val stopAnalysis = AtomicBoolean(false)

    private val listeners = ArrayList<() -> Unit>()
    fun listen(l: () -> Unit) { listeners.add(l) }
    fun unlisten(l: () -> Unit) { listeners.remove(l) }
    private fun changed() = main.post { listeners.toList().forEach { it() } }

    private var started = false
    fun init(ctx: Context) {
        if (started) return
        started = true
        app = ctx.applicationContext
        store = Store(app)
    }

    fun uriOf(id: Long): Uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)

    fun moodOf(t: Track): Mood? = MoodModel.best(features[t.id], t.genre, moods[t.id])

    fun playCount(id: Long): Int = habits[id]?.plays ?: 0

    fun mixMaker(): MixMaker = MixMaker(tracks, HashMap(features), habits, moods)

    /** Re-reads the music library and the app's database, then starts analysing new songs. */
    fun refresh(then: (() -> Unit)? = null) {
        io.execute {
            try {
                val list = Scanner.scan(app)
                val ov = store.overrides()
                raw = list
                applyOverrides(ov)
                val f = store.features()
                features.clear(); analysedSize.clear()
                for ((id, p) in f) { analysedSize[id] = p.first; p.second?.let { features[id] = it } }
                moods = store.moods()
                habits = Habits(store.plays(), System.currentTimeMillis())
                scanned = true
            } catch (e: SecurityException) {
                scanned = false
            }
            changed()
            then?.let { main.post(it) }
            startAnalysis()
        }
    }

    private fun applyOverrides(ov: Map<Long, Store.Override>) {
        val list = raw.map { t ->
            val o = ov[t.id] ?: return@map t
            t.copy(title = o.title.ifBlank { t.title }, artist = o.artist, album = o.album.ifBlank { t.album })
        }
        tracks = list
        byId = list.associateBy { it.id }
    }

    fun reloadOverrides() = io.execute { applyOverrides(store.overrides()); changed() }

    fun setMood(t: Track, mood: Mood?) = io.execute {
        store.setMood(t.id, mood); moods = store.moods(); changed()
    }

    fun recordPlay(e: PlayEvent) = io.execute {
        store.addPlay(e)
        habits = Habits(store.plays(), System.currentTimeMillis())
        changed()
    }

    // ---------------- analysis

    fun startAnalysis() {
        if (analysing) return
        val todo = tracks.filter { analysedSize[it.id] != it.sizeBytes }
        if (todo.isEmpty()) return
        analysing = true; stopAnalysis.set(false)
        analysisDone = 0; analysisTotal = todo.size
        changed()
        analysisThread.execute {
            var sinceNotify = 0
            for (t in todo) {
                if (stopAnalysis.get()) break
                val f = try { Decoder.analyze(app, uriOf(t.id), t.durationMs) } catch (e: Throwable) { null }
                store.putFeatures(t.id, t.sizeBytes, f)
                analysedSize[t.id] = t.sizeBytes
                if (f != null) features[t.id] = f
                analysisDone++
                if (++sinceNotify >= 5) { sinceNotify = 0; changed() }
            }
            analysing = false
            changed()
        }
    }

    fun pauseAnalysis() { stopAnalysis.set(true) }

    fun forgetFiles(ids: Collection<Long>) {
        val gone = ids.toSet()
        raw = raw.filter { it.id !in gone }
        tracks = tracks.filter { it.id !in gone }
        byId = tracks.associateBy { it.id }
        changed()
    }
}

/** Reads songs from Android's media library. */
object Scanner {
    fun scan(ctx: Context): List<Track> {
        val m = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val cols = arrayOf(
            MediaStore.Audio.Media._ID, MediaStore.Audio.Media.TITLE, MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM, MediaStore.Audio.Media.ALBUM_ID, MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.SIZE, MediaStore.Audio.Media.MIME_TYPE, MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.RELATIVE_PATH, MediaStore.Audio.Media.DATE_ADDED, MediaStore.Audio.Media.TRACK,
            MediaStore.Audio.Media.YEAR, MediaStore.Audio.Media.GENRE, MediaStore.Audio.Media.BITRATE,
        )
        val sel = "(${MediaStore.Audio.Media.IS_MUSIC} != 0 OR ${MediaStore.Audio.Media.DURATION} > 60000) AND " +
            "${MediaStore.Audio.Media.IS_RINGTONE} = 0 AND ${MediaStore.Audio.Media.IS_NOTIFICATION} = 0 AND " +
            "${MediaStore.Audio.Media.IS_ALARM} = 0 AND ${MediaStore.Audio.Media.DURATION} > 15000"
        val out = ArrayList<Track>()
        ctx.contentResolver.query(m, cols, sel, null, null)?.use { c ->
            while (c.moveToNext()) {
                fun s(i: Int) = c.getString(i) ?: ""
                val artist = s(2).let { if (it == "<unknown>") "" else it }
                out.add(Track(
                    id = c.getLong(0), title = s(1), artist = artist, album = s(3),
                    genre = s(13), year = c.getInt(12), trackNo = c.getInt(11) % 1000,
                    durationMs = c.getLong(5), sizeBytes = c.getLong(6), bitrate = c.getInt(14),
                    mimeType = s(7), displayName = s(8), folder = s(9), dateAddedSec = c.getLong(10), albumId = c.getLong(4),
                ))
            }
        }
        return out
    }
}

/** Decodes ~40 s from the middle of a song to mono floats and runs the analyzer. */
object Decoder {
    private const val WINDOW_US = 40_000_000L

    fun analyze(ctx: Context, uri: Uri, durationMs: Long): Features? {
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
            return AudioAnalyzer.analyze(samples, sr)
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            ex.release()
        }
    }
}
