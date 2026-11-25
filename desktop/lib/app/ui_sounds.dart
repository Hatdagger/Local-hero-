import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

/// Little sounds for the on-screen phones and gadgets: key clicks, flips,
/// slides, the TV powering on, the handheld's boot beep. All are made in code
/// when first needed (the app ships no sound files).
enum UiSound {
  /// Plastic phone key.
  key,

  /// Square-wave blip (green-screen handheld).
  pixel,

  /// Soft glassy "bloop" (console dashboard).
  jewel,

  /// Tiny tick (music player).
  tick,

  /// Lid snapping open.
  flip,

  /// Something sliding into place.
  slide,

  /// Phone landing (candybar).
  land,

  /// Screen lighting up.
  chirp,

  /// Tube TV switching on: thunk + static + hum.
  crt,

  /// Handheld boot: short note, then a long high beeeep.
  beep,

  /// Letter box popping up.
  pop,

  /// Putting it away.
  close,

  /// Highlight moving between keys with the D-pad / stick (one per gadget
  /// family): soft plastic tick, quiet square blip, tiny glassy blip,
  /// click-wheel tick.
  navKey,
  navPixel,
  navJewel,
  navWheel,
}

const _rate = 22050;

/// Makes the samples (-1..1) for a sound. Pure maths, so it can be tested.
List<double> synthSamples(UiSound s) {
  final rnd = Random(s.index + 11);
  final out = <double>[];
  double noise() => rnd.nextDouble() * 2 - 1;
  int n(double ms) => (_rate * ms / 1000).round();
  double sq(double f, double t) => sin(2 * pi * f * t) >= 0 ? 1.0 : -1.0;

  /// Mixes [f] into [out] starting at [startMs] for [ms].
  void add(double startMs, double ms, double Function(double t) f) {
    final start = n(startMs), len = n(ms);
    while (out.length < start + len) {
      out.add(0);
    }
    for (var i = 0; i < len; i++) {
      out[start + i] += f(i / _rate);
    }
  }

  switch (s) {
    case UiSound.key:
      add(0, 30, (t) => noise() * exp(-t * 320) * 0.5 + sin(2 * pi * 1900 * t) * exp(-t * 220) * 0.3);
    case UiSound.pixel:
      add(0, 38, (t) => sq(1180, t) * 0.22 * min(1.0, (0.038 - t) * 400));
    case UiSound.jewel:
      add(0, 90, (t) => sin(2 * pi * (650 + 4000 * t) * t) * exp(-t * 38) * 0.42);
    case UiSound.tick:
      add(0, 8, (t) => noise() * exp(-t * 900) * 0.55);
    case UiSound.flip:
      add(0, 12, (t) => noise() * exp(-t * 500) * 0.5);
      add(70, 140, (t) => sin(2 * pi * 150 * t) * exp(-t * 28) * 0.45);
      add(70, 18, (t) => noise() * exp(-t * 380) * 0.45);
    case UiSound.slide:
      {
        var y = 0.0;
        add(0, 230, (t) {
          final a = 0.05 + t * 1.6; // the hiss gets brighter as it slides
          y += a.clamp(0.0, 0.9) * (noise() - y);
          return y * sin(pi * t / 0.23) * 0.5;
        });
        add(215, 25, (t) => noise() * exp(-t * 400) * 0.45);
      }
    case UiSound.land:
      add(0, 160, (t) => sin(2 * pi * 95 * t) * exp(-t * 22) * 0.7);
      add(0, 14, (t) => noise() * exp(-t * 450) * 0.4);
    case UiSound.chirp:
      add(0, 55, (t) => sin(2 * pi * 1500 * t) * min(1.0, t * 800) * exp(-t * 30) * 0.32);
      add(60, 80, (t) => sin(2 * pi * 2100 * t) * min(1.0, t * 800) * exp(-t * 25) * 0.32);
    case UiSound.crt:
      add(0, 120, (t) => (sin(2 * pi * 55 * t) * 0.6 + noise() * 0.35) * exp(-t * 30));
      add(40, 420, (t) => noise() * 0.13 * exp(-t * 7));
      add(40, 650, (t) => sin(2 * pi * 120 * t) * 0.14 * exp(-t * 4) * min(1.0, t * 30));
    case UiSound.beep:
      // A short low note, then the long high "beeeep" that fades out.
      add(0, 75, (t) => sq(1046.5, t) * 0.2);
      add(75, 900, (t) => sq(2093, t) * 0.2 * exp(-t * 3.2));
    case UiSound.pop:
      add(0, 60, (t) => sin(2 * pi * (380 + 9000 * t) * t) * exp(-t * 45) * 0.4);
    case UiSound.close:
      {
        var y = 0.0;
        add(0, 180, (t) {
          final a = 0.7 - t * 3.5; // reverse of slide: gets darker
          y += a.clamp(0.04, 0.9) * (noise() - y);
          return y * sin(pi * t / 0.18) * 0.42;
        });
      }
    case UiSound.navKey:
      add(0, 14, (t) => noise() * exp(-t * 700) * 0.22 + sin(2 * pi * 2600 * t) * exp(-t * 600) * 0.12);
    case UiSound.navPixel:
      add(0, 18, (t) => sq(1568, t) * 0.1 * min(1.0, (0.018 - t) * 600));
    case UiSound.navJewel:
      add(0, 35, (t) => sin(2 * pi * (1400 + 3000 * t) * t) * exp(-t * 110) * 0.22);
    case UiSound.navWheel:
      add(0, 5, (t) => noise() * exp(-t * 1500) * 0.35);
  }
  for (var i = 0; i < out.length; i++) {
    out[i] = out[i].clamp(-1.0, 1.0);
  }
  // Tiny fade at the ends so nothing pops.
  const fade = 40;
  for (var i = 0; i < fade && i < out.length; i++) {
    out[i] *= i / fade;
    out[out.length - 1 - i] *= i / fade;
  }
  return out;
}

