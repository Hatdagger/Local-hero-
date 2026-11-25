import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'window_manager.dart';
import 'xp_theme.dart';

const kMiniPlayerId = 'miniplayer';

/// What's playing in Local Hero (or another player), via Android's media
/// sessions (see DeskMedia.kt).
class MediaRemote extends ChangeNotifier {
  MediaRemote._() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'state') _onState(Map<String, dynamic>.from(call.arguments as Map));
      return null;
    });
  }
  static final instance = MediaRemote._();
  static const _ch = MethodChannel('desk/media');

  bool known = false;
  bool access = false;
  bool active = false;
  String app = '';
  String package = '';
  String title = '';
  String artist = '';
  String album = '';
  Uint8List? art;
  bool playing = false;
  int durationMs = 0;
  double _speed = 1;
  int _posMs = 0;
  DateTime _at = DateTime.now();

  /// Current position, moving along while playing.
  int get positionMs {
    if (!playing) return _posMs;
    final p = _posMs + (DateTime.now().difference(_at).inMilliseconds * _speed).round();
    return durationMs > 0 ? p.clamp(0, durationMs) : p;
  }

  void _onState(Map<String, dynamic> m) {
    known = true;
    access = m['access'] as bool? ?? false;
    active = m['active'] as bool? ?? false;
    if (active) {
      app = m['app'] as String? ?? '';
      package = m['package'] as String? ?? '';
      title = m['title'] as String? ?? '';
      artist = m['artist'] as String? ?? '';
      album = m['album'] as String? ?? '';
      final a = m['art'];
      art = a is Uint8List && a.isNotEmpty ? a : null;
      playing = m['playing'] as bool? ?? false;
      durationMs = (m['duration'] as num? ?? 0).toInt();
      _speed = (m['speed'] as num? ?? 1).toDouble();
      if (_speed == 0) _speed = 1;
      final pos = (m['position'] as num? ?? 0).toInt();
      final updated = (m['updated'] as num? ?? 0).toInt();
      final now = (m['now'] as num? ?? 0).toInt();
      // Android reports where it was at "updated"; catch up to "now".
      _posMs = playing && updated > 0 && now > updated ? pos + ((now - updated) * _speed).round() : pos;
      _at = DateTime.now();
    }
    notifyListeners();
  }

  Future<void> _call(String m, [Map<String, dynamic>? args]) async {
    try {
      await _ch.invokeMethod(m, args);
    } catch (_) {}
  }

  Future<void> start() => _call('start');
  Future<void> stop() => _call('stop');
  Future<void> askAccess() => _call('askAccess');
  Future<void> openPlayer() => _call('openPlayer');
  Future<void> next() => _call('next');
  Future<void> previous() => _call('previous');

  Future<void> playPause() async {
    // Feels instant; Android confirms a moment later.
    playing = !playing;
    _posMs = positionMs;
    _at = DateTime.now();
    notifyListeners();
    await _call(playing ? 'play' : 'pause');
  }

  Future<void> seek(int ms) async {
    _posMs = ms;
    _at = DateTime.now();
    notifyListeners();
    await _call('seek', {'ms': ms});
  }
}

DeskWindow miniPlayerWindow() => DeskWindow(
      id: kMiniPlayerId,
      title: 'Local Hero',
      icon: Icons.music_note,
      size: const Size(360, 158),
      resizable: false,
      canMaximize: false,
      alwaysOnTop: true,
      onClose: () => MediaRemote.instance.stop(),
      content: (c, w) => const _MiniPlayer(),
    );

class _MiniPlayer extends StatefulWidget {
  const _MiniPlayer();

