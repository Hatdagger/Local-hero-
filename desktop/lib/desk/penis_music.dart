import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'media_player.dart';
import 'window_manager.dart';
import 'xp_theme.dart';

/// Penis Music: really fast drums, a rubbery bouncing bass and cartoon sound
/// effects played live in time with whatever song the Media Player is
/// playing, with the song sped up a little. The music files are never changed.
/// The sounds are made by DeskPenis.kt; this keeps it in step with the player.
class PenisMusic extends ChangeNotifier {
  PenisMusic._() {
    unawaited(_load());
  }
  static final instance = PenisMusic._();
  static const _ch = MethodChannel('desk/penis');

  static const drumNames = ['Fast', 'Faster', 'Ludicrous'];
  static const sfxNames = ['None', 'Some', 'Lots', 'Chaos'];

  bool on = false;
  int drums = 1;
  int sfx = 2;
  bool bass = true;
  double speed = 1.2;
  double volume = 0.7;

  /// What the engine is doing, for the settings window.
  String status = '';

  /// Beat found per song: key -> (bpm, ms of one beat).
  final Map<String, (double, double)?> _beats = {};
  final Set<String> _finding = {};

  DeskPlayer? _player;
  bool _engine = false;
  int _lastSync = 0;
  bool _lastPlaying = false;
  int _lastSeek = -1;
  String? _lastKey;
  double _appliedRate = 1;

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    on = p.getBool('penisOn') ?? false;
    drums = (p.getInt('penisDrums') ?? 1).clamp(0, 2).toInt();
    sfx = (p.getInt('penisSfx') ?? 2).clamp(0, 3).toInt();
    bass = p.getBool('penisBass') ?? true;
    speed = (p.getDouble('penisSpeed') ?? 1.2).clamp(1.0, 1.5).toDouble();
    volume = (p.getDouble('penisVolume') ?? 0.7).clamp(0.0, 1.0).toDouble();
    notifyListeners();
    _update(force: true);
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('penisOn', on);
    await p.setInt('penisDrums', drums);
    await p.setInt('penisSfx', sfx);
    await p.setBool('penisBass', bass);
    await p.setDouble('penisSpeed', speed);
    await p.setDouble('penisVolume', volume);
  }

  /// Called once by the player.
  void attach(DeskPlayer p) {
    _player = p;
    p.addListener(_update);
  }

  void set({bool? on, int? drums, int? sfx, bool? bass, double? speed, double? volume}) {
    this.on = on ?? this.on;
    this.drums = drums ?? this.drums;
    this.sfx = sfx ?? this.sfx;
    this.bass = bass ?? this.bass;
    this.speed = speed ?? this.speed;
    this.volume = volume ?? this.volume;
    unawaited(_save());
    notifyListeners();
    _update(force: true);
  }

  void toggle() => set(on: !on);

  /// The song speed the player should use right now.
  double get rateFor => on ? speed : 1.0;

  void _setStatus(String s) {
    if (status == s) return;
    status = s;
    // Don't notify from inside the player's own notify loop.
    scheduleMicrotask(notifyListeners);
  }

  void _update({bool force = false}) {
    final p = _player;
    if (p == null || kIsWeb || !Platform.isAndroid) return;
    final cur = p.current;
    final want = on && cur != null && !cur.video;

    // Song speed.
    final rate = want ? speed : 1.0;
    if (rate != _appliedRate) {
      _appliedRate = rate;
      unawaited(p.setRate(rate));
    }

    if (!want) {
      if (_engine) {
        _engine = false;
        unawaited(_ch.invokeMethod('stop').catchError((_) => null));
      }
      _setStatus(on ? (cur?.video == true ? 'Off for videos.' : 'Waiting for a song.') : 'Switched off.');
      return;
    }

    final song = cur!;
    final key = song.key;
    if (!_beats.containsKey(key)) {
      if (_finding.add(key)) {
        _setStatus('Finding the beat of "${song.title}"...');
        unawaited(() async {
          (double, double)? beat;
          try {
            final r = await _ch.invokeMethod<Map>('beat', {'uri': song.uri, 'duration': song.durationMs});
            if (r != null) beat = ((r['bpm'] as num).toDouble(), (r['beat0'] as num).toDouble());
          } catch (_) {}
          _beats[key] = beat;
          _finding.remove(key);
          _update(force: true);
        }());
      }
      return;
    }
    final beat = _beats[key];
    if (beat == null) {
      _setStatus("Couldn't find a beat in \"${song.title}\".");
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final changed = force || key != _lastKey || p.playing != _lastPlaying || p.seekSerial != _lastSeek;
    if (!changed && now - _lastSync < 400) return;
    _lastSync = now;
    _lastKey = key;
    _lastPlaying = p.playing;
    _lastSeek = p.seekSerial;
    _engine = true;
    _setStatus('Playing along at ${(beat.$1 * speed).round()} BPM.');
    unawaited(_ch.invokeMethod('sync', {
      'bpm': beat.$1,
      'beat0': beat.$2,
      'pos': p.position.inMilliseconds,
      'playing': p.playing,
      'rate': speed,
      'drums': drums,
      'sfx': sfx,
      'bass': bass,
      'volume': volume,
    }).catchError((_) => null));
  }
}

