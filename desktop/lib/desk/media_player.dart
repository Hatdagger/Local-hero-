import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import 'desk.dart';
import 'explorer.dart' show confirmBox, promptBox;
import 'media_library.dart';
import 'mixes.dart';
import 'playlists.dart';
import 'window_manager.dart';
import 'xp_theme.dart';

export 'media_library.dart';

enum Repeat { off, all, one }

// ======================================================================
// Playback (the desktop's own player; keeps going when its window closes)

class DeskPlayer extends ChangeNotifier {
  DeskPlayer._() {
    unawaited(_loadPrefs());
    unawaited(VisSettings.load());
    if (!kIsWeb && Platform.isAndroid) _LockScreenControls(this);
  }
  static final instance = DeskPlayer._();

  List<MediaItem> queue = const [];
  List<MediaItem> _original = const [];
  int index = -1;
  bool shuffle = false;
  Repeat repeat = Repeat.off;
  double volume = 1;
  bool muted = false;
  String? error;

  VideoPlayerController? controller;
  bool _ending = false;
  int _loadSerial = 0;

  /// Play counts, for "Most played".
  Map<String, int> plays = {};

  MediaItem? get current => index >= 0 && index < queue.length ? queue[index] : null;
  bool get playing => controller?.value.isPlaying ?? false;
  Duration get position => controller?.value.position ?? Duration.zero;
  Duration get duration {
    final d = controller?.value.duration ?? Duration.zero;
    if (d > Duration.zero) return d;
    return Duration(milliseconds: current?.durationMs ?? 0);
  }

  bool get isVideo => current?.video ?? false;

  /// The video fills the whole screen (above the taskbar).
  bool fullScreen = false;

  void setFullScreen(bool on) {
    if (on && !isVideo) return;
    if (fullScreen == on) return;
    fullScreen = on;
    notifyListeners();
  }

  /// Spectrum of the current song for the visualizer: [kBands] values per
  /// 1/30 s, worked out by DeskSound.kt when the song starts. Null until ready.
  Uint8List? spectrum;
  String? _spectrumKey;
  static const kBands = 24;
  static const kSpectrumFps = 30;

  void _loadSpectrum(MediaItem m) {
    if (m.video || m.uri.isEmpty || _spectrumKey == m.key) return;
    _spectrumKey = m.key;
    spectrum = null;
    unawaited(() async {
      Uint8List? bytes;
      try {
        bytes = await const MethodChannel('desk/library').invokeMethod<Uint8List>('spectrum', {'uri': m.uri});
      } catch (_) {}
      if (_spectrumKey != m.key) return;
      spectrum = bytes;
      notifyListeners();
    }());
  }

  /// Band levels (0..1) at the current position, or null.
  List<double>? bandsNow() {
    final sp = spectrum;
    if (sp == null || current?.video == true) return null;
    final frames = sp.length ~/ kBands;
    final f = (position.inMilliseconds * kSpectrumFps / 1000).floor();
    if (f < 0 || f >= frames) return null;
    return [for (var b = 0; b < kBands; b++) sp[f * kBands + b] / 255];
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    volume = p.getDouble('playerVolume') ?? 1;
    shuffle = p.getBool('playerShuffle') ?? false;
    repeat = Repeat.values.firstWhere((r) => r.name == p.getString('playerRepeat'), orElse: () => Repeat.off);
    try {
      plays = Map<String, int>.from(jsonDecode(p.getString('playerPlays') ?? '{}') as Map);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('playerVolume', volume);
    await p.setBool('playerShuffle', shuffle);
    await p.setString('playerRepeat', repeat.name);
    await p.setString('playerPlays', jsonEncode(plays));
  }

  int playsOf(MediaItem m) => plays[m.key] ?? 0;

  // Listening history for Auto Mixes: one entry per song started.
  MediaItem? _ev;
  int _evStart = 0;
  int _evMaxMs = 0;

  void _startEvent(MediaItem m) {
    _ev = m.video ? null : m;
    _evStart = DateTime.now().millisecondsSinceEpoch;
    _evMaxMs = 0;
  }

  void _endEvent({bool completed = false}) {
    final m = _ev;
    _ev = null;
    if (m == null) return;
    final dur = duration.inMilliseconds > 0 ? duration.inMilliseconds : m.durationMs;
    final done = completed || (dur > 0 && _evMaxMs >= dur * 0.9);
    AutoMixes.instance.record(PlayEvent(m.key, _evStart, done ? math.max(_evMaxMs, dur) : _evMaxMs, dur, done));
  }

  /// Plays [list] from [start].
  Future<void> play(List<MediaItem> list, int start, {bool? shuffled}) async {
    if (list.isEmpty) return;
    final s = start.clamp(0, list.length - 1);
    _original = List.of(list);
    if (shuffled != null) shuffle = shuffled;
    if (shuffle) {
      final first = list[s];
      final rest = List.of(list)..removeAt(s);
      rest.shuffle(math.Random());
      queue = [first, ...rest];
      index = 0;
    } else {
      queue = List.of(list);
      index = s;
    }
    await _load(autoplay: true);
  }

  Future<void> playOne(MediaItem m) => play([m], 0, shuffled: false);

  Future<void> playFile(String path, {required bool video}) => playOne(MediaItem.fromPath(path, video: video));

  Future<void> _load({required bool autoplay}) async {
    final serial = ++_loadSerial;
    _endEvent();
    final old = controller;
    controller = null;
    old?.removeListener(_onTick);
    unawaited(old?.dispose());
    error = null;
    _ending = false;
    notifyListeners();
    final m = current;
    if (m == null) return;
    if (!m.video && fullScreen) fullScreen = false;
    _loadSpectrum(m);
    final VideoPlayerController c;
    final opts = VideoPlayerOptions(allowBackgroundPlayback: !m.video, mixWithOthers: false);
    if (m.uri.isNotEmpty && !kIsWeb && Platform.isAndroid) {
      c = VideoPlayerController.contentUri(Uri.parse(m.uri), videoPlayerOptions: opts);
    } else {
      c = VideoPlayerController.file(File(m.path), videoPlayerOptions: opts);
    }
    try {
      await c.initialize();
    } catch (e) {
      await c.dispose();
      if (serial != _loadSerial) return;
      error = "Can't play '${m.title}'.";
      notifyListeners();
      // Skip to the next one after a broken file, like a real player.
      if (queue.length > 1 && index < queue.length - 1) {
        Timer(const Duration(seconds: 2), () {
          if (serial == _loadSerial) unawaited(next());
        });
      }
      return;
    }
    if (serial != _loadSerial) {
      await c.dispose();
      return;
    }
    controller = c;
    await c.setVolume(muted ? 0 : volume);
    c.addListener(_onTick);
    if (autoplay) await c.play();
    _startEvent(m);
    plays[m.key] = (plays[m.key] ?? 0) + 1;
    unawaited(_savePrefs());
    notifyListeners();
  }

  void _onTick() {
    final c = controller;
    if (c == null) return;
    final v = c.value;
    if (_ev != null && v.position.inMilliseconds > _evMaxMs) _evMaxMs = v.position.inMilliseconds;
    if (v.hasError && error == null) {
      error = v.errorDescription ?? "Can't play this file.";
    }
    final done = v.duration > Duration.zero && v.position >= v.duration - const Duration(milliseconds: 200) && !v.isPlaying;
    if (done && !_ending) {
      _ending = true;
      scheduleMicrotask(_finished);
    }
    notifyListeners();
  }

  Future<void> _finished() async {
    final m = current;
    _endEvent(completed: true);
    if (repeat == Repeat.one) {
      if (m != null) _startEvent(m);
      await seek(Duration.zero);
      await controller?.play();
      _ending = false;
      return;
    }
    if (index < queue.length - 1) {
      index++;
      await _load(autoplay: true);
    } else if (repeat == Repeat.all && queue.isNotEmpty) {
      index = 0;
      await _load(autoplay: true);
    } else {
      notifyListeners();
    }
  }

  Future<void> toggle() async {
    final c = controller;
    if (c == null) {
      if (current != null) await _load(autoplay: true);
      return;
    }
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      if (c.value.position >= c.value.duration && c.value.duration > Duration.zero) {
        await c.seekTo(Duration.zero);
        if (current != null) _startEvent(current!);
      }
      _ending = false;
      await c.play();
    }
    notifyListeners();
  }

