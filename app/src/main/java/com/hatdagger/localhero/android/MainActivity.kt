package com.hatdagger.localhero.android

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.util.Size
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.CheckBox
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.ProgressBar
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast
import com.hatdagger.localhero.core.Bucket
import com.hatdagger.localhero.core.DuplicateGroup
import com.hatdagger.localhero.core.Duplicates
import com.hatdagger.localhero.core.GroupBy
import com.hatdagger.localhero.core.LibraryOps
import com.hatdagger.localhero.core.Mix
import com.hatdagger.localhero.core.Mood
import com.hatdagger.localhero.core.MoodModel
import com.hatdagger.localhero.core.NameFix
import com.hatdagger.localhero.core.NameFixer
import com.hatdagger.localhero.core.SortBy
import com.hatdagger.localhero.core.Track
import java.util.Calendar

class MainActivity : Activity() {
    private lateinit var ui: Ui
    private lateinit var fileOps: FileOps
    private val main = Handler(Looper.getMainLooper())

    enum class Tab(val label: String, val accent: Int) {
        LIBRARY("Library", Palette.GOLD), MIXES("Mixes", Palette.TEAL), PLAYLISTS("Playlists", Palette.VIOLET), TIDY("Tidy", Palette.CORAL)
    }
    private var tab = Tab.LIBRARY

    // Library state
    private var group = GroupBy.SONGS
    private var sort = SortBy.ARTIST
    private var query = ""
    private var libDetail: Bucket? = null

    // Mixes state
    private var mixes: List<Mix>? = null
    private var mixDetail: Mix? = null
    private var mixesBusy = false

    // Playlists state
    private var playlistDetail: Long? = null

    // Tidy state
    private var tidyMode = 0
    private var dupGroups: List<DuplicateGroup>? = null
    private val dupSelected = HashSet<Long>()
    private var fixes: List<NameFix>? = null
    private val fixSelected = HashSet<Long>()
    private var organize = false
    private val undoSelected = HashSet<Long>()
    private var tidyBusy = false

    // Views
    private lateinit var rootFrame: FrameLayout
    private lateinit var status: TextView
    private lateinit var topArea: LinearLayout
    private lateinit var list: ListView
    private lateinit var adapter: ItemAdapter
    private lateinit var tabBar: LinearLayout
    private lateinit var libTop: LinearLayout
    private lateinit var groupChips: LinearLayout
    private lateinit var sortButton: android.widget.Button

    private lateinit var mini: LinearLayout
    private lateinit var miniArt: ImageView
    private lateinit var miniTitle: TextView
    private lateinit var miniSub: TextView
    private lateinit var miniPlay: TextView
    private lateinit var miniProgress: ProgressBar

    private var nowView: View? = null
    private var nowSeek: SeekBar? = null
    private var nowTimes: TextView? = null
    private var nowPlay: TextView? = null
    private var nowArt: ImageView? = null
    private var nowTitle: TextView? = null
    private var nowSub: TextView? = null
    private var nowMood: android.widget.Button? = null
    private var nowShuffle: TextView? = null
    private var nowRepeat: TextView? = null
    private var nowSleep: android.widget.Button? = null
    private var queueAdapter: ItemAdapter? = null
    private var seeking = false

    private var shownTrackId = -1L
    private var artBitmap: Bitmap? = null
    private var lastTracksRef: Any? = null
    private var lastMoodsRef: Any? = null
    private var lastHabitsRef: Any? = null

    private val heroListener: () -> Unit = {
        updateStatus()
        if (lastTracksRef !== Hero.tracks || lastMoodsRef !== Hero.moods || lastHabitsRef !== Hero.habits) {
            if (lastTracksRef !== Hero.tracks) { Playback.restore(this) }
            render()
        }
    }
    private val playbackListener: () -> Unit = { onPlaybackChanged() }

    private val ticker = object : Runnable {
        override fun run() { updateProgress(); main.postDelayed(this, 500) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = Palette.BG
        window.navigationBarColor = Palette.BG
        ui = Ui(this)
        fileOps = FileOps(this)
        Hero.init(this)
        buildShell()
        Hero.listen(heroListener)
        Playback.listen(playbackListener)
        if (hasAudioPermission()) Hero.refresh { Playback.restore(this) } else askPermissions()
        render()
    }

    override fun onResume() { super.onResume(); main.post(ticker); onPlaybackChanged() }
    override fun onPause() { super.onPause(); main.removeCallbacks(ticker); Playback.save(this) }
    override fun onDestroy() { Hero.unlisten(heroListener); Playback.unlisten(playbackListener); super.onDestroy() }

    // ---------------- permissions

    private fun audioPermission() = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_AUDIO else Manifest.permission.READ_EXTERNAL_STORAGE
    private fun hasAudioPermission() = checkSelfPermission(audioPermission()) == PackageManager.PERMISSION_GRANTED

    private fun askPermissions() {
        val perms = ArrayList<String>()
        perms.add(audioPermission())
        if (Build.VERSION.SDK_INT >= 33) perms.add(Manifest.permission.POST_NOTIFICATIONS)
        requestPermissions(perms.toTypedArray(), 1)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (hasAudioPermission()) Hero.refresh { Playback.restore(this) } else render()
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!fileOps.onResult(requestCode, resultCode)) super.onActivityResult(requestCode, resultCode, data)
    }

    // ---------------- shell

    private fun buildShell() {
        rootFrame = FrameLayout(this).apply { setBackgroundColor(Palette.BG) }
        val column = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }

        val title = ui.text("Local Hero", 22f, Palette.GOLD, bold = true)
        status = ui.text("", 12.5f, Palette.TEXT_DIM, lines = 1)
        val header = ui.column(title, status).apply { setPadding(ui.dp(18), ui.dp(16), ui.dp(18), ui.dp(4)) }
        column.addView(header)

        topArea = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        column.addView(topArea)

        adapter = ItemAdapter(this, ui)
        list = ListView(this).apply {
            this.adapter = this@MainActivity.adapter
            divider = null; dividerHeight = 0
            setSelector(android.R.color.transparent)
            isFastScrollEnabled = true
            clipToPadding = false
            setPadding(0, 0, 0, ui.dp(8))
        }
        column.addView(list, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        column.addView(buildMini())

        tabBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(ui.dp(8), ui.dp(6), ui.dp(8), ui.dp(10))
            setBackgroundColor(Palette.SURFACE)
        }
        column.addView(tabBar)

