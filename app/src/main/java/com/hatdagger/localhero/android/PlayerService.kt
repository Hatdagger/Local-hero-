package com.hatdagger.localhero.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.MediaPlayer
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Size
import com.hatdagger.localhero.R
import com.hatdagger.localhero.core.PlayEvent
import com.hatdagger.localhero.core.Track

enum class Repeat { OFF, ALL, ONE }

/**
 * Playback state the screens read from, and the commands they send. The actual player lives in
 * [PlayerService]; commands start it when needed.
 */
object Playback {
    var queue: List<Track> = emptyList(); internal set
    private var original: List<Track> = emptyList()
    var index = -1; internal set
    var shuffle = false; private set
    var repeat = Repeat.OFF; private set
    var playing = false; internal set
    var sleepAtMs = 0L; internal set
    val current: Track? get() = queue.getOrNull(index)

    private val listeners = ArrayList<() -> Unit>()
    fun listen(l: () -> Unit) { listeners.add(l) }
    fun unlisten(l: () -> Unit) { listeners.remove(l) }
    internal fun changed() { listeners.toList().forEach { it() } }

    fun position(): Long = PlayerService.instance?.position() ?: savedPosition
    fun duration(): Long = PlayerService.instance?.duration()?.takeIf { it > 0 } ?: (current?.durationMs ?: 0)
    internal var savedPosition = 0L

    private fun send(ctx: Context, action: String, extra: Long = 0) {
        val i = Intent(ctx, PlayerService::class.java).setAction(action).putExtra("v", extra)
        ctx.startForegroundService(i)
    }

    fun play(ctx: Context, list: List<Track>, start: Int, shuffled: Boolean = false) {
        if (list.isEmpty()) return
        original = list
        shuffle = shuffled
        if (shuffled) {
            val first = list[start.coerceIn(0, list.size - 1)]
            queue = listOf(first) + (list - first).shuffled()
            index = 0
        } else { queue = list; index = start.coerceIn(0, list.size - 1) }
        savedPosition = 0
        send(ctx, PlayerService.ACT_START)
        changed()
    }

    fun toggle(ctx: Context) { if (current != null) send(ctx, if (playing) PlayerService.ACT_PAUSE else PlayerService.ACT_PLAY) }
    fun next(ctx: Context) = send(ctx, PlayerService.ACT_NEXT)
    fun prev(ctx: Context) = send(ctx, PlayerService.ACT_PREV)
    fun seek(ctx: Context, ms: Long) { savedPosition = ms; send(ctx, PlayerService.ACT_SEEK, ms) }
    fun jump(ctx: Context, i: Int) { if (i in queue.indices) { index = i; savedPosition = 0; send(ctx, PlayerService.ACT_START); changed() } }

    fun setShuffle(on: Boolean) {
        val cur = current ?: run { shuffle = on; changed(); return }
        shuffle = on
        if (on) {
            val rest = queue.filterIndexed { i, _ -> i != index }.shuffled()
            original = if (original.isEmpty()) queue else original
            queue = listOf(cur) + rest; index = 0
        } else if (original.isNotEmpty()) {
            queue = original; index = original.indexOfFirst { it.id == cur.id }.coerceAtLeast(0)
        }
        PlayerService.instance?.queueChanged()
        changed()
    }

    fun cycleRepeat() {
        repeat = Repeat.values()[(repeat.ordinal + 1) % Repeat.values().size]
        PlayerService.instance?.queueChanged()
        changed()
    }

    fun playNext(t: Track) {
        if (queue.isEmpty()) return
        val q = queue.toMutableList(); q.add(index + 1, t); queue = q
        original = original + t
        PlayerService.instance?.queueChanged(); changed()
    }

    fun addToQueue(t: Track) {
        if (queue.isEmpty()) return
        queue = queue + t; original = original + t
        PlayerService.instance?.queueChanged(); changed()
    }

    fun removeAt(i: Int) {
        if (i == index || i !in queue.indices) return
        val q = queue.toMutableList(); val gone = q.removeAt(i); queue = q
        original = original - gone
        if (i < index) index--
        PlayerService.instance?.queueChanged(); changed()
    }

    fun moveItem(from: Int, to: Int) {
        if (from !in queue.indices || to !in queue.indices) return
        val q = queue.toMutableList(); val t = q.removeAt(from); q.add(to, t)
        val cur = current
        queue = q
        index = q.indexOfFirst { it === cur }.coerceAtLeast(0)
        PlayerService.instance?.queueChanged(); changed()
    }

    fun setSleep(minutes: Int) {
        sleepAtMs = if (minutes <= 0) 0 else System.currentTimeMillis() + minutes * 60_000L
        changed()
    }