  Future<void> pause() async {
    await controller?.pause();
    notifyListeners();
  }

  Future<void> stop() async {
    await controller?.pause();
    await controller?.seekTo(Duration.zero);
    notifyListeners();
  }

  Future<void> next() async {
    if (queue.isEmpty) return;
    if (index < queue.length - 1) {
      index++;
    } else if (repeat == Repeat.all) {
      index = 0;
    } else {
      return;
    }
    await _load(autoplay: true);
  }

  Future<void> previous() async {
    if (queue.isEmpty) return;
    // Back to the start of the song first, like most players.
    if (position > const Duration(seconds: 3) || index == 0) {
      await seek(Duration.zero);
      return;
    }
    index--;
    await _load(autoplay: true);
  }

  Future<void> jump(int i) async {
    if (i < 0 || i >= queue.length) return;
    index = i;
    await _load(autoplay: true);
  }

  /// Goes up by one on every seek, so the lock screen can follow jumps.
  int seekSerial = 0;

  Future<void> seek(Duration d) async {
    _ending = false;
    await controller?.seekTo(d);
    seekSerial++;
    notifyListeners();
  }

  Future<void> setVolume(double v) async {
    volume = v.clamp(0.0, 1.0);
    muted = false;
    await controller?.setVolume(volume);
    unawaited(_savePrefs());
    notifyListeners();
  }

  Future<void> toggleMute() async {
    muted = !muted;
    await controller?.setVolume(muted ? 0 : volume);
    notifyListeners();
  }

  void setShuffle(bool on) {
    shuffle = on;
    final cur = current;
    if (cur != null) {
      if (on) {
        final rest = List.of(queue)..removeAt(index);
        rest.shuffle(math.Random());
        if (_original.isEmpty) _original = List.of(queue);
        queue = [cur, ...rest];
        index = 0;
      } else if (_original.isNotEmpty) {
        queue = List.of(_original);
        index = math.max(0, queue.indexWhere((m) => m.key == cur.key));
      }
    }
    unawaited(_savePrefs());
    notifyListeners();
  }

  void cycleRepeat() {
    repeat = Repeat.values[(repeat.index + 1) % Repeat.values.length];
    unawaited(_savePrefs());
    notifyListeners();
  }

  void playNext(MediaItem m) {
    if (queue.isEmpty) {
      unawaited(playOne(m));
      return;
    }
    queue = [...queue]..insert(index + 1, m);
    _original = [..._original, m];
    notifyListeners();
  }

  void addToQueue(MediaItem m) {
    if (queue.isEmpty) {
      unawaited(playOne(m));
      return;
    }
    queue = [...queue, m];
    _original = [..._original, m];
    notifyListeners();
  }

  void removeAt(int i) {
    if (i == index || i < 0 || i >= queue.length) return;
    final gone = queue[i];
    queue = [...queue]..removeAt(i);
    _original = _original.where((m) => m.key != gone.key).toList();
    if (i < index) index--;
    notifyListeners();
  }
}

// ======================================================================
// Shared widgets

String fmt(Duration d) => LibraryOps.formatTime(d.inMilliseconds);

/// Album art / video frame, or a note icon.
class MediaArt extends StatefulWidget {
  const MediaArt({super.key, required this.item, this.size = 48});
  final MediaItem? item;
  final double size;

  @override
  State<MediaArt> createState() => _MediaArtState();
}

class _MediaArtState extends State<MediaArt> {
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MediaArt old) {
    super.didUpdateWidget(old);
    if (old.item?.key != widget.item?.key) _load();
  }

  void _load() {
    final i = widget.item;
    if (i == null) return;
    MediaLibrary.instance.loadArt(i).then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.item;
    final bytes = i == null ? null : MediaLibrary.instance.artFor(i);
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: const Color(0xFF1E3E9B),
        border: Border.all(color: const Color(0xFF7F9DB9)),
      ),
      child: bytes != null
          ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
          : Icon(i?.video == true ? Icons.movie : Icons.music_note, size: widget.size * 0.5, color: Colors.white70),
    );
  }
}

class RoundButton extends StatelessWidget {
  const RoundButton({super.key, required this.icon, required this.tip, required this.onTap, this.size = 28, this.on = false});
  final IconData icon;
  final String tip;
  final VoidCallback? onTap;
  final double size;
  final bool on;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tip,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Xp.buttonBorder),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: on
                    ? const [Color(0xFFBFD6FF), Color(0xFF8DB2F2)]
                    : const [Color(0xFFFFFFFF), Color(0xFFECEBE6), Color(0xFFD6D0C5)],
              ),
            ),
            child: Icon(icon, size: size * 0.62, color: onTap == null ? const Color(0xFFAAAAAA) : const Color(0xFF1E3E9B)),
          ),
        ),
      );
}

/// Position slider with times, used by both players.
class SeekBar extends StatefulWidget {
  const SeekBar({super.key, required this.player, this.light = false});
  final DeskPlayer player;
  final bool light;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    final dur = p.duration.inMilliseconds.toDouble();
    final pos = (_drag ?? p.position.inMilliseconds.toDouble()).clamp(0.0, dur > 0 ? dur : 1.0).toDouble();
    final style = Xp.text.copyWith(fontSize: 11, color: widget.light ? Colors.white : null);
    return Row(children: [
      Text(LibraryOps.formatTime(pos.round()), style: style),
      Expanded(
        child: SizedBox(
          height: 22,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
              activeTrackColor: widget.light ? const Color(0xFF8FD14F) : Xp.selection,
              thumbColor: widget.light ? Colors.white : Xp.selection,
            ),
            child: Slider(
              value: pos,
              min: 0,
              max: dur > 0 ? dur : 1,
              onChanged: dur > 0 ? (v) => setState(() => _drag = v) : null,
              onChangeEnd: dur > 0
                  ? (v) {
                      setState(() => _drag = null);
                      p.seek(Duration(milliseconds: v.round()));
                    }
                  : null,
            ),
          ),
        ),
      ),
      Text(dur > 0 ? LibraryOps.formatTime(dur.round()) : '', style: style),
    ]);
  }
}

// ======================================================================
// Media Player window

const kMediaPlayerId = 'mediaplayer';

DeskWindow mediaPlayerWindow({int tab = 0}) => DeskWindow(
      id: kMediaPlayerId,
      title: 'Media Player',
      icon: Icons.play_circle,
      size: const Size(900, 600),
      minSize: const Size(520, 360),
      content: (c, w) => _PlayerWindow(w: w, startTab: tab),
    );

class _PlayerWindow extends StatefulWidget {
  const _PlayerWindow({required this.w, required this.startTab});
  final DeskWindow w;
  final int startTab;

  @override
  State<_PlayerWindow> createState() => _PlayerWindowState();
}

enum _Tab { nowPlaying, library, videos, mixes, playlist }

/// Songs dragged from the library (with the mouse) onto a playlist.
class _SongDrag {
  final List<MediaItem> items;
  const _SongDrag(this.items);
}

class _PlayerWindowState extends State<_PlayerWindow> {
  final lib = MediaLibrary.instance;
  final player = DeskPlayer.instance;
  final lists = Playlists.instance;
  final auto = AutoMixes.instance;
  Playlist? _list;
  Mix? _mix;
  bool _analyseStarted = false;
  VisStyle _vis = VisSettings.style;
  bool _mouse = false;
  late _Tab _tab = _Tab.values[widget.startTab.clamp(0, 3)];
  GroupBy _group = GroupBy.songs;
  Bucket? _bucket;
  SortBy _sort = SortBy.artist;
  final _search = TextEditingController();
  String? _selected;