  @override
  State<_MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<_MiniPlayer> {
  final _m = MediaRemote.instance;
  Timer? _tick;
  late final AppLifecycleListener _life;
  double? _dragMs;

  @override
  void initState() {
    super.initState();
    _m.addListener(_changed);
    _m.start();
    _life = AppLifecycleListener(onResume: _m.start);
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_m.playing && _dragMs == null && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _m.removeListener(_changed);
    _life.dispose();
    _tick?.cancel();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final t = _m.active && _m.title.isNotEmpty ? _m.title : (_m.app.isEmpty ? 'Local Hero' : _m.app);
    context.read<WindowManager>().setTitle(kMiniPlayerId, t);
  }

  static String _time(int ms) {
    final s = (ms / 1000).floor();
    final m = s ~/ 60;
    final h = m ~/ 60;
    final ss = (s % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${(m % 60).toString().padLeft(2, '0')}:$ss' : '$m:$ss';
  }

  @override
  Widget build(BuildContext context) {
    if (!_m.known) {
      return const Center(child: Text('Connecting...', style: Xp.textGrey));
    }
    if (!_m.access) {
      return Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('To show and control Local Hero, the desktop needs notification access.', style: Xp.text),
          const SizedBox(height: 4),
          const Text('Turn on "ClassicDesk mini player" in the next screen, then come back.', style: Xp.textGrey),
          const Spacer(),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            XpButton(label: 'Allow access...', minWidth: 110, isDefault: true, onPressed: _m.askAccess),
          ]),
        ]),
      );
    }
    if (!_m.active) {
      return Padding(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          _art(null),
          const SizedBox(width: 10),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Nothing playing', style: Xp.textBold),
              const SizedBox(height: 4),
              const Text('Start some music in Local Hero.', style: Xp.textGrey),
              const SizedBox(height: 8),
              XpButton(label: 'Open Local Hero', minWidth: 120, onPressed: _m.openPlayer),
            ]),
          ),
        ]),
      );
    }

    final dur = _m.durationMs;
    final pos = (_dragMs ?? _m.positionMs.toDouble()).clamp(0.0, dur > 0 ? dur.toDouble() : 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GestureDetector(onDoubleTap: _m.openPlayer, child: _art(_m.art)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(_m.title.isEmpty ? '(untitled)' : _m.title,
                style: Xp.textBold, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text([_m.artist, _m.album].where((s) => s.isNotEmpty).join(' - '),
                style: Xp.textGrey.copyWith(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _btn(Icons.skip_previous, 'Previous', _m.previous),
              const SizedBox(width: 6),
              _btn(_m.playing ? Icons.pause : Icons.play_arrow, _m.playing ? 'Pause' : 'Play', _m.playPause, big: true),
              const SizedBox(width: 6),
              _btn(Icons.skip_next, 'Next', _m.next),
              const Spacer(),
              Tooltip(
                message: 'Open ${_m.app.isEmpty ? 'the player' : _m.app}',
                child: InkWell(
                  onTap: _m.openPlayer,
                  child: const Padding(padding: EdgeInsets.all(3), child: Icon(Icons.open_in_new, size: 16)),
                ),
              ),
            ]),
            SizedBox(
              height: 22,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                  activeTrackColor: Xp.selection,
                  thumbColor: Xp.selection,
                ),
                child: Slider(
                  value: pos,
                  min: 0,
                  max: dur > 0 ? dur.toDouble() : 1,
                  onChanged: dur > 0 ? (v) => setState(() => _dragMs = v) : null,
                  onChangeEnd: dur > 0
                      ? (v) {
                          setState(() => _dragMs = null);
                          _m.seek(v.round());
                        }
                      : null,
                ),
              ),
            ),
            Row(children: [
              Text(_time(pos.round()), style: Xp.text.copyWith(fontSize: 11)),
              const Spacer(),
              Text(dur > 0 ? _time(dur) : '', style: Xp.text.copyWith(fontSize: 11)),
            ]),
          ]),
        ),
      ]),
    );
  }

  Widget _art(Uint8List? bytes) => Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          color: const Color(0xFF1E3E9B),
          border: Border.all(color: const Color(0xFF7F9DB9)),
        ),
        child: bytes == null
            ? const Icon(Icons.music_note, size: 48, color: Colors.white70)
            : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
      );

  Widget _btn(IconData icon, String tip, VoidCallback onTap, {bool big = false}) => Tooltip(
        message: tip,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: big ? 34 : 28,
            height: big ? 34 : 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Xp.buttonBorder),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFFFFFFF), Color(0xFFECEBE6), Color(0xFFD6D0C5)],
              ),
            ),
            child: Icon(icon, size: big ? 22 : 18, color: const Color(0xFF1E3E9B)),
          ),
        ),
      );
}