// ======================================================================
// Settings window

const kPenisMusicId = 'penismusic';

DeskWindow penisMusicWindow() => DeskWindow(
      id: kPenisMusicId,
      title: 'Penis Music',
      icon: Icons.celebration,
      size: const Size(380, 330),
      resizable: false,
      canMaximize: false,
      content: (c, w) => const _PenisMusicPanel(),
    );

class _PenisMusicPanel extends StatelessWidget {
  const _PenisMusicPanel();

  @override
  Widget build(BuildContext context) {
    final pm = PenisMusic.instance;
    return ListenableBuilder(
      listenable: pm,
      builder: (c, _) {
        Widget choice(String label, List<String> names, int value, ValueChanged<int> pick) => Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                SizedBox(width: 110, child: Text(label, style: Xp.text)),
                for (var i = 0; i < names.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: GestureDetector(
                      onTap: () => pick(i),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(3),
                          border: Border.all(color: i == value ? Xp.selection : const Color(0xFFB5B2A6)),
                          color: i == value ? const Color(0xFFD7E4FB) : Colors.white,
                        ),
                        child: Text(names[i], style: i == value ? Xp.textBold : Xp.text),
                      ),
                    ),
                  ),
              ]),
            );
        Widget slider(String label, double value, double min, double max, String shown, ValueChanged<double> set) =>
            Row(children: [
              SizedBox(width: 110, child: Text(label, style: Xp.text)),
              Expanded(
                child: Slider(
                  value: value,
                  min: min,
                  max: max,
                  divisions: ((max - min) * 20).round(),
                  onChanged: set,
                  activeColor: Xp.selection,
                ),
              ),
              SizedBox(width: 44, child: Text(shown, style: Xp.text)),
            ]);
        return Container(
          color: Xp.face,
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.celebration, size: 36, color: pm.on ? const Color(0xFFE07A1F) : Colors.black38),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                    'Turns whatever the Media Player is playing into penis music: really fast drums, '
                    'a rubbery bass and cartoon sounds, live. Your files are never changed.',
                    style: Xp.text.copyWith(fontSize: 11)),
              ),
            ]),
            const SizedBox(height: 8),
            XpCheck(label: 'Penis Music on', value: pm.on, onChanged: (v) => pm.set(on: v)),
            choice('Drums', PenisMusic.drumNames, pm.drums, (i) => pm.set(drums: i)),
            choice('Cartoon sounds', PenisMusic.sfxNames, pm.sfx, (i) => pm.set(sfx: i)),
            const SizedBox(height: 6),
            XpCheck(label: 'Rubbery bouncing bass', value: pm.bass, onChanged: (v) => pm.set(bass: v)),
            const SizedBox(height: 4),
            slider('Song speed', pm.speed, 1.0, 1.5, '${(pm.speed * 100).round()}%', (v) => pm.set(speed: v)),
            slider('Effects volume', pm.volume, 0.1, 1.0, '${(pm.volume * 100).round()}%', (v) => pm.set(volume: v)),
            const Spacer(),
            Text(pm.status, style: Xp.textGrey.copyWith(fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
          ]),
        );
      },
    );
  }
}