  @override
  void initState() {
    super.initState();
    if (!lib.scanned) unawaited(lib.scan());
    if (player.current == null && widget.startTab == 0) _tab = _Tab.library;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<MediaItem> _visibleSongs() {
    var list = _bucket?.items ?? lib.songs;
    list = LibraryOps.search(list, _search.text);
    if (_bucket == null) list = LibraryOps.sort(list, _sort, plays: player.playsOf);
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([lib, player, lists, auto]),
      builder: (c, _) {
        if (!_analyseStarted && lib.scanned && lib.songs.isNotEmpty) {
          _analyseStarted = true;
          scheduleMicrotask(() => auto.analyse(lib.songs));
        }
        if (_tab == _Tab.playlist && !lists.lists.contains(_list)) {
          _tab = _Tab.library;
          _list = null;
        }
        final wm = context.read<WindowManager>();
        final cur = player.current;
        final title = cur == null ? 'Media Player' : '${cur.title} - Media Player';
        if (widget.w.title != title) scheduleMicrotask(() => wm.setTitle(widget.w.id, title));
        return Listener(
          onPointerDown: (e) {
            final m = e.kind == PointerDeviceKind.mouse;
            if (m != _mouse) setState(() => _mouse = m);
          },
          child: Container(
          color: const Color(0xFF1D2B53),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _sidebar(),
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(0, 6, 6, 0),
                    decoration: BoxDecoration(
                      color: _tab == _Tab.nowPlaying ? Colors.black : Colors.white,
                      border: Border.all(color: const Color(0xFF6C86C9)),
                    ),
                    child: switch (_tab) {
                      _Tab.nowPlaying => _nowPlaying(),
                      _Tab.library => _library(),
                      _Tab.videos => _videos(),
                      _Tab.mixes => _mix == null ? _mixesView() : _mixView(_mix!),
                      _Tab.playlist => _playlistView(_list!),
                    },
                  ),
                ),
              ]),
            ),
            _transport(),
          ]),
        ),
        );
      },
    );
  }

  // ------------------------------------------------------------ sidebar

  Widget _sidebar() {
    Widget item(_Tab t, IconData icon, String label) {
      final on = _tab == t;
      return GestureDetector(
        onTap: () => setState(() {
          _tab = t;
          _list = null;
          _mix = null;
        }),
        child: Container(
          margin: const EdgeInsets.fromLTRB(6, 6, 6, 0),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            gradient: on ? const LinearGradient(colors: [Color(0xFF4F7BE0), Color(0xFF2B55B8)]) : null,
          ),
          child: Row(children: [
            Icon(icon, size: 20, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 13))),
          ]),
        ),
      );
    }

    return Container(
      width: 150,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF3A5CB0), Color(0xFF1D2B53)]),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        item(_Tab.nowPlaying, Icons.graphic_eq, 'Now Playing'),
        item(_Tab.library, Icons.library_music, 'Music Library'),
        item(_Tab.videos, Icons.video_library, 'Videos'),
        item(_Tab.mixes, Icons.auto_awesome, 'Auto Mixes'),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 14, 6, 2),
          child: Row(children: [
            const Expanded(
              child: Text('Playlists', style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
            ),
            Tooltip(
              message: 'New Playlist',
              child: GestureDetector(
                onTap: () => _newPlaylist(const []),
                child: const Icon(Icons.add_box_outlined, size: 18, color: Colors.white),
              ),
            ),
          ]),
        ),
        Expanded(
          child: lists.lists.isEmpty
              ? GestureDetector(
                  onTap: () => _newPlaylist(const []),
                  child: const Padding(
                    padding: EdgeInsets.fromLTRB(12, 4, 8, 4),
                    child: Text('Click + to make one, or right-click songs and pick Add to Playlist.',
                        style: TextStyle(color: Colors.white54, fontSize: 11)),
                  ),
                )
              : ListView(padding: EdgeInsets.zero, children: [for (final p in lists.lists) _sidebarList(p)]),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
              lib.scanning
                  ? 'Reading library...'
                  : '${lib.songs.length} songs\n${lib.videos.length} videos',
              style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ),
      ]),
    );
  }

  Widget _sidebarList(Playlist p) {
    final on = _tab == _Tab.playlist && _list == p;
    return DragTarget<_SongDrag>(
      onAcceptWithDetails: (d) => _addTo(p, d.data.items),
      builder: (c, cand, rej) => GestureDetector(
        onTap: () => setState(() {
          _tab = _Tab.playlist;
          _list = p;
          _selected = null;
        }),
        onDoubleTap: () => _playList(p, shuffled: false),
        onSecondaryTapUp: (d) => _listMenu(p, d.globalPosition),
        onLongPressStart: (d) => _listMenu(p, d.globalPosition),
        child: Container(
          margin: const EdgeInsets.fromLTRB(6, 2, 6, 0),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            gradient: on ? const LinearGradient(colors: [Color(0xFF4F7BE0), Color(0xFF2B55B8)]) : null,
            border: cand.isNotEmpty ? Border.all(color: Colors.white) : null,
          ),
          child: Row(children: [
            const Icon(Icons.queue_music, size: 18, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(
              child: Text(p.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          ]),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ playlists

  void _toast(String text) {
    try {
      context.read<Desk>().toasts.show(DeskToast(title: 'Media Player', text: text, icon: Icons.playlist_add));
    } catch (_) {}
  }

  String _songs(int n) => n == 1 ? '1 song' : '$n songs';

  void _addTo(Playlist p, List<MediaItem> items) {
    final n = lists.add(p, items);
    if (n == 0) {
      _toast(items.length == 1 ? "It's already in '${p.name}'." : "They're already in '${p.name}'.");
    } else {
      _toast("Added ${_songs(n)} to '${p.name}'.");
    }
  }

  void _newPlaylist(List<MediaItem> items, {String? name}) {
    promptBox(context.read<WindowManager>(),
        title: 'New Playlist',
        text: items.isEmpty ? 'Name the new playlist:' : 'Name the new playlist (${_songs(items.length)}):',
        initial: name ?? lists.freeName(),
        okLabel: 'Create',
        icon: Icons.queue_music, onOk: (v) {
      final p = lists.create(v, items);
      if (!mounted) return;
      setState(() {
        _tab = _Tab.playlist;
        _list = p;
        _selected = null;
      });
    });
  }

  /// Songs in [p], using the library's copies where it has them.
  List<MediaItem> _itemsOf(Playlist p) {
    if (!lib.scanned) return p.items;
    final byKey = {for (final m in lib.songs) m.key: m, for (final m in lib.videos) m.key: m};
    return PlaylistOps.refresh(p.items, byKey);
  }

  void _playList(Playlist p, {required bool shuffled, int start = 0}) {
    final items = _itemsOf(p);
    if (items.isEmpty) return;
    unawaited(player.play(items, start, shuffled: shuffled));
  }

  Future<void> _listMenu(Playlist p, Offset at) async {
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
      items: [
        PopupMenuItem(value: 'play', enabled: p.items.isNotEmpty, child: const Text('Play', style: Xp.textBold)),
        PopupMenuItem(value: 'shuffle', enabled: p.items.isNotEmpty, child: const Text('Shuffle', style: Xp.text)),
        PopupMenuItem(value: 'queue', enabled: p.items.isNotEmpty, child: const Text('Add to Now Playing', style: Xp.text)),
        const PopupMenuDivider(height: 7),
        const PopupMenuItem(value: 'rename', child: Text('Rename...', style: Xp.text)),
        const PopupMenuItem(value: 'delete', child: Text('Delete', style: Xp.text)),
      ],
    );
    switch (v) {
      case 'play':
        _playList(p, shuffled: false);
      case 'shuffle':
        _playList(p, shuffled: true);
      case 'queue':
        for (final m in _itemsOf(p)) {
          player.addToQueue(m);
        }
      case 'rename':
        _renameList(p);
      case 'delete':
        _deleteList(p);
    }
  }

  void _renameList(Playlist p) => promptBox(context.read<WindowManager>(),
      title: 'Rename Playlist',
      text: 'New name for this playlist:',
      initial: p.name,
      icon: Icons.queue_music,
      onOk: (v) => lists.rename(p, v));

  void _deleteList(Playlist p) => confirmBox(context.read<WindowManager>(),
      title: 'Delete Playlist',
      text: "Delete the playlist '${p.name}'? The songs themselves stay on the tablet.",
      icon: Icons.delete_outline,
      onYes: () => lists.delete(p));

  /// "Add to Playlist" entries for a song menu; values are 'pl:<n>' or 'pl:new'.
  List<PopupMenuEntry<String>> _addMenuItems() => [
        const PopupMenuDivider(height: 7),
        for (var i = 0; i < lists.lists.length; i++)
          PopupMenuItem(
            value: 'pl:$i',
            child: Text("Add to '${lists.lists[i].name}'",
                style: Xp.text, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        const PopupMenuItem(value: 'pl:new', child: Text('Add to New Playlist...', style: Xp.text)),
      ];

  /// Handles a value from [_addMenuItems]. True if it was one.
  bool _handleAdd(String? v, List<MediaItem> items) {
    if (v == null || !v.startsWith('pl:')) return false;
    if (v == 'pl:new') {
      _newPlaylist(items);
    } else {
      final i = int.tryParse(v.substring(3)) ?? -1;
      if (i >= 0 && i < lists.lists.length) _addTo(lists.lists[i], items);
    }
    return true;
  }

  Future<void> _addMenuAt(Offset at, List<MediaItem> items) async {
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
      items: _addMenuItems().skip(1).toList(),
    );
    _handleAdd(v, items);
  }

  Widget _playlistView(Playlist p) {
    final items = _itemsOf(p);
    final cur = player.current?.key;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        color: const Color(0xFFF4F6FB),
        child: Row(children: [
          const Icon(Icons.queue_music, size: 36, color: Color(0xFF2B55B8)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, style: Xp.textBold.copyWith(fontSize: 14), overflow: TextOverflow.ellipsis),
              Text(
                  items.isEmpty
                      ? 'Empty'
                      : '${_songs(items.length)}, ${LibraryOps.formatTime(items.fold(0, (t, m) => t + m.durationMs))}',
                  style: Xp.textGrey.copyWith(fontSize: 11)),
            ]),
          ),
          XpButton(label: 'Play All', onPressed: items.isEmpty ? null : () => _playList(p, shuffled: false)),
          const SizedBox(width: 4),
          XpButton(label: 'Shuffle', onPressed: items.isEmpty ? null : () => _playList(p, shuffled: true)),
          const SizedBox(width: 4),
          XpButton(label: 'Rename', onPressed: () => _renameList(p)),
          const SizedBox(width: 4),
          XpButton(label: 'Delete', onPressed: () => _deleteList(p)),
        ]),
      ),
      Expanded(
        child: items.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                      'This playlist is empty.\nIn the Music Library, right-click a song (or hold it) and pick '
                      "Add to this playlist, or drag songs onto the playlist's name on the left.",
                      textAlign: TextAlign.center,
                      style: Xp.textGrey),
                ),
              )
            : ReorderableListView.builder(
                buildDefaultDragHandles: false,
                itemCount: items.length,
                onReorder: (from, to) => lists.move(p, from, to > from ? to - 1 : to),
                itemBuilder: (c, i) {
                  final m = items[i];
                  final sel = _selected == 'pl:$i';
                  final playing = cur == m.key;
                  final style = Xp.text.copyWith(
                      fontSize: 12,
                      color: sel ? Colors.white : (playing ? const Color(0xFF0C32A4) : null),
                      fontWeight: playing ? FontWeight.bold : null);
                  return GestureDetector(
                    key: ValueKey(m.key),
                    onTap: () => setState(() => _selected = 'pl:$i'),
                    onDoubleTap: () => _playList(p, shuffled: false, start: i),
                    onSecondaryTapUp: (d) => _playlistSongMenu(p, items, i, d.globalPosition),
                    onLongPressStart: (d) => _playlistSongMenu(p, items, i, d.globalPosition),
                    child: Container(
                      height: 26,
                      color: sel ? Xp.selection : (i.isOdd ? const Color(0xFFF7F7F7) : Colors.white),
                      child: Row(children: [
                        ReorderableDragStartListener(
                          index: i,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.grab,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              child: Icon(Icons.drag_indicator, size: 16, color: sel ? Colors.white70 : Colors.black38),
                            ),
                          ),
                        ),
                        SizedBox(width: 26, child: Text('${i + 1}', style: style)),
                        Expanded(
                            flex: 4,
                            child: Text(m.title, style: style, maxLines: 1, overflow: TextOverflow.ellipsis)),
                        Expanded(
                            flex: 3,
                            child: Text(m.artist, style: style, maxLines: 1, overflow: TextOverflow.ellipsis)),
                        SizedBox(
                          width: 50,
                          child: Text(m.durationMs > 0 ? LibraryOps.formatTime(m.durationMs) : '', style: style),
                        ),
                      ]),
                    ),
                  );
                },
              ),
      ),
    ]);
  }

  Future<void> _playlistSongMenu(Playlist p, List<MediaItem> items, int i, Offset at) async {
    setState(() => _selected = 'pl:$i');
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
      items: [
        const PopupMenuItem(value: 'play', child: Text('Play', style: Xp.textBold)),
        const PopupMenuItem(value: 'next', child: Text('Play Next', style: Xp.text)),
        const PopupMenuItem(value: 'queue', child: Text('Add to Now Playing', style: Xp.text)),
        const PopupMenuDivider(height: 7),
        PopupMenuItem(value: 'up', enabled: i > 0, child: const Text('Move Up', style: Xp.text)),
        PopupMenuItem(value: 'down', enabled: i < items.length - 1, child: const Text('Move Down', style: Xp.text)),
        const PopupMenuItem(value: 'remove', child: Text('Remove from Playlist', style: Xp.text)),
      ],
    );
    switch (v) {
      case 'play':
        _playList(p, shuffled: false, start: i);
      case 'next':
        player.playNext(items[i]);
      case 'queue':
        player.addToQueue(items[i]);
      case 'up':
        lists.move(p, i, i - 1);
        setState(() => _selected = 'pl:${i - 1}');
      case 'down':
        lists.move(p, i, i + 1);
        setState(() => _selected = 'pl:${i + 1}');
      case 'remove':
        lists.removeAt(p, i);
        setState(() => _selected = null);
    }
  }

  Widget _visMenuButton() => Tooltip(
        message: 'Visualization',
        child: GestureDetector(
          onTapDown: (d) async {
            final v = await showMenu<VisStyle>(
              context: context,
              position: RelativeRect.fromLTRB(d.globalPosition.dx, d.globalPosition.dy, d.globalPosition.dx + 1,
                  d.globalPosition.dy + 1),
              items: [
                for (final s in VisStyle.values)
                  CheckedPopupMenuItem(value: s, checked: s == _vis, child: Text(s.label, style: Xp.text)),
              ],
            );
            if (v != null) {
              VisSettings.set(v);
              setState(() => _vis = v);
            }
          },
          child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.equalizer, size: 18, color: Colors.white70)),
        ),
      );

  /// Swaps the big player for the small always-on-top one.
  void _toMini() {
    final desk = context.read<Desk>();
    context.read<WindowManager>().close(widget.w.id);
    desk.openMiniPlayer();
  }

  // ------------------------------------------------------------ now playing

  Widget _nowPlaying() {
    final cur = player.current;
    final c = player.controller;
    Widget stage;
    if (cur == null) {
      stage = const Center(child: Text('Nothing playing. Pick something from the Music Library.', style: TextStyle(color: Colors.white70)));
    } else if (cur.video && c != null && c.value.isInitialized) {
      stage = GestureDetector(
        onTap: player.toggle,
        onDoubleTap: () => player.setFullScreen(true),
        child: Center(child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c))),
      );
    } else {
      stage = Stack(children: [
        if (_vis != VisStyle.off) Positioned.fill(child: Visualizer(player: player, style: _vis)),
        Positioned(
          right: 6,
          top: 6,
          child: _visMenuButton(),
        ),
        Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Opacity(opacity: _vis == VisStyle.off ? 1 : 0.9, child: MediaArt(item: cur, size: _vis == VisStyle.off ? 220 : 160)),
          const SizedBox(height: 12),
          Text(cur.title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          if (cur.subtitle.isNotEmpty) Text(cur.subtitle, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          if (player.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(player.error!, style: const TextStyle(color: Color(0xFFFF8A80))),
            ),
        ]),
        ),
      ]);
    }
    final showQueue = player.queue.length > 1 && !(cur?.video ?? false);
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(child: stage),
      if (showQueue)
        Container(
          width: 250,
          color: const Color(0xFF101830),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
              child: Row(children: [
                const Expanded(
                  child: Text('Up next', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
                Tooltip(
                  message: 'Save this list as a playlist',
                  child: GestureDetector(
                    onTap: () => _newPlaylist(player.queue, name: lists.freeName('Now Playing')),
                    child: const Row(children: [
                      Icon(Icons.playlist_add, size: 16, color: Colors.white70),
                      SizedBox(width: 2),
                      Text('Save', style: TextStyle(color: Colors.white70, fontSize: 11)),
                    ]),
                  ),
                ),
              ]),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: player.queue.length,
                itemBuilder: (c, i) {
                  final m = player.queue[i];
                  final now = i == player.index;
                  return GestureDetector(
                    onDoubleTap: () => player.jump(i),
                    onSecondaryTapUp: (d) => _queueMenu(i, d.globalPosition),
                    onLongPressStart: (d) => _queueMenu(i, d.globalPosition),
                    child: Container(
                      color: now ? const Color(0xFF2B55B8) : null,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Row(children: [
                        SizedBox(
                          width: 18,
                          child: now ? const Icon(Icons.play_arrow, size: 14, color: Color(0xFF8FD14F)) : null,
                        ),
                        Expanded(
                          child: Text(m.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: now ? Colors.white : Colors.white70, fontSize: 12)),
                        ),
                        Text(m.durationMs > 0 ? LibraryOps.formatTime(m.durationMs) : '',
                            style: const TextStyle(color: Colors.white54, fontSize: 11)),
                      ]),
                    ),
                  );
                },
              ),
            ),
          ]),
        ),
    ]);
  }

  Future<void> _queueMenu(int i, Offset at) async {
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
      items: [
        const PopupMenuItem(value: 'play', child: Text('Play', style: Xp.textBold)),
        const PopupMenuItem(value: 'remove', child: Text('Remove from list', style: Xp.text)),
        ..._addMenuItems(),
      ],
    );
    if (i < player.queue.length && _handleAdd(v, [player.queue[i]])) return;
    if (v == 'play') unawaited(player.jump(i));
    if (v == 'remove') player.removeAt(i);
  }

  // ------------------------------------------------------------ library

  Widget _permissionNote() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('The player needs permission to see your music and videos.', style: Xp.text),
          const SizedBox(height: 8),
          XpButton(
              label: 'Allow...',
              isDefault: true,
              onPressed: () async {
                await lib.askPermission();
                // The answer comes back when Android's box closes.
                Timer(const Duration(seconds: 3), () => lib.scan());
              }),
        ]),
      );

  Widget _toolbar({required bool songs}) {
    return Container(
      padding: const EdgeInsets.all(6),
      color: const Color(0xFFECE9D8),
      child: Row(children: [
        if (songs) ...[
          for (final g in GroupBy.values)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: GestureDetector(
                onTap: () => setState(() {
                  _group = g;
                  _bucket = null;
                }),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _group == g ? const Color(0xFFC1D2EE) : null,
                    border: Border.all(color: _group == g ? Xp.selection : Colors.transparent),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(g.label, style: Xp.text.copyWith(fontSize: 12)),
                ),
              ),
            ),
          const Spacer(),
          if (_group == GroupBy.songs || _bucket != null) ...[
            const Text('Sort:', style: Xp.text),
            const SizedBox(width: 4),
            PopupMenuButton<SortBy>(
              tooltip: 'Sort by',
              onSelected: (s) => setState(() => _sort = s),
              itemBuilder: (_) => [
                for (final s in SortBy.values) PopupMenuItem(value: s, child: Text(s.label, style: Xp.text)),
              ],
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Xp.fieldBorder)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(_sort.label, style: Xp.text.copyWith(fontSize: 12)),
                  const Icon(Icons.arrow_drop_down, size: 16),
                ]),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ] else
          const Spacer(),
        SizedBox(
          width: 170,
          child: XpField(controller: _search, hint: 'Search', onChanged: (_) => setState(() {})),
        ),
        const SizedBox(width: 4),
        Tooltip(
          message: 'Read the library again',
          child: GestureDetector(onTap: lib.scan, child: const Icon(Icons.refresh, size: 18, color: Color(0xFF1E3E9B))),
        ),
      ]),
    );
  }

  Widget _library() {
    if (lib.scanned && !lib.permission) return _permissionNote();
    final body = (_group == GroupBy.songs || _bucket != null || _search.text.trim().isNotEmpty)
        ? _songList(_visibleSongs())
        : _buckets(LibraryOps.group(lib.songs, _group));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _toolbar(songs: true),
      if (_bucket != null)
        Container(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          color: const Color(0xFFF4F6FB),
          child: Row(children: [
            GestureDetector(
              onTap: () => setState(() => _bucket = null),
              child: Row(children: [
                const Icon(Icons.arrow_back, size: 16, color: Color(0xFF0C32A4)),
                const SizedBox(width: 4),
                Text(_group.label, style: Xp.text.copyWith(color: const Color(0xFF0C32A4))),
              ]),
            ),
            const SizedBox(width: 12),
            MediaArt(item: _bucket!.cover, size: 36),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_bucket!.name, style: Xp.textBold, overflow: TextOverflow.ellipsis),
                Text(_bucket!.sub, style: Xp.textGrey.copyWith(fontSize: 11), overflow: TextOverflow.ellipsis),
              ]),
            ),
            XpButton(label: 'Play All', onPressed: () => player.play(_bucket!.items, 0, shuffled: false)),
            const SizedBox(width: 4),
            XpButton(label: 'Shuffle', onPressed: () => player.play(_bucket!.items, 0, shuffled: true)),
            const SizedBox(width: 4),
            Builder(
              builder: (bc) => XpButton(
                label: 'Add to Playlist',
                minWidth: 100,
                onPressed: () {
                  final box = bc.findRenderObject() as RenderBox;
                  _addMenuAt(box.localToGlobal(Offset(0, box.size.height)), _bucket!.items);
                },
              ),
            ),
          ]),
        ),
      Expanded(child: body),
    ]);
  }

  Widget _buckets(List<Bucket> list) {
    if (lib.scanning && list.isEmpty) return const Center(child: Text('Reading library...', style: Xp.textGrey));
    if (list.isEmpty) return const Center(child: Text('No music found.', style: Xp.textGrey));
    return LayoutBuilder(builder: (c, box) {
      final cols = math.max(1, (box.maxWidth / 150).floor());
      return GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: cols, mainAxisExtent: 170),
        itemCount: list.length,
        itemBuilder: (c, i) {
          final b = list[i];
          return GestureDetector(
            onTap: () => setState(() {
              _bucket = b;
              _search.clear();
            }),
            onDoubleTap: () => player.play(b.items, 0),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Column(children: [
                MediaArt(item: b.cover, size: 110),
                const SizedBox(height: 4),
                Text(b.name, style: Xp.textBold.copyWith(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(b.sub, style: Xp.textGrey.copyWith(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
          );
        },
      );
    });
  }

  Widget _songList(List<MediaItem> list) {
    if (lib.scanning && list.isEmpty) return const Center(child: Text('Reading library...', style: Xp.textGrey));
    if (list.isEmpty) {
      return Center(
          child: Text(lib.songs.isEmpty ? 'No music found on this device.' : 'Nothing matches.', style: Xp.textGrey));
    }
    Widget head(String t, {int flex = 3}) => Expanded(
          flex: flex,
          child: Container(
            height: 22,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.centerLeft,
            decoration: const BoxDecoration(
              color: Color(0xFFEBEADB),
              border: Border(right: BorderSide(color: Color(0xFFC7C5B2)), bottom: BorderSide(color: Color(0xFFC7C5B2))),
            ),
            child: Text(t, style: Xp.text.copyWith(fontSize: 12)),
          ),
        );
    final cur = player.current?.key;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [head('Title', flex: 4), head('Artist'), head('Album'), head('Length', flex: 1)]),
      Expanded(
        child: ListView.builder(
          itemExtent: 24,
          itemCount: list.length,
          itemBuilder: (c, i) {
            final m = list[i];
            final sel = _selected == m.key;
            final playing = cur == m.key;
            final style = Xp.text.copyWith(
                fontSize: 12,
                color: sel ? Colors.white : (playing ? const Color(0xFF0C32A4) : null),
                fontWeight: playing ? FontWeight.bold : null);
            Widget cell(String t, {int flex = 3}) => Expanded(
                  flex: flex,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(t, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                );
            return Draggable<_SongDrag>(
              data: _SongDrag([m]),
              maxSimultaneousDrags: _mouse ? 1 : 0,
              dragAnchorStrategy: pointerDragAnchorStrategy,
              onDragStarted: () => setState(() => _selected = m.key),
              feedback: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  color: const Color(0xCC316AC5),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.music_note, size: 14, color: Colors.white),
                    const SizedBox(width: 4),
                    Text(m.title, style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ]),
                ),
              ),
              child: GestureDetector(
              onTap: () => setState(() => _selected = m.key),
              onDoubleTap: () => player.play(list, i),
              onSecondaryTapUp: (d) => _songMenu(list, i, d.globalPosition),
              onLongPressStart: (d) => _songMenu(list, i, d.globalPosition),
              child: Container(
                color: sel ? Xp.selection : (i.isOdd ? const Color(0xFFF7F7F7) : Colors.white),
                child: Row(children: [
                  cell(m.title, flex: 4),
                  cell(m.artist),
                  cell(m.video ? '' : m.album),
                  cell(m.durationMs > 0 ? LibraryOps.formatTime(m.durationMs) : '', flex: 1),
                ]),
              ),
            ),
            );
          },
        ),
      ),
    ]);
  }

  Future<void> _songMenu(List<MediaItem> list, int i, Offset at) async {
    final m = list[i];
    setState(() => _selected = m.key);
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
      items: [
        const PopupMenuItem(value: 'play', child: Text('Play', style: Xp.textBold)),
        const PopupMenuItem(value: 'next', child: Text('Play Next', style: Xp.text)),
        const PopupMenuItem(value: 'queue', child: Text('Add to Now Playing', style: Xp.text)),
        const PopupMenuItem(value: 'like', child: Text('Songs Like This', style: Xp.text)),
        ..._addMenuItems(),
      ],
    );
    if (_handleAdd(v, [m])) return;
    switch (v) {
      case 'play':
        unawaited(player.play(list, i));
      case 'next':
        player.playNext(m);
      case 'queue':
        player.addToQueue(m);
      case 'like':
        _songsLike(m);
    }
  }

  // ------------------------------------------------------------ Auto Mixes

  void _songsLike(MediaItem m) => setState(() {
        _tab = _Tab.mixes;
        _mix = auto.soundsLike(lib.songs, m);
        _selected = null;
      });

  void _playMix(Mix m, {required bool shuffled, int start = 0}) {
    if (m.items.isEmpty) return;
    unawaited(player.play(m.items, start, shuffled: shuffled));
  }

  Widget _analysisBar() {
    final n = auto.features.length;
    final String text;
    if (auto.analysing) {
      text = 'Listening to your songs to work out their mood: ${auto.analysisDone} of ${auto.analysisTotal}. '
          'Mood mixes get better as this goes.';
    } else if (auto.paused) {
      text = 'Listening paused. Mood mixes use the $n songs heard so far.';
    } else {
      text = n == 0 ? 'Mood mixes appear once your songs have been listened to.' : 'Moods worked out for $n songs.';
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
      color: const Color(0xFFF4F6FB),
      child: Row(children: [
        Icon(auto.analysing ? Icons.hearing : Icons.auto_awesome, size: 28, color: const Color(0xFF2B55B8)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Auto Mixes', style: Xp.textBold.copyWith(fontSize: 14)),
            Text(text, style: Xp.textGrey.copyWith(fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
            if (auto.analysing && auto.analysisTotal > 0)
              Padding(
                padding: const EdgeInsets.only(top: 3, right: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: auto.analysisDone / auto.analysisTotal,
                    minHeight: 6,
                    backgroundColor: const Color(0xFFDDE3F0),
                    color: const Color(0xFF3FA83F),
                  ),
                ),
              ),
          ]),
        ),
        if (auto.analysing)
          XpButton(label: 'Pause', onPressed: auto.pause)
        else if (auto.paused)
          XpButton(label: 'Resume', onPressed: () => unawaited(auto.analyse(lib.songs))),
        const SizedBox(width: 4),
        XpButton(label: 'New Mixes', onPressed: auto.refresh),
      ]),
    );
  }

  Widget _mixesView() {
    if (lib.scanned && !lib.permission) return _permissionNote();
    final mixes = lib.songs.isEmpty ? const <Mix>[] : auto.mixes(lib.songs);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _analysisBar(),
      Expanded(
        child: mixes.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                      lib.scanning || !lib.scanned
                          ? 'Reading library...'
                          : 'No mixes yet. Play some music and they will start to appear.',
                      textAlign: TextAlign.center,
                      style: Xp.textGrey),
                ),
              )
            : LayoutBuilder(builder: (c, box) {
                final cols = math.max(1, (box.maxWidth / 230).floor());
                return GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: cols, mainAxisExtent: 92),
                  itemCount: mixes.length,
                  itemBuilder: (c, i) => _mixCard(mixes[i]),
                );
              }),
      ),
    ]);
  }

  Widget _mixCard(Mix m) {
    Future<void> menu(Offset at) async {
      final v = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
        items: [
          const PopupMenuItem(value: 'open', child: Text('Open', style: Xp.textBold)),
          const PopupMenuItem(value: 'play', child: Text('Play', style: Xp.text)),
          const PopupMenuItem(value: 'shuffle', child: Text('Shuffle', style: Xp.text)),
          const PopupMenuItem(value: 'save', child: Text('Save as Playlist...', style: Xp.text)),
        ],
      );
      switch (v) {
        case 'open':
          setState(() => _mix = m);
        case 'play':
          _playMix(m, shuffled: false);
        case 'shuffle':
          _playMix(m, shuffled: true);
        case 'save':
          _newPlaylist(m.items, name: lists.freeName(m.title));
      }
    }

    return GestureDetector(
      onTap: () => setState(() {
        _mix = m;
        _selected = null;
      }),
      onDoubleTap: () => _playMix(m, shuffled: false),
      onSecondaryTapUp: (d) => menu(d.globalPosition),
      onLongPressStart: (d) => menu(d.globalPosition),
      child: Container(
        margin: const EdgeInsets.all(5),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF9DB3E6)),
          gradient: const LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFFFFFFF), Color(0xFFE3EAF8)]),
        ),
        child: Row(children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              gradient: const LinearGradient(colors: [Color(0xFF4F7BE0), Color(0xFF2B55B8)]),
            ),
            child: Icon(m.icon, color: Colors.white, size: 30),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(m.title, style: Xp.textBold.copyWith(fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(m.subtitle, style: Xp.textGrey.copyWith(fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
              Text(_songs(m.items.length), style: Xp.textGrey.copyWith(fontSize: 11)),
            ]),
          ),
          Tooltip(
            message: 'Play',
            child: GestureDetector(
              onTap: () => _playMix(m, shuffled: false),
              child: const Icon(Icons.play_circle_fill, size: 30, color: Color(0xFF3FA83F)),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _mixView(Mix m) {
    final cur = player.current?.key;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.fromLTRB(6, 8, 8, 8),
        color: const Color(0xFFF4F6FB),
        child: Row(children: [
          Tooltip(
            message: 'Back to Auto Mixes',
            child: GestureDetector(
              onTap: () => setState(() => _mix = null),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.arrow_back, size: 20, color: Color(0xFF2B55B8)),
              ),
            ),
          ),
          Icon(m.icon, size: 36, color: const Color(0xFF2B55B8)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m.title, style: Xp.textBold.copyWith(fontSize: 14), overflow: TextOverflow.ellipsis),
              Text(
                  '${m.subtitle} - ${_songs(m.items.length)}, '
                  '${LibraryOps.formatTime(m.items.fold(0, (t, x) => t + x.durationMs))}',
                  style: Xp.textGrey.copyWith(fontSize: 11),
                  overflow: TextOverflow.ellipsis),
            ]),
          ),
          XpButton(label: 'Play All', onPressed: m.items.isEmpty ? null : () => _playMix(m, shuffled: false)),
          const SizedBox(width: 4),
          XpButton(label: 'Shuffle', onPressed: m.items.isEmpty ? null : () => _playMix(m, shuffled: true)),
          const SizedBox(width: 4),
          XpButton(
              label: 'Save as Playlist',
              onPressed: m.items.isEmpty ? null : () => _newPlaylist(m.items, name: lists.freeName(m.title))),
        ]),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: m.items.length,
          itemBuilder: (c, i) {
            final t = m.items[i];
            final sel = _selected == 'mix:$i';
            final playing = cur == t.key;
            final style = Xp.text.copyWith(
                fontSize: 12,
                color: sel ? Colors.white : (playing ? const Color(0xFF0C32A4) : null),
                fontWeight: playing ? FontWeight.bold : null);
            final mood = auto.moodOf(t);
            return GestureDetector(
              onTap: () => setState(() => _selected = 'mix:$i'),
              onDoubleTap: () => _playMix(m, shuffled: false, start: i),
              onSecondaryTapUp: (d) => _mixSongMenu(m, i, d.globalPosition),
              onLongPressStart: (d) => _mixSongMenu(m, i, d.globalPosition),
              child: Container(
                height: 26,
                padding: const EdgeInsets.only(left: 8),
                color: sel ? Xp.selection : (i.isOdd ? const Color(0xFFF7F7F7) : Colors.white),
                child: Row(children: [
                  SizedBox(width: 28, child: Text('${i + 1}', style: style)),
                  Expanded(flex: 4, child: Text(t.title, style: style, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  Expanded(flex: 3, child: Text(t.artist, style: style, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  SizedBox(
                    width: 100,
                    child: mood == null
                        ? const SizedBox()
                        : Row(children: [
                            Icon(mood.icon, size: 13, color: sel ? Colors.white : const Color(0xFF2B55B8)),
                            const SizedBox(width: 3),
                            Flexible(child: Text(mood.label, style: style, overflow: TextOverflow.ellipsis)),
                          ]),
                  ),
                  SizedBox(
                    width: 50,
                    child: Text(t.durationMs > 0 ? LibraryOps.formatTime(t.durationMs) : '', style: style),
                  ),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }

  Future<void> _mixSongMenu(Mix m, int i, Offset at) async {
    setState(() => _selected = 'mix:$i');
    final t = m.items[i];
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
      items: [
        const PopupMenuItem(value: 'play', child: Text('Play', style: Xp.textBold)),
        const PopupMenuItem(value: 'next', child: Text('Play Next', style: Xp.text)),
        const PopupMenuItem(value: 'queue', child: Text('Add to Now Playing', style: Xp.text)),
        const PopupMenuItem(value: 'like', child: Text('Songs Like This', style: Xp.text)),
        ..._addMenuItems(),
      ],
    );
    if (_handleAdd(v, [t])) return;
    switch (v) {
      case 'play':
        _playMix(m, shuffled: false, start: i);
      case 'next':
        player.playNext(t);
      case 'queue':
        player.addToQueue(t);
      case 'like':
        _songsLike(t);
    }
  }

  // ------------------------------------------------------------ videos

  Widget _videos() {
    if (lib.scanned && !lib.permission) return _permissionNote();
    final list = LibraryOps.search(lib.videos, _search.text);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _toolbar(songs: false),
      Expanded(
        child: list.isEmpty
            ? Center(child: Text(lib.scanning ? 'Reading library...' : 'No videos found.', style: Xp.textGrey))
            : LayoutBuilder(builder: (c, box) {
                final cols = math.max(1, (box.maxWidth / 190).floor());
                return GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: cols, mainAxisExtent: 150),
                  itemCount: list.length,
                  itemBuilder: (c, i) {
                    final m = list[i];
                    return GestureDetector(
                      onDoubleTap: () {
                        unawaited(player.play(list, i, shuffled: false));
                        setState(() => _tab = _Tab.nowPlaying);
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Column(children: [
                          SizedBox(
                            width: 170,
                            height: 100,
                            child: Stack(fit: StackFit.expand, children: [
                              FittedBox(fit: BoxFit.cover, clipBehavior: Clip.hardEdge, child: MediaArt(item: m, size: 170)),
                              Positioned(
                                right: 4,
                                bottom: 4,
                                child: Container(
                                  color: const Color(0xAA000000),
                                  padding: const EdgeInsets.symmetric(horizontal: 4),
                                  child: Text(LibraryOps.formatTime(m.durationMs),
                                      style: const TextStyle(color: Colors.white, fontSize: 11)),
                                ),
                              ),
                            ]),
                          ),
                          const SizedBox(height: 4),
                          Text(m.title, style: Xp.text.copyWith(fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
                        ]),
                      ),
                    );
                  },
                );
              }),
      ),
    ]);
  }

  // ------------------------------------------------------------ transport

  Widget _transport() {
    final p = player;
    final cur = p.current;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SeekBar(player: p, light: true),
        Row(children: [
          RoundButton(icon: Icons.shuffle, tip: 'Shuffle', on: p.shuffle, onTap: () => p.setShuffle(!p.shuffle)),
          const SizedBox(width: 4),
          RoundButton(
              icon: p.repeat == Repeat.one ? Icons.repeat_one : Icons.repeat,
              tip: switch (p.repeat) {
                Repeat.off => 'Repeat: off',
                Repeat.all => 'Repeat: all',
                Repeat.one => 'Repeat: this song',
              },
              on: p.repeat != Repeat.off,
              onTap: p.cycleRepeat),
          const SizedBox(width: 14),
          RoundButton(icon: Icons.stop, tip: 'Stop', onTap: cur == null ? null : p.stop),
          const SizedBox(width: 4),
          RoundButton(icon: Icons.skip_previous, tip: 'Previous', onTap: cur == null ? null : p.previous),
          const SizedBox(width: 4),
          RoundButton(
              icon: p.playing ? Icons.pause : Icons.play_arrow,
              tip: p.playing ? 'Pause' : 'Play',
              size: 40,
              onTap: cur == null
                  ? (lib.songs.isEmpty ? null : () => p.play(lib.songs, 0))
                  : p.toggle),
          const SizedBox(width: 4),
          RoundButton(icon: Icons.skip_next, tip: 'Next', onTap: cur == null ? null : p.next),
          const SizedBox(width: 14),
          Expanded(
            child: Text(cur == null ? '' : '${cur.title}${cur.subtitle.isEmpty ? '' : '  -  ${cur.subtitle}'}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          if (p.isVideo) ...[
            RoundButton(icon: Icons.fullscreen, tip: 'Full Screen (Ctrl+F)', onTap: () => p.setFullScreen(true)),
            const SizedBox(width: 6),
          ],
          RoundButton(icon: Icons.picture_in_picture_alt, tip: 'Switch to Mini Player (Ctrl+2)', onTap: _toMini),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: p.toggleMute,
            child: Icon(p.muted || p.volume == 0 ? Icons.volume_off : Icons.volume_up, size: 18, color: Colors.white),
          ),
          SizedBox(
            width: 110,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 8),
                activeTrackColor: const Color(0xFF8FD14F),
                thumbColor: Colors.white,
              ),
              child: Slider(value: p.muted ? 0 : p.volume, onChanged: p.setVolume),
            ),
          ),
        ]),
      ]),
    );
  }
}