/// 16-bit mono WAV file bytes.
Uint8List wavFromSamples(List<double> samples, {int rate = _rate}) {
  final data = ByteData(44 + samples.length * 2);
  void tag(int o, String s) {
    for (var i = 0; i < 4; i++) {
      data.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  data.setUint32(4, 36 + samples.length * 2, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, (samples[i] * 32767).round().clamp(-32768, 32767), Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Plays [UiSound]s. A small pool of players is reused so key clicks are quick.
class UiSounds {
  UiSounds._();
  static final instance = UiSounds._();

  static bool get _testing => Platform.environment.containsKey('FLUTTER_TEST');

  final _paths = <UiSound, String>{};
  final _players = <AudioPlayer>[];
  int _next = 0;

  Future<String> _path(UiSound s) async {
    final known = _paths[s];
    if (known != null) return known;
    final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}aim_ui_sounds');
    await dir.create(recursive: true);
    final f = File('${dir.path}${Platform.pathSeparator}v1_${s.name}.wav');
    if (!await f.exists()) await f.writeAsBytes(wavFromSamples(synthSamples(s)), flush: true);
    return _paths[s] = f.path;
  }

  /// Makes the sound files ahead of time so the first click isn't late.
  Future<void> warmUp() async {
    if (_testing) return;
    try {
      for (final s in UiSound.values) {
        await _path(s);
      }
    } catch (_) {}
  }

  Future<AudioPlayer> _player() async {
    if (_players.length < 5) {
      final p = AudioPlayer();
      _players.add(p);
      await p.setReleaseMode(ReleaseMode.stop);
      if (Platform.isAndroid) {
        try {
          await p.setPlayerMode(PlayerMode.lowLatency);
        } catch (_) {}
      }
      return p;
    }
    return _players[_next++ % _players.length];
  }

  Future<void> play(UiSound s, {double volume = 0.7}) async {
    if (_testing) return;
    try {
      final path = await _path(s);
      final p = await _player();
      await p.stop();
      await p.play(DeviceFileSource(path), volume: volume);
    } catch (_) {
      // Sounds are a nicety; never let them break typing.
    }
  }
}