        rootFrame.addView(column)
        // Keep clear of the status and navigation bars (Android 15 draws edge to edge).
        rootFrame.setOnApplyWindowInsetsListener { v, insets ->
            val b = insets.getInsets(android.view.WindowInsets.Type.systemBars() or android.view.WindowInsets.Type.ime())
            v.setPadding(b.left, b.top, b.right, b.bottom)
            insets
        }
        setContentView(rootFrame)
        buildLibraryTop()
        renderTabs()
    }

    private fun renderTabs() {
        tabBar.removeAllViews()
        for (t in Tab.values()) {
            val b = ui.button(t.label, t.accent, if (t == tab) Ui.Style.FILLED else Ui.Style.GHOST) {
                if (tab == t) {
                    // Tapping the open tab goes back to its top level.
                    libDetail = null; mixDetail = null; playlistDetail = null
                } else tab = t
                renderTabs(); render(); list.setSelection(0)
            }
            tabBar.addView(ui.weight(b))
            (b.layoutParams as LinearLayout.LayoutParams).setMargins(ui.dp(4), 0, ui.dp(4), 0)
        }
    }

    private fun updateStatus() {
        val n = Hero.tracks.size
        val parts = ArrayList<String>()
        if (Hero.scanned) parts.add("%,d songs".format(n))
        if (Hero.analysing) parts.add("listening to your music ${Hero.analysisDone}/${Hero.analysisTotal}")
        else if (Hero.scanned && n > 0) parts.add("${Hero.features.size * 100 / maxOf(1, n)}% analysed")
        status.text = parts.joinToString(" · ")
    }

    private val pendingTop = ArrayList<View>()
    private fun top(v: View) { pendingTop.add(v) }

    private fun render() {
        lastTracksRef = Hero.tracks; lastMoodsRef = Hero.moods; lastHabitsRef = Hero.habits
        updateStatus()
        pendingTop.clear()
        val items: List<Item> = when (tab) {
            Tab.LIBRARY -> libraryScreen()
            Tab.MIXES -> mixesScreen()
            Tab.PLAYLISTS -> playlistsScreen()
            Tab.TIDY -> tidyScreen()
        }
        // Keep persistent views (like the search box) attached so typing isn't interrupted.
        val same = topArea.childCount == pendingTop.size && pendingTop.indices.all { topArea.getChildAt(it) === pendingTop[it] }
        if (!same) {
            topArea.removeAllViews()
            for (v in pendingTop) { (v.parent as? ViewGroup)?.removeView(v); topArea.addView(v) }
        }
        adapter.items = items
    }

    // ---------------- shared pieces

    private fun songSub(t: Track) = listOf(t.artist.ifBlank { "Unknown artist" }, t.album).filter { it.isNotBlank() }.joinToString(" · ")

    private fun songItems(songs: List<Track>, accent: Int, extra: ((Track, Int) -> List<Pair<String, () -> Unit>>)? = null): List<Item> {
        val cur = Playback.current?.id
        return songs.mapIndexed { i, t ->
            val mood = Hero.moodOf(t)?.emoji ?: ""
            Item.Entry(
                t.title.ifBlank { t.displayName }, songSub(t), "$mood  ${LibraryOps.formatTime(t.durationMs)}".trim(), accent,
                highlight = t.id == cur,
                onClick = { Playback.play(this, songs, i) },
                onLong = { songMenu(t, extra?.invoke(t, i) ?: emptyList()) },
            )
        }
    }

    private fun detailHeader(title: String, sub: String, accent: Int, songs: List<Track>, vararg extra: Pair<String, () -> Unit>): View {
        val back = ui.button("‹ Back", accent, Ui.Style.GHOST) { onBackPressed() }
        val t = ui.column(ui.text(title, 18f, Palette.TEXT, bold = true, lines = 2), ui.text(sub, 12.5f, Palette.TEXT_DIM, lines = 1))
        val buttons = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        buttons.addView(ui.button("▶ Play", accent, Ui.Style.FILLED) { Playback.play(this, songs, 0) })
        buttons.addView(ui.margins(ui.button("⤮ Shuffle", accent) { if (songs.isNotEmpty()) Playback.play(this, songs, songs.indices.random(), shuffled = true) }, l = 8))
        for ((label, act) in extra) buttons.addView(ui.margins(ui.button(label, accent, Ui.Style.OUTLINE) { act() }, l = 8))
        val scroll = HorizontalScrollView(this).apply { isHorizontalScrollBarEnabled = false; addView(buttons) }
        return ui.column(ui.row(back), t, ui.margins(scroll, t = 8)).apply { setPadding(ui.dp(14), 0, ui.dp(14), ui.dp(6)) }
    }

    private fun message(text: String, accent: Int, button: Pair<String, () -> Unit>? = null): Item {
        val card = ui.card(accent)
        card.addView(ui.text(text, 14f, Palette.TEXT))
        if (button != null) card.addView(ui.margins(ui.button(button.first, accent, Ui.Style.FILLED) { button.second() }, t = 10))
        val wrap = FrameLayout(this).apply { setPadding(ui.dp(14), ui.dp(8), ui.dp(14), ui.dp(8)); addView(card) }
        return Item.Custom(wrap)
    }

    private fun dialog() = AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)

    private fun askText(title: String, initial: String, done: (String) -> Unit) {
        val input = EditText(this).apply { setText(initial); setSingleLine(); inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES; setSelection(initial.length) }
        val box = FrameLayout(this).apply { setPadding(ui.dp(20), ui.dp(8), ui.dp(20), 0); addView(input) }
        dialog().setTitle(title).setView(box)
            .setPositiveButton("OK") { _, _ -> input.text.toString().trim().takeIf { it.isNotEmpty() }?.let(done) }
            .setNegativeButton("Cancel", null).show()
    }

    private fun mb(bytes: Long) = String.format(java.util.Locale.US, "%.1f MB", bytes / 1_048_576.0)

    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_LONG).show()

    private fun songMenu(t: Track, extra: List<Pair<String, () -> Unit>> = emptyList()) {
        val opts = ArrayList<Pair<String, () -> Unit>>()
        if (Playback.queue.isNotEmpty()) {
            opts.add("Play next" to { Playback.playNext(t); toast("Plays next") })
            opts.add("Add to queue" to { Playback.addToQueue(t); toast("Added to queue") })
        }
        opts.add("Add to playlist…" to { addToPlaylist(listOf(t)) })
        opts.add("Songs like this" to { showSoundsLike(t) })
        opts.add("Set mood…" to { pickMood(t) })
        opts.add("Song info" to { songInfo(t) })
        opts.addAll(extra)
        dialog().setTitle(t.title.ifBlank { t.displayName }).setItems(opts.map { it.first }.toTypedArray()) { _, i -> opts[i].second() }.show()
    }

    private fun pickMood(t: Track) {
        val auto = MoodModel.best(Hero.features[t.id], t.genre)
        val labels = Mood.values().map { "${it.emoji}  ${it.label}" + if (Hero.moods[t.id] == it) "  ✓" else "" } +
            ("Automatic (sounds ${auto?.label ?: "unknown yet"})" + if (Hero.moods[t.id] == null) "  ✓" else "")
        dialog().setTitle("Mood for “${t.title}”").setItems(labels.toTypedArray()) { _, i ->
            Hero.setMood(t, Mood.values().getOrNull(i))
        }.show()
    }

    private val keyNames = arrayOf("C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B")

    private fun songInfo(t: Track) {
        val f = Hero.features[t.id]
        val raw = Hero.raw.firstOrNull { it.id == t.id }
        val s = Hero.habits[t.id]
        val lines = ArrayList<String>()
        lines.add("File: ${t.displayName}")
        lines.add("Folder: ${t.folder}")
        lines.add("Format: " + t.extension.uppercase() + (if (t.bitrate > 0) " · ${t.bitrate / 1000} kbps" else "") + " · " + mb(t.sizeBytes))
        if (raw != null && (raw.title != t.title || raw.artist != t.artist)) lines.add("Tags in file: ${raw.artist.ifBlank { "?" }} – ${raw.title}")
        if (t.genre.isNotBlank()) lines.add("Genre: ${t.genre}")
        if (f != null) {
            lines.add("")
            lines.add("Sound: ${if (f.tempoBpm > 0) "%.0f BPM".format(f.tempoBpm) else "no clear beat"} · ${keyNames[f.key]} ${if (f.major) "major" else "minor"}")
            lines.add("Energy %d%% · Brightness %d%%".format((f.energy * 100).toInt(), (f.brightness * 100).toInt()))
            lines.add("Mood: ${Hero.moodOf(t)?.label ?: "?"}${if (Hero.moods[t.id] != null) " (set by you)" else ""}")
        } else lines.add("\nNot analysed yet")
        if (s != null) {
            lines.add("")
            lines.add("Played ${s.plays}× · finished ${s.completes} · skipped ${s.skips}")
        }
        dialog().setTitle(t.title).setMessage(lines.joinToString("\n")).setPositiveButton("OK", null).show()
    }

    private fun addToPlaylist(songs: List<Track>) {
        val pls = Hero.store.playlists()
        val labels = listOf("＋ New playlist…") + pls.map { "${it.name} (${it.trackIds.size})" }
        dialog().setTitle("Add ${if (songs.size == 1) "song" else "${songs.size} songs"} to…").setItems(labels.toTypedArray()) { _, i ->
            if (i == 0) askText("New playlist", "") { name ->
                Hero.store.createPlaylist(name, songs.map { it.id }); toast("Saved “$name”"); if (tab == Tab.PLAYLISTS) render()
            } else {
                val p = pls[i - 1]
                Hero.store.setPlaylistTracks(p.id, p.trackIds + songs.map { it.id }.filter { it !in p.trackIds })
                toast("Added to “${p.name}”"); if (tab == Tab.PLAYLISTS) render()
            }
        }.show()
    }

    private fun showSoundsLike(t: Track) {
        mixDetail = Hero.mixMaker().soundsLike(t)
        tab = Tab.MIXES; renderTabs(); closeNowPlaying(); render(); list.setSelection(0)
    }

    // ---------------- Library

    private fun buildLibraryTop() {
        groupChips = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(ui.dp(10), 0, ui.dp(10), 0) }
        val chipScroll = HorizontalScrollView(this).apply { isHorizontalScrollBarEnabled = false; addView(groupChips) }
        val search = EditText(this).apply {
            hint = "Search songs, artists, albums…"
            setHintTextColor(Palette.TEXT_DIM); setTextColor(Palette.TEXT); textSize = 15f
            setSingleLine()
            background = ui.rounded(Palette.SURFACE_HI, 20)
            setPadding(ui.dp(16), ui.dp(10), ui.dp(16), ui.dp(10))
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun afterTextChanged(s: Editable?) { query = s?.toString() ?: ""; libDetail = null; render() }
            })
        }
        sortButton = ui.button("", Palette.GOLD, Ui.Style.OUTLINE) {
            val opts = SortBy.values()
            dialog().setTitle("Sort songs by").setItems(opts.map { it.label }.toTypedArray()) { _, i -> sort = opts[i]; render() }.show()
        }
        val refresh = ui.button("⟳", Palette.GOLD, Ui.Style.GHOST) { Hero.refresh(); toast("Rescanning library…") }
        val searchRow = ui.row(ui.weight(search), ui.margins(sortButton, l = 8), refresh).apply { setPadding(ui.dp(14), ui.dp(4), ui.dp(10), ui.dp(4)) }
        libTop = ui.column(searchRow, chipScroll)
    }

    private fun renderChips() {
        groupChips.removeAllViews()
        for (g in GroupBy.values()) {
            val b = ui.button(g.label, Palette.GOLD, if (g == group) Ui.Style.FILLED else Ui.Style.TONAL) { group = g; libDetail = null; render(); list.setSelection(0) }
            groupChips.addView(ui.margins(b, l = 4, r = 4, t = 4, b = 6))
        }
        sortButton.text = "⇅ ${sort.label}"
        sortButton.visibility = if (group == GroupBy.SONGS) View.VISIBLE else View.GONE
    }

    private fun libraryScreen(): List<Item> {
        if (!hasAudioPermission()) return listOf(message("Local Hero needs permission to see the music on this device.", Palette.GOLD, "Allow access" to { askPermissions() }))
        if (!Hero.scanned) return listOf(message("Reading your music library…", Palette.GOLD))
        if (Hero.tracks.isEmpty()) return listOf(message("No music found on this device yet. Copy some songs into your Music folder, then tap ⟳.", Palette.GOLD))
        val d = libDetail
        if (d != null) {
            top(detailHeader(d.name, d.sub, Palette.GOLD, d.tracks, "＋ Playlist" to { addToPlaylist(d.tracks) }))
            return songItems(d.tracks, Palette.GOLD)
        }
        top(libTop)
        renderChips()
        val base = LibraryOps.search(Hero.tracks, query)
        if (group == GroupBy.SONGS) {
            val sorted = LibraryOps.sort(base, sort) { Hero.playCount(it) }
            val head = if (sorted.size > 1) listOf<Item>(Item.Header("${sorted.size} songs · tap to play, hold for options", Palette.GOLD)) else emptyList()
            return head + songItems(sorted, Palette.GOLD)
        }
        val buckets = LibraryOps.group(base, group) { Hero.moodOf(it) }
        return buckets.map { b -> Item.Entry(b.name, b.sub, "›", Palette.GOLD, onClick = { libDetail = b; render(); list.setSelection(0) }) }
    }

    // ---------------- Mixes

    private fun buildMixes(force: Boolean) {
        if (mixesBusy || (!force && mixes != null)) return
        mixesBusy = true
        Thread {
            val m = try { Hero.mixMaker().all(System.currentTimeMillis(), Calendar.getInstance().get(Calendar.HOUR_OF_DAY)) } catch (e: Exception) { emptyList() }
            runOnUiThread { mixes = m; mixesBusy = false; if (tab == Tab.MIXES) render() }
        }.start()
    }

    private fun mixesScreen(): List<Item> {
        val md = mixDetail
        if (md != null) {
            top(detailHeader(md.title, md.subtitle, Palette.TEAL, md.tracks, "Save as playlist" to {
                askText("Save mix as playlist", md.title.replace(Regex("^\\W+"), "")) { name -> Hero.store.createPlaylist(name, md.tracks.map { it.id }); toast("Saved “$name”") }
            }))
            return songItems(md.tracks, Palette.TEAL)
        }
        if (!Hero.scanned) return listOf(message("Waiting for your library…", Palette.TEAL))
        buildMixes(false)
        val card = ui.card(Palette.TEAL)
        val n = Hero.tracks.size
        val pct = Hero.features.size * 100 / maxOf(1, n)
        card.addView(ui.text(
            if (Hero.analysing) "Listening to your songs to learn their mood: ${Hero.analysisDone} of ${Hero.analysisTotal}. Mood mixes get better as this finishes."
            else "$pct% of your songs analysed. Mixes also learn from what you play, finish and skip.", 13.5f, Palette.TEXT))
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        row.addView(ui.button("↻ New picks", Palette.TEAL, Ui.Style.FILLED) { mixes = null; buildMixes(true); render() })
        if (Hero.analysing) row.addView(ui.margins(ui.button("Pause listening", Palette.TEAL) { Hero.pauseAnalysis() }, l = 8))
        else if (pct < 100) row.addView(ui.margins(ui.button("Analyse the rest", Palette.TEAL) { Hero.startAnalysis() }, l = 8))
        card.addView(ui.margins(row, t = 10))
        top(FrameLayout(this).apply { setPadding(ui.dp(14), ui.dp(4), ui.dp(14), ui.dp(4)); addView(card) })

        val m = mixes ?: return listOf(message("Making mixes…", Palette.TEAL))
        if (m.isEmpty()) return listOf(message("Not enough to go on yet. Play some music, or let the analysis run a little longer.", Palette.TEAL))
        val items = ArrayList<Item>()
        val habit = m.filter { it.key.startsWith("habit") }
        val mood = m.filter { it.key.startsWith("mood") }
        if (habit.isNotEmpty()) items.add(Item.Header("From your listening habits", Palette.TEAL))
        habit.forEach { items.add(mixEntry(it)) }
        if (mood.isNotEmpty()) items.add(Item.Header("By mood", Palette.TEAL))
        mood.forEach { items.add(mixEntry(it)) }
        return items
    }

    private fun mixEntry(m: Mix) = Item.Entry(m.title, "${m.subtitle} · ${m.tracks.size} songs", "▶", Palette.TEAL,
        onClick = { mixDetail = m; render(); list.setSelection(0) },
        onLong = { Playback.play(this, m.tracks, 0) })

    // ---------------- Playlists

    private fun playlistsScreen(): List<Item> {
        val pls = Hero.store.playlists()
        val pd = playlistDetail?.let { id -> pls.firstOrNull { it.id == id } }
        if (pd != null) {
            val songs = pd.trackIds.mapNotNull { Hero.byId[it] }
            top(detailHeader(pd.name, "${songs.size} songs · hold a song to move or remove it", Palette.VIOLET, songs,
                "Rename" to { askText("Rename playlist", pd.name) { Hero.store.renamePlaylist(pd.id, it); render() } },
                "Delete" to {
                    dialog().setTitle("Delete “${pd.name}”?").setMessage("Only the playlist is deleted, not the songs.")
                        .setPositiveButton("Delete") { _, _ -> Hero.store.deletePlaylist(pd.id); playlistDetail = null; render() }
                        .setNegativeButton("Cancel", null).show()
                }))
            return songItems(songs, Palette.VIOLET) { t, i ->
                val ids = songs.map { it.id }.toMutableList()
                listOf(
                    "Move up" to { if (i > 0) { ids.add(i - 1, ids.removeAt(i)); Hero.store.setPlaylistTracks(pd.id, ids); render() } },
                    "Move down" to { if (i < ids.size - 1) { ids.add(i + 1, ids.removeAt(i)); Hero.store.setPlaylistTracks(pd.id, ids); render() } },
                    "Remove from playlist" to { ids.removeAt(i); Hero.store.setPlaylistTracks(pd.id, ids); render() },
                )
            }
        }
        playlistDetail = null
        val newBtn = ui.button("＋ New playlist", Palette.VIOLET, Ui.Style.FILLED) {
            askText("New playlist", "") { Hero.store.createPlaylist(it, emptyList()); render() }
        }
        top(ui.row(newBtn).apply { setPadding(ui.dp(14), ui.dp(4), ui.dp(14), ui.dp(4)) })
        if (pls.isEmpty()) return listOf(message("No playlists yet. Make one here, hold any song and choose “Add to playlist”, or save a mix from the Mixes tab.", Palette.VIOLET))
        return pls.map { p ->
            val dur = p.trackIds.sumOf { Hero.byId[it]?.durationMs ?: 0 }
            Item.Entry(p.name, "${p.trackIds.size} songs · ${LibraryOps.formatTime(dur)}", "›", Palette.VIOLET, onClick = { playlistDetail = p.id; render(); list.setSelection(0) })
        }
    }

    // ---------------- Tidy

    private fun tidyScreen(): List<Item> {
        if (!Hero.scanned) return listOf(message("Waiting for your library…", Palette.CORAL))
        val chips = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(ui.dp(10), ui.dp(2), ui.dp(10), ui.dp(4)) }
        listOf("Duplicates", "Fix names", "Undo").forEachIndexed { i, label ->
            chips.addView(ui.margins(ui.button(label, Palette.CORAL, if (tidyMode == i) Ui.Style.FILLED else Ui.Style.TONAL) { tidyMode = i; render(); list.setSelection(0) }, l = 4, r = 4))
        }
        top(chips)
        return when (tidyMode) { 0 -> duplicatesScreen(); 1 -> namesScreen(); else -> undoScreen() }
    }

    private fun fileSub(t: Track): String {
        val kbps = if (t.bitrate > 0) "${t.bitrate / 1000} kbps" else t.extension.uppercase()
        return t.folder + " · " + kbps + " · " + mb(t.sizeBytes) + " · " + LibraryOps.formatTime(t.durationMs)
    }

    private fun tidyAction(vararg buttons: View) {
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        buttons.forEachIndexed { i, b -> row.addView(if (i == 0) b else ui.margins(b, l = 8)) }
        top(HorizontalScrollView(this).apply { isHorizontalScrollBarEnabled = false; setPadding(ui.dp(14), ui.dp(2), ui.dp(14), ui.dp(4)); addView(row) })
    }

    private fun duplicatesScreen(): List<Item> {
        val groups = dupGroups
        tidyAction(
            ui.button(if (tidyBusy) "Searching…" else if (groups == null) "Find duplicates" else "Search again", Palette.CORAL, Ui.Style.FILLED) { findDuplicates() },
            ui.button("Trash ${dupSelected.size} selected", Palette.CORAL, Ui.Style.OUTLINE) { trashSelected() }.apply { isEnabled = dupSelected.isNotEmpty(); alpha = if (dupSelected.isEmpty()) 0.4f else 1f },
        )
        if (groups == null) return listOf(message(
            "Finds the same song saved more than once — exact copies, the same artist & title in different folders, and (once analysed) files that sound identical.\n\n" +
                "The best copy of each (lossless or highest quality, good tags, tidy folder) is marked ★ and left unticked. Ticked files go to the system trash, which you can restore from for 30 days.", Palette.CORAL))
        if (groups.isEmpty()) return listOf(message("No duplicates found. Nice and tidy!", Palette.CORAL))
        val items = ArrayList<Item>()
        val wasted = groups.sumOf { g -> g.extras.sumOf { it.sizeBytes } }
        items.add(Item.Header("${groups.size} songs with copies · %.0f MB in extra copies".format(wasted / 1_048_576.0), Palette.CORAL))
        for (g in groups) {
            items.add(Item.Header("${g.keep.artist.ifBlank { "?" }} – ${g.keep.title.ifBlank { g.keep.displayName }}  ·  ${g.reason}${if (!g.sure) " (check)" else ""}", Palette.TEXT_DIM))
            for (t in listOf(g.keep) + g.extras) {
                val isKeep = t.id == g.keep.id
                items.add(Item.Entry((if (isKeep) "★ " else "") + t.displayName, fileSub(t), if (isKeep) "best" else "", Palette.CORAL,
                    checked = t.id in dupSelected,
                    onCheck = { c ->
                        if (c) dupSelected.add(t.id) else dupSelected.remove(t.id)
                        val all = (listOf(g.keep) + g.extras).all { it.id in dupSelected }
                        if (all) toast("Careful: every copy of this song is ticked")
                        render()
                    },
                    onLong = { Playback.play(this, listOf(t), 0); toast("Playing this copy") }))
            }
        }
        return items
    }

    private fun findDuplicates() {
        if (tidyBusy) return
        tidyBusy = true; render()
        Thread {
            val g = Duplicates.find(Hero.raw, HashMap(Hero.features))
            runOnUiThread {
                tidyBusy = false; dupGroups = g
                dupSelected.clear()
                g.filter { it.sure }.forEach { grp -> grp.extras.forEach { dupSelected.add(it.id) } }
                render(); list.setSelection(0)
            }
        }.start()
    }

    private fun trashSelected() {
        val ids = dupSelected.toList()
        if (ids.isEmpty()) return
        fileOps.trash(ids) { ok ->
            if (ok) {
                toast("Moved ${ids.size} files to the trash")
                Hero.forgetFiles(ids)
                dupGroups = dupGroups?.mapNotNull { g ->
                    val left = (listOf(g.keep) + g.extras).filter { it.id !in ids }
                    if (left.size < 2) null else g.copy(keep = left.first(), extras = left.drop(1))
                }
                dupSelected.clear()
                render()
                Hero.refresh()
            }
        }
    }

    private fun namesScreen(): List<Item> {
        val f = fixes
        val organizeBox = CheckBox(this).apply {
            text = "Also sort into Music/Artist/Album folders"; setTextColor(Palette.TEXT); isChecked = organize
            buttonTintList = android.content.res.ColorStateList.valueOf(Palette.CORAL)
            setOnCheckedChangeListener { _, c -> organize = c; if (fixes != null) planNames() }
        }
        top(ui.row(organizeBox).apply { setPadding(ui.dp(14), 0, ui.dp(14), 0) })
        val n = fixSelected.size
        tidyAction(
            ui.button(if (tidyBusy) "Checking…" else if (f == null) "Check names" else "Check again", Palette.CORAL, Ui.Style.FILLED) { planNames() },
            ui.button("Rename $n files", Palette.CORAL, Ui.Style.OUTLINE) { applyNames(true) }.apply { isEnabled = n > 0; alpha = if (n == 0) 0.4f else 1f },
            ui.button("Fix names in app only", Palette.CORAL, Ui.Style.GHOST) { applyNames(false) }.apply { isEnabled = n > 0; alpha = if (n == 0) 0.4f else 1f },
        )
        if (f == null) return listOf(message(
            "Looks for songs with missing or junk names (“Track 01”, “<unknown>”, website names, “(Official Video)”, “copy (2)”, underscores, ALL CAPS) and works out the real artist and title from the tags, file name and folder.\n\n" +
                "“Rename files” renames them to “Artist - Title” (Android asks you to allow it). “Fix names in app only” leaves the files alone and just shows clean names here. Renames can be undone.", Palette.CORAL))
        if (f.isEmpty()) return listOf(message("All your song names look good.", Palette.CORAL))
        val items = ArrayList<Item>()
        items.add(Item.Header("${f.size} songs could be tidied · tap to tick/untick", Palette.CORAL))
        for (x in f) {
            val newPath = (x.newFolder ?: "") + x.newFileName
            val sub = if (x.changesFile) "${x.track.displayName}  →  $newPath" else "tags: ${x.track.artist.ifBlank { "?" }} – ${x.track.title}"
            items.add(Item.Entry("${x.artist.ifBlank { "?" }} – ${x.title}", sub, "", Palette.CORAL, checked = x.track.id in fixSelected,
                onCheck = { c -> if (c) fixSelected.add(x.track.id) else fixSelected.remove(x.track.id); render() },
                onLong = { editFix(x) }))
        }
        return items
    }

    /** Lets the user correct a guess by hand. */
    private fun editFix(x: NameFix) {
        askText("Artist – Title", "${x.artist} – ${x.title}") { s ->
            val parts = s.split(Regex("\\s+[-–]\\s+"), limit = 2)
            val artist = if (parts.size == 2) parts[0].trim() else x.artist
            val title = (if (parts.size == 2) parts[1] else parts[0]).trim()
            val ext = x.track.extension.ifEmpty { "mp3" }
            val stem = com.hatdagger.localhero.core.Names.safeFileName(if (artist.isNotBlank()) "$artist - $title" else title)
            val folder = if (organize) "Music/${com.hatdagger.localhero.core.Names.safeFileName(artist).ifBlank { "Unknown Artist" }}/${com.hatdagger.localhero.core.Names.safeFileName(x.album).ifBlank { "Singles" }}/" else null
            val updated = x.copy(artist = artist, title = title, newFileName = "$stem.$ext", newFolder = folder)
            fixes = fixes?.map { if (it.track.id == x.track.id) updated else it }
            fixSelected.add(x.track.id)
            render()
        }
    }

    private fun planNames() {
        if (tidyBusy) return
        tidyBusy = true; render()
        Thread {
            val plan = NameFixer.plan(Hero.raw, organize).filter { fx ->
                // Skip songs already fixed in the app unless the file itself still needs renaming.
                val shown = Hero.byId[fx.track.id]
                fx.changesFile || shown == null || shown.title != fx.title || shown.artist != fx.artist
            }
            runOnUiThread {
                tidyBusy = false; fixes = plan
                fixSelected.clear(); plan.forEach { fixSelected.add(it.track.id) }
                render(); list.setSelection(0)
            }
        }.start()
    }

    private fun applyNames(renameFiles: Boolean) {
        val chosen = fixes?.filter { it.track.id in fixSelected } ?: return
        if (chosen.isEmpty()) return
        val run = {
            tidyBusy = true; render()
            Thread {
                val (ok, errors) = fileOps.applyFixes(chosen, renameFiles)
                runOnUiThread {
                    tidyBusy = false
                    fixes = fixes?.filter { it.track.id !in fixSelected || errors.any { e -> e.startsWith(it.track.displayName) } }
                    fixSelected.clear()
                    val msg = if (renameFiles) "Renamed $ok files" else "Cleaned up $ok names in the app"
                    if (errors.isEmpty()) toast(msg)
                    else dialog().setTitle(msg).setMessage("Couldn't change ${errors.size}:\n\n" + errors.take(20).joinToString("\n")).setPositiveButton("OK", null).show()
                    Hero.refresh()
                    render()
                }
            }.start()
        }
        val needWrite = renameFiles && chosen.any { it.changesFile }
        if (needWrite) fileOps.requestWrite(chosen.filter { it.changesFile }.map { it.track.id }) { run() } else run()
    }

    private fun undoScreen(): List<Item> {
        val log = Hero.store.renames()
        tidyAction(
            ui.button("Undo ${undoSelected.size} renames", Palette.CORAL, Ui.Style.FILLED) { undoRenames(log.filter { it.id in undoSelected }) }
                .apply { isEnabled = undoSelected.isNotEmpty(); alpha = if (undoSelected.isEmpty()) 0.4f else 1f },
            ui.button("Select all", Palette.CORAL, Ui.Style.GHOST) { undoSelected.clear(); log.forEach { undoSelected.add(it.id) }; render() },
        )
        if (log.isEmpty()) return listOf(message("Nothing to undo. Files renamed or moved by Local Hero show up here so you can put them back.", Palette.CORAL))
        return log.map { r ->
            val date = android.text.format.DateFormat.getMediumDateFormat(this).format(java.util.Date(r.at))
            Item.Entry(r.newName, "was ${r.oldFolder}${r.oldName} · $date", "", Palette.CORAL, checked = r.id in undoSelected,
                onCheck = { c -> if (c) undoSelected.add(r.id) else undoSelected.remove(r.id); render() })
        }
    }

    private fun undoRenames(chosen: List<Store.Rename>) {
        if (chosen.isEmpty()) return
        // Undo newest first, one entry per song.
        val latest = chosen.sortedByDescending { it.id }.distinctBy { it.trackId }
        fileOps.requestWrite(latest.map { it.trackId }) {
            Thread {
                val errors = ArrayList<String>()
                val done = ArrayList<Long>()
                for (r in latest) {
                    val err = fileOps.applyFileChange(r.trackId, r.oldName, r.oldFolder)
                    if (err == null) { done.addAll(chosen.filter { it.trackId == r.trackId }.map { it.id }); Hero.store.setOverride(r.trackId, null) }
                    else errors.add("${r.newName}: $err")
                }
                Hero.store.deleteRenames(done)
                runOnUiThread {
                    undoSelected.clear()
                    if (errors.isEmpty()) toast("Put ${latest.size} files back") else dialog().setTitle("Some couldn't be undone").setMessage(errors.joinToString("\n")).setPositiveButton("OK", null).show()
                    Hero.refresh(); render()
                }
            }.start()
        }
    }

    // ---------------- mini player

    private fun buildMini(): View {
        miniArt = ImageView(this).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            background = ui.rounded(Palette.SURFACE_HI, 10); clipToOutline = true
            layoutParams = LinearLayout.LayoutParams(ui.dp(46), ui.dp(46))
        }
        miniTitle = ui.text("", 14.5f, Palette.TEXT, bold = true, lines = 1)
        miniSub = ui.text("", 12.5f, Palette.TEXT_DIM, lines = 1)
        val col = ui.column(miniTitle, miniSub).apply { setPadding(ui.dp(12), 0, ui.dp(6), 0) }
        miniPlay = ui.glyph("▶", Palette.GOLD, 44, filled = true) { Playback.toggle(this) }
        val next = ui.glyph("⏭", Palette.GOLD, 40) { Playback.next(this) }
        val row = ui.row(miniArt, ui.weight(col), miniPlay, next).apply { setPadding(ui.dp(12), ui.dp(8), ui.dp(8), ui.dp(8)) }
        miniProgress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 1000
            progressTintList = android.content.res.ColorStateList.valueOf(Palette.GOLD)
            progressBackgroundTintList = android.content.res.ColorStateList.valueOf(Palette.SURFACE_HI)
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ui.dp(3))
        }
        mini = ui.column(miniProgress, row).apply {
            setBackgroundColor(Palette.SURFACE)
            setOnClickListener { openNowPlaying() }
            visibility = View.GONE
        }
        return mini
    }

    private fun onPlaybackChanged() {
        val t = Playback.current
        mini.visibility = if (t == null) View.GONE else View.VISIBLE
        miniTitle.text = t?.title ?: ""
        miniSub.text = t?.let { songSub(it) } ?: ""
        miniPlay.text = if (Playback.playing) "❚❚" else "▶"
        if (t != null && t.id != shownTrackId) {
            shownTrackId = t.id
            artBitmap = null; miniArt.setImageDrawable(null); nowArt?.setImageDrawable(null)
            Thread {
                val bmp = try { contentResolver.loadThumbnail(Hero.uriOf(t.id), Size(600, 600), null) } catch (e: Exception) { null }
                runOnUiThread { if (shownTrackId == t.id) { artBitmap = bmp; miniArt.setImageBitmap(bmp); nowArt?.setImageBitmap(bmp); if (bmp == null) nowArt?.setImageDrawable(null) } }
            }.start()
            render() // updates the highlighted song
        }
        updateNowPlaying()
        updateProgress()
    }

    private fun updateProgress() {
        val d = Playback.duration()
        val p = Playback.position()
        miniProgress.progress = if (d > 0) (p * 1000 / d).toInt() else 0
        if (!seeking) nowSeek?.let { s -> s.max = d.toInt().coerceAtLeast(1); s.progress = p.toInt() }
        nowTimes?.text = "${LibraryOps.formatTime(p)}  /  ${LibraryOps.formatTime(d)}"
        nowSleep?.text = if (Playback.sleepAtMs > 0) "☾ ${((Playback.sleepAtMs - System.currentTimeMillis()) / 60_000 + 1).coerceAtLeast(0)} min" else "☾ Sleep"
    }

    // ---------------- now playing

    private fun openNowPlaying() {
        if (nowView != null || Playback.current == null) return
        val wide = resources.displayMetrics.widthPixels > resources.displayMetrics.heightPixels
        val panel = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(Palette.BG); isClickable = true }
        panel.addView(ui.row(ui.button("▾ Close", Palette.GOLD, Ui.Style.GHOST) { closeNowPlaying() }).apply { setPadding(ui.dp(8), ui.dp(12), ui.dp(8), 0) })

        val art = ImageView(this).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            background = ui.rounded(Palette.SURFACE_HI, 22); clipToOutline = true
            artBitmap?.let { setImageBitmap(it) }
        }
        nowArt = art
        val artSize = if (wide) (resources.displayMetrics.heightPixels * 0.42).toInt() else (resources.displayMetrics.widthPixels * 0.62).toInt()
        val artWrap = FrameLayout(this).apply {
            addView(art, FrameLayout.LayoutParams(artSize, artSize, Gravity.CENTER))
        }
        nowTitle = ui.text("", 22f, Palette.TEXT, bold = true, lines = 2).apply { gravity = Gravity.CENTER }
        nowSub = ui.text("", 14f, Palette.TEXT_DIM, lines = 2).apply { gravity = Gravity.CENTER }
        nowMood = ui.button("", Palette.TEAL, Ui.Style.TONAL) { Playback.current?.let { pickMood(it) } }
        nowSeek = SeekBar(this).apply {
            progressTintList = android.content.res.ColorStateList.valueOf(Palette.GOLD)
            thumbTintList = android.content.res.ColorStateList.valueOf(Palette.GOLD)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(s: SeekBar, p: Int, fromUser: Boolean) { if (fromUser) nowTimes?.text = "${LibraryOps.formatTime(p.toLong())}  /  ${LibraryOps.formatTime(Playback.duration())}" }
                override fun onStartTrackingTouch(s: SeekBar) { seeking = true }
                override fun onStopTrackingTouch(s: SeekBar) { seeking = false; Playback.seek(this@MainActivity, s.progress.toLong()) }
            })
        }
        nowTimes = ui.text("", 12.5f, Palette.TEXT_DIM).apply { gravity = Gravity.CENTER }
        nowShuffle = ui.glyph("⤮", Palette.GOLD, 46) { Playback.setShuffle(!Playback.shuffle) }
        nowRepeat = ui.glyph("↻", Palette.GOLD, 46) { Playback.cycleRepeat() }
        nowPlay = ui.glyph("▶", Palette.GOLD, 72, filled = true) { Playback.toggle(this) }
        val controls = ui.row(nowShuffle!!, ui.glyph("⏮", Palette.GOLD, 56) { Playback.prev(this) }, nowPlay!!,
            ui.glyph("⏭", Palette.GOLD, 56) { Playback.next(this) }, nowRepeat!!, gravity = Gravity.CENTER).apply { gravity = Gravity.CENTER }
        nowSleep = ui.button("☾ Sleep", Palette.GOLD, Ui.Style.GHOST) { pickSleep() }
        val extras = ui.row(
            nowMood!!,
            ui.margins(ui.button("≈ Like this", Palette.TEAL, Ui.Style.GHOST) { Playback.current?.let { showSoundsLike(it) } }, l = 6),
            ui.margins(ui.button("＋ Playlist", Palette.VIOLET, Ui.Style.GHOST) { Playback.current?.let { addToPlaylist(listOf(it)) } }, l = 6),
            ui.margins(nowSleep!!, l = 6),
        )
        val extrasScroll = HorizontalScrollView(this).apply { isHorizontalScrollBarEnabled = false; addView(extras) }
        val info = ui.column(artWrap, ui.margins(nowTitle!!, t = 14), nowSub!!, ui.margins(nowSeek!!, t = 12), nowTimes!!, ui.margins(controls, t = 8), ui.margins(extrasScroll, t = 8)).apply {
            gravity = Gravity.CENTER_HORIZONTAL; setPadding(ui.dp(20), 0, ui.dp(20), ui.dp(8))
        }
        (extrasScroll.layoutParams as LinearLayout.LayoutParams).gravity = Gravity.CENTER_HORIZONTAL

        val qa = ItemAdapter(this, ui)
        queueAdapter = qa
        val queueList = ListView(this).apply { adapter = qa; divider = null; setSelector(android.R.color.transparent) }
        val queueCol = ui.column(ui.text("UP NEXT", 12f, Palette.GOLD, bold = true).apply { setPadding(ui.dp(16), ui.dp(8), 0, ui.dp(4)); letterSpacing = 0.08f })
        queueCol.addView(queueList, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        if (wide) {
            val body = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            body.addView(info, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1.1f))
            body.addView(queueCol, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
            info.gravity = Gravity.CENTER
            panel.addView(body, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        } else {
            panel.addView(info)
            panel.addView(queueCol, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        rootFrame.addView(panel, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        nowView = panel
        updateNowPlaying(); updateProgress()
        queueList.setSelection(maxOf(0, Playback.index - 1))
    }

    private fun closeNowPlaying() {
        nowView?.let { rootFrame.removeView(it) }
        nowView = null; nowSeek = null; nowTimes = null; nowPlay = null; nowArt = null; nowTitle = null; nowSub = null
        nowMood = null; nowShuffle = null; nowRepeat = null; nowSleep = null; queueAdapter = null
    }

    private fun updateNowPlaying() {
        if (nowView == null) return
        val t = Playback.current ?: run { closeNowPlaying(); return }
        nowTitle?.text = t.title.ifBlank { t.displayName }
        nowSub?.text = songSub(t)
        nowPlay?.text = if (Playback.playing) "❚❚" else "▶"
        val mood = Hero.moodOf(t)
        nowMood?.text = if (mood != null) "${mood.emoji} ${mood.label}" else "Set mood"
        nowShuffle?.alpha = if (Playback.shuffle) 1f else 0.4f
        nowRepeat?.text = if (Playback.repeat == Repeat.ONE) "↻1" else "↻"
        nowRepeat?.alpha = if (Playback.repeat == Repeat.OFF) 0.4f else 1f
        queueAdapter?.items = Playback.queue.mapIndexed { i, q ->
            Item.Entry(q.title.ifBlank { q.displayName }, songSub(q), if (i == Playback.index) "♪" else LibraryOps.formatTime(q.durationMs), Palette.GOLD,
                highlight = i == Playback.index,
                onClick = { Playback.jump(this, i) },
                onLong = {
                    val opts = listOf("Move up", "Move down", "Remove from queue")
                    dialog().setTitle(q.title).setItems(opts.toTypedArray()) { _, k ->
                        when (k) { 0 -> Playback.moveItem(i, i - 1); 1 -> Playback.moveItem(i, i + 1); 2 -> Playback.removeAt(i) }
                    }.show()
                })
        }
    }

    private fun pickSleep() {
        val mins = listOf(0, 15, 30, 45, 60, 90)
        val labels = mins.map { if (it == 0) "Off" else "$it minutes" }
        dialog().setTitle("Stop playing after…").setItems(labels.toTypedArray()) { _, i -> Playback.setSleep(mins[i]); updateProgress() }.show()
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        // Re-lay out the player for the new orientation (side-by-side on a landscape tablet).
        if (nowView != null) { closeNowPlaying(); main.post { openNowPlaying() } }
    }

    // ---------------- back

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        when {
            nowView != null -> closeNowPlaying()
            tab == Tab.LIBRARY && libDetail != null -> { libDetail = null; render() }
            tab == Tab.MIXES && mixDetail != null -> { mixDetail = null; render() }
            tab == Tab.PLAYLISTS && playlistDetail != null -> { playlistDetail = null; render() }
            tab != Tab.LIBRARY -> { tab = Tab.LIBRARY; renderTabs(); render() }
            else -> moveTaskToBack(true) // keep music playing
        }
    }
}