/// Play, pause, skip and a seek bar on the lock screen and in the
/// notification shade (also headphone and Bluetooth buttons), through an
/// Android media session (DeskPlayback.kt). The notification also keeps music
/// playing while the desktop is in the background.
class _LockScreenControls {
  _LockScreenControls(this.player) {
    _ch.setMethodCallHandler(_onCall);
    player.addListener(_changed);
  }

  final DeskPlayer player;
  static const _ch = MethodChannel('desk/playback');
  String _last = '';
  bool _shown = false;
  bool _dismissed = false;
  bool _asked = false;

  void _changed() {
    final m = player.current;
    final playing = player.playing;
    if (playing) _dismissed = false;
    if (m == null || _dismissed) {
      if (_shown) {
        _shown = false;
        _last = '';
        unawaited(_invoke('stop'));
      }
      return;
    }
    final dur = player.duration.inMilliseconds;
    final sig = '${m.key}|$playing|$dur|${player.seekSerial}|${player.index}';
    if (sig == _last) return;
    _last = sig;
    _shown = true;
    if (!_asked && playing) {
      _asked = true;
      unawaited(_invoke('askNotifications'));
    }
    unawaited(_invoke('update', {
      'title': m.title,
      'artist': m.artist,
      'album': m.album,
      'playing': playing,
      'position': player.position.inMilliseconds,
      'duration': dur,
      'uri': m.uri,
      'path': m.path,
    }));
  }