    // ---- remember the queue between app launches
    fun save(ctx: Context) {
        ctx.getSharedPreferences("playback", Context.MODE_PRIVATE).edit()
            .putString("queue", queue.joinToString(",") { it.id.toString() })
            .putInt("index", index).putLong("pos", position())
            .putBoolean("shuffle", shuffle).putString("repeat", repeat.name).apply()
    }

    fun restore(ctx: Context) {
        if (queue.isNotEmpty()) return
        val p = ctx.getSharedPreferences("playback", Context.MODE_PRIVATE)
        val ids = (p.getString("queue", "") ?: "").split(",").mapNotNull { it.toLongOrNull() }
        val q = ids.mapNotNull { Hero.byId[it] }
        if (q.isEmpty()) return
        queue = q; original = q
        index = p.getInt("index", 0).coerceIn(0, q.size - 1)
        savedPosition = p.getLong("pos", 0)
        shuffle = p.getBoolean("shuffle", false)
        repeat = runCatching { Repeat.valueOf(p.getString("repeat", "OFF")!!) }.getOrDefault(Repeat.OFF)
        changed()
    }
}

class PlayerService : Service() {
    companion object {
        const val ACT_START = "start"; const val ACT_PLAY = "play"; const val ACT_PAUSE = "pause"
        const val ACT_NEXT = "next"; const val ACT_PREV = "prev"; const val ACT_SEEK = "seek"; const val ACT_STOP = "stop"
        private const val CHANNEL = "playback"
        private const val NOTE_ID = 7
        var instance: PlayerService? = null; private set
    }

    private val main = Handler(Looper.getMainLooper())
    private lateinit var session: MediaSession
    private lateinit var audio: AudioManager
    private var focusRequest: AudioFocusRequest? = null
    private var player: MediaPlayer? = null
    private var prepared = false
    private var next: MediaPlayer? = null
    private var nextIndex = -1
    private var nextReady = false
    private var resumeOnFocus = false
    private var startedAt = 0L
    private var listenedMs = 0L
    private var lastTickPos = 0L
    private var art: Bitmap? = null
    private var foreground = false

    private val attrs = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build()

