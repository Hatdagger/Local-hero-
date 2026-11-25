import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

import 'settings.dart';

/// Plays the classic AIM sounds the user imported. The app ships no sounds of
/// its own; without an import, events are silent.
class SoundEngine {
  final AppSettings settings;
  Directory? _dir;
  bool foreground = true;

  SoundEngine(this.settings);

  Future<Directory> soundsDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}sounds');
    await d.create(recursive: true);
    return _dir = d;
  }

  Future<List<String>> available() async {
    final d = await soundsDir();
    final files = await d
        .list()
        .where((f) => f is File && f.path.toLowerCase().endsWith('.wav'))
        .map((f) => f.uri.pathSegments.last)
        .toList();
    files.sort();
    return files;
  }

  Future<void> saveSound(String name, List<int> bytes) async {
    final d = await soundsDir();
    await File('${d.path}${Platform.pathSeparator}${name.toLowerCase()}').writeAsBytes(bytes, flush: true);
  }

  Future<void> play(SoundEvent e) async {
    if (!foreground || !settings.soundsOn) return;
    final name = settings.soundFor(e);
    if (name.isEmpty) return;
    await playFile(name);
  }

  /// Last playback problem, for the Prefs screen.
  String? lastError;

  /// Plays a sound. Returns null on success or a short reason it failed.
  Future<String?> playFile(String name) async {
    try {
      final d = await soundsDir();
      final f = File('${d.path}${Platform.pathSeparator}$name');
      if (!await f.exists()) return lastError = 'The sound file $name is missing. Import the sounds again.';
      final path = await _playablePath(f);
      final p = AudioPlayer();
      p.onPlayerComplete.first.then((_) => p.dispose());
      await p.setVolume(1.0);
      await p.play(DeviceFileSource(path));
      lastError = null;
      return null;
    } catch (e) {
      // Sound is a nicety; never let it break messaging.
      return lastError = 'Couldn\'t play $name: $e';
    }
  }

  /// The classic AIM sounds are 8-bit WAVs at odd sample rates (down to
  /// 7418 Hz), which some players reject or mangle. Plays a converted
  /// 16-bit 22050 Hz copy (made once, kept in sounds/.pcm16/).
  Future<String> _playablePath(File src) async {
    final bytes = await src.readAsBytes();
    final wav = WavInfo.parse(bytes);
    if (wav == null || (wav.bits == 16 && wav.rate >= 11025 && wav.channels <= 2 && wav.format == 1)) {
      return src.path;
    }
    final cacheDir = Directory('${src.parent.path}${Platform.pathSeparator}.pcm16');
    await cacheDir.create(recursive: true);
    final out = File('${cacheDir.path}${Platform.pathSeparator}${src.uri.pathSegments.last}');
    if (await out.exists() && (await out.lastModified()).isAfter(await src.lastModified())) return out.path;
    final converted = toPcm16(bytes, wav);
    if (converted == null) return src.path;
    await out.writeAsBytes(converted, flush: true);
    return out.path;
  }
}

/// The parts of a WAV header we need.
class WavInfo {
  final int format, channels, rate, bits, dataOffset, dataLength;
  const WavInfo(this.format, this.channels, this.rate, this.bits, this.dataOffset, this.dataLength);

  static WavInfo? parse(List<int> b) {
    if (b.length < 44 || String.fromCharCodes(b.sublist(0, 4)) != 'RIFF' || String.fromCharCodes(b.sublist(8, 12)) != 'WAVE') {
      return null;
    }
    int u16(int o) => b[o] | b[o + 1] << 8;
    int u32(int o) => b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24;
    int? format, channels, rate, bits;
    var i = 12;
    while (i + 8 <= b.length) {
      final id = String.fromCharCodes(b.sublist(i, i + 4));
      final len = u32(i + 4);
      if (id == 'fmt ' && i + 24 <= b.length) {
        format = u16(i + 8);
        channels = u16(i + 10);
        rate = u32(i + 12);
        bits = u16(i + 22);
      } else if (id == 'data' && format != null) {
        final avail = b.length - (i + 8);
        return WavInfo(format, channels!, rate!, bits!, i + 8, len > avail ? avail : len);
      }
      i += 8 + len + (len & 1);
    }
    return null;
  }
}

/// Converts 8- or 16-bit PCM (mono/stereo) to 16-bit mono 22050 Hz PCM.
Uint8List? toPcm16(List<int> b, WavInfo w, {int outRate = 22050}) {
  if (w.format != 1 || (w.bits != 8 && w.bits != 16) || w.channels < 1 || w.channels > 2 || w.rate <= 0) return null;
  final frameBytes = w.bits ~/ 8 * w.channels;
  final frames = w.dataLength ~/ frameBytes;
  if (frames == 0) return null;
  double sample(int f) {
    var sum = 0.0;
    for (var c = 0; c < w.channels; c++) {
      final o = w.dataOffset + f * frameBytes + c * (w.bits ~/ 8);
      if (w.bits == 8) {
        sum += (b[o] - 128) * 256; // 8-bit WAV is unsigned
      } else {
        final v = b[o] | b[o + 1] << 8;
        sum += v >= 0x8000 ? v - 0x10000 : v;
      }
    }
    return sum / w.channels;
  }

  final outFrames = (frames * outRate / w.rate).floor();
  final data = ByteData(44 + outFrames * 2);
  void tag(int o, String s) {
    for (var k = 0; k < 4; k++) {
      data.setUint8(o + k, s.codeUnitAt(k));
    }
  }

  tag(0, 'RIFF');
  data.setUint32(4, 36 + outFrames * 2, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, outRate, Endian.little);
  data.setUint32(28, outRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, outFrames * 2, Endian.little);
  for (var n = 0; n < outFrames; n++) {
    final pos = n * w.rate / outRate; // linear interpolation
    final i0 = pos.floor();
    final i1 = i0 + 1 < frames ? i0 + 1 : i0;
    final t = pos - i0;
    final v = sample(i0) * (1 - t) + sample(i1) * t;
    data.setInt16(44 + n * 2, v.round().clamp(-32768, 32767), Endian.little);
  }
  return data.buffer.asUint8List();
}