  Future<void> _invoke(String method, [Object? args]) async {
    try {
      await _ch.invokeMethod(method, args);
    } catch (_) {}
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method != 'action') return null;
    final a = Map<String, Object?>.from(call.arguments as Map);
    switch (a['name']) {
      case 'play':
        if (!player.playing) await player.toggle();
      case 'pause':
        if (player.playing) await player.pause();
      case 'next':
        await player.next();
      case 'previous':
        await player.previous();
      case 'seek':
        await player.seek(Duration(milliseconds: (a['ms'] as num?)?.toInt() ?? 0));
      case 'stop':
        await player.pause();
        _dismissed = true;
        _changed();
    }
    return null;
  }
}


// ======================================================================
// Visualizer

enum VisStyle {
  bars('Bars'),
  mirror('Mirror'),
  rings('Rings'),
  off('None (album art)');

  const VisStyle(this.label);
  final String label;
}

class VisSettings {
  static VisStyle style = VisStyle.bars;
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final p = await SharedPreferences.getInstance();
    style = VisStyle.values.firstWhere((v) => v.name == p.getString('visStyle'), orElse: () => VisStyle.bars);
  }

  static void set(VisStyle s) {
    style = s;
    unawaited(SharedPreferences.getInstance().then((p) => p.setString('visStyle', s.name)));
  }
}