    private val noisy = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) { if (Playback.playing) pause() }
    }

    private val focus = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> { resumeOnFocus = false; pause() }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> { resumeOnFocus = Playback.playing; pause() }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> player?.setVolume(0.25f, 0.25f)
            AudioManager.AUDIOFOCUS_GAIN -> { player?.setVolume(1f, 1f); if (resumeOnFocus) { resumeOnFocus = false; play() } }
        }
    }

    /** Counts real listening time (so seeking doesn't fake a "completed" play) and runs the sleep timer. */
    private val ticker = object : Runnable {
        override fun run() {
            val p = player
            if (p != null && prepared && Playback.playing) {
                val pos = p.currentPosition.toLong()
                val d = pos - lastTickPos
                if (d in 1..2500) listenedMs += d
                lastTickPos = pos
            }
            if (Playback.sleepAtMs in 1..System.currentTimeMillis()) { Playback.sleepAtMs = 0; pause(); Playback.changed() }
            main.postDelayed(this, 1000)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        Hero.init(this)
        audio = getSystemService(AUDIO_SERVICE) as AudioManager
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Playback", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
        session = MediaSession(this, "LocalHero").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() = play()
                override fun onPause() = pause()
                override fun onSkipToNext() = skip(1)
                override fun onSkipToPrevious() = previous()
                override fun onSeekTo(pos: Long) = seekTo(pos)
                override fun onStop() = stopAll()
            })
            setSessionActivity(PendingIntent.getActivity(this@PlayerService, 0, Intent(this@PlayerService, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE))
            isActive = true
        }
        registerReceiver(noisy, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        main.post(ticker)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Must call startForeground quickly after startForegroundService.
        goForeground()
        when (intent?.action) {
            ACT_START -> startCurrent(Playback.savedPosition, true)
            ACT_PLAY -> play()
            ACT_PAUSE -> pause()
            ACT_NEXT -> skip(1)
            ACT_PREV -> previous()
            ACT_SEEK -> seekTo(intent.getLongExtra("v", 0))
            ACT_STOP -> stopAll()
        }
        return START_NOT_STICKY
    }

    fun position(): Long = player?.takeIf { prepared }?.currentPosition?.toLong() ?: Playback.savedPosition
    fun duration(): Long = player?.takeIf { prepared }?.duration?.toLong() ?: 0

    private fun newPlayer(t: Track): MediaPlayer = MediaPlayer().apply {
        setAudioAttributes(attrs)
        setWakeMode(applicationContext, PowerManager.PARTIAL_WAKE_LOCK)
        setDataSource(applicationContext, Hero.uriOf(t.id))
        setOnCompletionListener { mp -> onCompleted(mp) }
        setOnErrorListener { mp, _, _ -> onError(mp); true }
    }

    private fun startCurrent(seekMs: Long, autoplay: Boolean) {
        logPlay(false)
        releaseNext()
        player?.release(); player = null; prepared = false
        val t = Playback.current ?: return
        art = null
        try {
            val mp = newPlayer(t)
            player = mp
            mp.setOnPreparedListener {
                if (player !== it) return@setOnPreparedListener
                prepared = true
                if (seekMs > 0) it.seekTo(seekMs.toInt())
                lastTickPos = seekMs; listenedMs = 0; startedAt = System.currentTimeMillis()
                it.isLooping = Playback.repeat == Repeat.ONE
                if (autoplay) play() else updateAll()
                prepareNext()
            }
            mp.prepareAsync()
            loadArt(t)
            updateAll()
        } catch (e: Exception) {
            onError(player)
        }
    }

    private fun loadArt(t: Track) {
        Thread {
            val bmp = try { contentResolver.loadThumbnail(Hero.uriOf(t.id), Size(512, 512), null) } catch (e: Exception) { null }
            main.post { if (Playback.current?.id == t.id) { art = bmp; updateAll() } }
        }.start()
    }

    private fun nextIndexFor(step: Int): Int {
        val q = Playback.queue
        if (q.isEmpty()) return -1
        val n = Playback.index + step
        return when {
            n in q.indices -> n
            Playback.repeat == Repeat.ALL -> (n + q.size) % q.size
            else -> -1
        }
    }

    /** Gapless: get the next song ready and hand it to the current player. */
    private fun prepareNext() {
        releaseNext()
        val cur = player ?: return
        if (Playback.repeat == Repeat.ONE || !prepared) return
        val ni = nextIndexFor(1)
        if (ni < 0) return
        val t = Playback.queue[ni]
        try {
            val mp = newPlayer(t)
            next = mp; nextIndex = ni
            mp.setOnPreparedListener {
                if (next !== it || player !== cur) return@setOnPreparedListener
                try { cur.setNextMediaPlayer(it); nextReady = true } catch (e: Exception) { releaseNext() }
            }
            mp.prepareAsync()
        } catch (e: Exception) { releaseNext() }
    }

    private fun releaseNext() {
        try { if (nextReady) player?.setNextMediaPlayer(null) } catch (_: Exception) {}
        next?.release(); next = null; nextReady = false; nextIndex = -1
    }

    /** Called by [Playback] when the queue, shuffle or repeat changed. */
    fun queueChanged() {
        player?.isLooping = Playback.repeat == Repeat.ONE
        if (prepared) prepareNext()
        updateAll()
    }

    private fun onCompleted(mp: MediaPlayer) {
        if (mp !== player) return
        listenedMs = maxOf(listenedMs, (Playback.current?.durationMs ?: 0) * 9 / 10)
        logPlay(true)
        val n = next
        if (nextReady && n != null && nextIndex in Playback.queue.indices) {
            // The next song already started on its own (gapless).
            mp.release()
            player = n; prepared = true
            Playback.index = nextIndex
            next = null; nextReady = false; nextIndex = -1
            startedAt = System.currentTimeMillis(); listenedMs = 0; lastTickPos = 0
            Playback.savedPosition = 0
            loadArt(Playback.current!!)
            updateAll(); Playback.changed()
            prepareNext()
            return
        }
        val ni = nextIndexFor(1)
        if (ni >= 0) { Playback.index = ni; Playback.savedPosition = 0; startCurrent(0, true); Playback.changed() }
        else {
            // End of the queue: stop and rewind to the first song.
            Playback.playing = false
            Playback.index = 0; Playback.savedPosition = 0
            startCurrent(0, false)
            Playback.changed()
        }
    }

    private fun onError(mp: MediaPlayer?) {
        if (mp != null && mp === next) { releaseNext(); return }
        logPlay(false)
        player?.release(); player = null; prepared = false
        // Skip unplayable files instead of stopping.
        val ni = nextIndexFor(1)
        if (ni >= 0 && ni != Playback.index) { Playback.index = ni; startCurrent(0, Playback.playing); Playback.changed() }
        else { Playback.playing = false; updateAll(); Playback.changed() }
    }

    private fun logPlay(completed: Boolean) {
        val t = Playback.current ?: return
        if (startedAt == 0L || listenedMs < 1000 && !completed) { startedAt = 0; return }
        Hero.recordPlay(PlayEvent(t.id, startedAt, listenedMs, t.durationMs, completed || listenedMs >= t.durationMs * 9 / 10))
        startedAt = 0; listenedMs = 0
    }

    fun play() {
        val p = player
        if (p == null) { if (Playback.current != null) startCurrent(Playback.savedPosition, true); return }
        if (!prepared) return
        val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN).setAudioAttributes(attrs).setOnAudioFocusChangeListener(focus).build()
        focusRequest = req
        if (audio.requestAudioFocus(req) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) return
        p.start()
        if (startedAt == 0L) { startedAt = System.currentTimeMillis(); listenedMs = 0 }
        lastTickPos = p.currentPosition.toLong()
        Playback.playing = true
        updateAll(); Playback.changed()
    }

    fun pause() {
        player?.takeIf { prepared && it.isPlaying }?.pause()
        Playback.playing = false
        Playback.savedPosition = position()
        Playback.save(this)
        updateAll(); Playback.changed()
    }

    fun seekTo(ms: Long) {
        player?.takeIf { prepared }?.seekTo(ms.toInt())
        lastTickPos = ms
        Playback.savedPosition = ms
        updateAll()
    }

    fun skip(step: Int) {
        val ni = nextIndexFor(step)
        if (ni < 0) return
        Playback.index = ni; Playback.savedPosition = 0
        startCurrent(0, Playback.playing || step != 0)
        Playback.changed()
    }

    /** Restart the song if more than 3 s in, otherwise go back one. */
    fun previous() {
        if (position() > 3000 || nextIndexFor(-1) < 0) seekTo(0) else skip(-1)
    }

    private fun stopAll() {
        pause()
        stopForeground(STOP_FOREGROUND_REMOVE); foreground = false
        stopSelf()
    }

    // ---------------- session + notification

    private fun updateAll() {
        val t = Playback.current
        val state = if (Playback.playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED
        session.setPlaybackState(PlaybackState.Builder()
            .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or
                PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS or PlaybackState.ACTION_SEEK_TO or PlaybackState.ACTION_STOP)
            .setState(state, position(), if (Playback.playing) 1f else 0f)
            .build())
        if (t != null) {
            session.setMetadata(MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, t.title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, t.artist)
                .putString(MediaMetadata.METADATA_KEY_ALBUM, t.album)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, t.durationMs)
                .apply { art?.let { putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it) } }
                .build())
        }
        val nm = getSystemService(NotificationManager::class.java)
        if (foreground || Playback.playing) goForeground() else nm.notify(NOTE_ID, buildNotification())
        if (!Playback.playing && foreground) {
            stopForeground(STOP_FOREGROUND_DETACH); foreground = false
            nm.notify(NOTE_ID, buildNotification())
        }
    }

    private fun goForeground() {
        val n = buildNotification()
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTE_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        else startForeground(NOTE_ID, n)
        foreground = true
    }

    private fun action(icon: Int, title: String, act: String, req: Int): Notification.Action {
        val pi = PendingIntent.getService(this, req, Intent(this, PlayerService::class.java).setAction(act), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(this, icon), title, pi).build()
    }

    private fun buildNotification(): Notification {
        val t = Playback.current
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_note)
            .setContentTitle(t?.title ?: "Local Hero")
            .setContentText(t?.artist ?: "")
            .setLargeIcon(art)
            .setOngoing(Playback.playing)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE))
            .setDeleteIntent(PendingIntent.getService(this, 9, Intent(this, PlayerService::class.java).setAction(ACT_STOP), PendingIntent.FLAG_IMMUTABLE))
            .addAction(action(android.R.drawable.ic_media_previous, "Previous", ACT_PREV, 1))
            .addAction(if (Playback.playing) action(android.R.drawable.ic_media_pause, "Pause", ACT_PAUSE, 2) else action(android.R.drawable.ic_media_play, "Play", ACT_PLAY, 3))
            .addAction(action(android.R.drawable.ic_media_next, "Next", ACT_NEXT, 4))
            .setStyle(Notification.MediaStyle().setMediaSession(session.sessionToken).setShowActionsInCompactView(0, 1, 2))
            .build()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        Playback.save(this)
        if (!Playback.playing) stopAll()
    }

    override fun onDestroy() {
        Playback.savedPosition = position()
        Playback.save(this)
        logPlay(false)
        main.removeCallbacks(ticker)
        try { unregisterReceiver(noisy) } catch (_: Exception) {}
        focusRequest?.let { audio.abandonAudioFocusRequest(it) }
        releaseNext()
        player?.release(); player = null
        Playback.playing = false
        session.release()
        instance = null
        Playback.changed()
        super.onDestroy()
    }
}