/// Bars that move with the music. The levels come from [DeskPlayer.bandsNow];
/// they're smoothed here (quick rise, slower fall, with peak caps).
class Visualizer extends StatefulWidget {
  const Visualizer({super.key, required this.player, required this.style});
  final DeskPlayer player;
  final VisStyle style;

  @override
  State<Visualizer> createState() => _VisualizerState();
}

class _VisualizerState extends State<Visualizer> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _levels = List<double>.filled(DeskPlayer.kBands, 0);
  final _peaks = List<double>.filled(DeskPlayer.kBands, 0);
  double _t = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration d) {
    final now = widget.player.playing ? widget.player.bandsNow() : null;
    for (var i = 0; i < _levels.length; i++) {
      final target = now?[i] ?? 0;
      _levels[i] = target > _levels[i] ? _levels[i] + (target - _levels[i]) * 0.6 : _levels[i] * 0.88;
      _peaks[i] = math.max(_peaks[i] - 0.008, _levels[i]);
    }
    _t = d.inMilliseconds / 1000;
    setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _VisPainter(widget.style, List.of(_levels), List.of(_peaks), _t), size: Size.infinite);
}

class _VisPainter extends CustomPainter {
  _VisPainter(this.style, this.levels, this.peaks, this.t);
  final VisStyle style;
  final List<double> levels;
  final List<double> peaks;
  final double t;

  static Color _hue(double x, double v) =>
      HSVColor.fromAHSV(1, (200 - 160 * x + 360) % 360, 0.75, 0.55 + 0.45 * v).toColor();

  @override
  void paint(Canvas canvas, Size size) {
    final n = levels.length;
    switch (style) {
      case VisStyle.off:
        return;
      case VisStyle.bars:
        final w = size.width / n;
        final base = size.height - 8;
        final maxH = size.height * 0.85;
        for (var i = 0; i < n; i++) {
          final h = levels[i] * maxH;
          final r = Rect.fromLTWH(i * w + 2, base - h, w - 4, h);
          canvas.drawRect(
              r,
              Paint()
                ..shader = LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [const Color(0xFF2B55B8), _hue(i / n, levels[i])])
                    .createShader(r));
          final py = base - peaks[i] * maxH - 4;
          canvas.drawRect(Rect.fromLTWH(i * w + 2, py, w - 4, 3), Paint()..color = Colors.white70);
        }
      case VisStyle.mirror:
        final w = size.width / n;
        final mid = size.height / 2;
        for (var i = 0; i < n; i++) {
          final h = levels[i] * size.height * 0.45;
          final paint = Paint()..color = _hue(i / n, levels[i]).withValues(alpha: 0.85);
          canvas.drawRRect(
              RRect.fromRectAndRadius(Rect.fromLTWH(i * w + 3, mid - h, w - 6, h * 2), const Radius.circular(3)), paint);
        }
      case VisStyle.rings:
        final c = size.center(Offset.zero);
        final maxR = size.shortestSide * 0.48;
        for (var i = n - 1; i >= 0; i--) {
          final r = maxR * (0.25 + 0.75 * i / n) * (0.85 + 0.3 * levels[i]);
          canvas.drawCircle(
              c,
              r,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2 + 6 * levels[i]
                ..color = _hue((i / n + t * 0.05) % 1, levels[i]).withValues(alpha: 0.35 + 0.6 * levels[i]));
        }
    }
  }

  @override
  bool shouldRepaint(_VisPainter old) => true;
}

// ======================================================================
// Full screen video

/// Covers the whole screen (taskbar too) while [DeskPlayer.fullScreen] is on.
/// Click = play/pause, double-click or Esc = back to the window. The controls
/// show when the mouse moves.
class FullScreenVideo extends StatefulWidget {
  const FullScreenVideo({super.key});

  @override
  State<FullScreenVideo> createState() => _FullScreenVideoState();
}

class _FullScreenVideoState extends State<FullScreenVideo> {
  final p = DeskPlayer.instance;
  bool _controls = true;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    p.addListener(_changed);
  }

  @override
  void dispose() {
    p.removeListener(_changed);
    _hide?.cancel();
    super.dispose();
  }

  bool _wasOn = false;

  void _changed() {
    if (!mounted) return;
    final on = p.fullScreen && p.isVideo;
    if (on && !_wasOn) _poke();
    _wasOn = on;
    setState(() {});
  }

  void _poke() {
    _hide?.cancel();
    if (!_controls) setState(() => _controls = true);
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controls = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = p.controller;
    if (!p.fullScreen || !p.isVideo) return const SizedBox.shrink();
    final cur = p.current;
    return MouseRegion(
      cursor: _controls ? SystemMouseCursors.basic : SystemMouseCursors.none,
      onHover: (_) => _poke(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _poke();
          p.toggle();
        },
        onDoubleTap: () => p.setFullScreen(false),
        child: Container(
          color: Colors.black,
          child: Stack(children: [
            if (c != null && c.value.isInitialized)
              Center(child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c))),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 200),
              left: 0,
              right: 0,
              bottom: _controls ? 0 : -110,
              child: GestureDetector(
                onTap: _poke,
                onDoubleTap: () {},
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                        begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black87]),
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    SeekBar(player: p, light: true),
                    Row(children: [
                      RoundButton(icon: Icons.skip_previous, tip: 'Previous', onTap: p.previous),
                      const SizedBox(width: 6),
                      RoundButton(
                          icon: p.playing ? Icons.pause : Icons.play_arrow,
                          tip: p.playing ? 'Pause (Space)' : 'Play (Space)',
                          size: 40,
                          onTap: p.toggle),
                      const SizedBox(width: 6),
                      RoundButton(icon: Icons.skip_next, tip: 'Next', onTap: p.next),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(cur?.title ?? '',
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      GestureDetector(
                        onTap: p.toggleMute,
                        child: Icon(p.muted || p.volume == 0 ? Icons.volume_off : Icons.volume_up,
                            size: 20, color: Colors.white),
                      ),
                      SizedBox(
                        width: 120,
                        child: Slider(
                            value: p.muted ? 0 : p.volume,
                            onChanged: p.setVolume,
                            activeColor: const Color(0xFF8FD14F)),
                      ),
                      RoundButton(
                          icon: Icons.fullscreen_exit, tip: 'Exit Full Screen (Esc)', onTap: () => p.setFullScreen(false)),
                    ]),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
