import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../oscar/bytes.dart';

/// One received file in a [ChatLine]: its name and where it was saved.
String fileEntry(String name, String where) => '$name\t$where';

(String, String) parseFileEntry(String e) {
  final i = e.indexOf('\t');
  if (i < 0) return (e.split(RegExp(r'[\\/]')).last, e);
  return (e.substring(0, i), e.substring(i + 1));
}

class ChatLine {
  final String from;
  final String text;
  final DateTime time;
  final bool mine;
  final bool auto;

  /// Colours the sender picked (ARGB), or null for the default look.
  final int? fg;
  final int? bg;

  /// Outbox id while the message is still pending, otherwise null.
  String? pendingId;

  /// Pictures in this message (files on this device), sent by Direct Connect.
  final List<String> images;

  /// Files received with Send File: "name<TAB>where" (a path or a content://
  /// address). See [fileEntry].
  final List<String> files;

  /// A note from the app ("Direct Connect is open"), not a message.
  final bool system;

  ChatLine(this.from, this.text, this.time,
      {required this.mine,
      this.auto = false,
      this.pendingId,
      this.fg,
      this.bg,
      this.images = const [],
      this.files = const [],
      this.system = false});

  Map<String, dynamic> toJson() =>
      {
        'f': from,
        't': text,
        'at': time.millisecondsSinceEpoch,
        'm': mine,
        if (auto) 'a': true,
        if (fg != null) 'fg': fg,
        if (bg != null) 'bg': bg,
        if (images.isNotEmpty) 'img': images,
        if (files.isNotEmpty) 'fl': files,
        if (system) 'sys': true,
      };

  static ChatLine fromJson(Map<String, dynamic> j) => ChatLine(
        j['f'] as String,
        j['t'] as String,
        DateTime.fromMillisecondsSinceEpoch(j['at'] as int),
        mine: j['m'] as bool,
        auto: j['a'] as bool? ?? false,
        fg: j['fg'] as int?,
        bg: j['bg'] as int?,
        images: [for (final p in (j['img'] as List?) ?? const []) p as String],
        files: [for (final p in (j['fl'] as List?) ?? const []) p as String],
        system: j['sys'] as bool? ?? false,
      );
}

/// Optional on-device chat history (off by default). Cleared on sign-off.
class HistoryStore {
  Future<Directory> _dir(String owner) async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}history${Platform.pathSeparator}${normalizeSn(owner)}');
    await d.create(recursive: true);
    return d;
  }

  String _fileName(String buddy) =>
      '${normalizeSn(buddy).replaceAll(RegExp(r'[^a-z0-9@._-]'), '_')}.jsonl';

  Future<void> append(String owner, String buddy, ChatLine line) async {
    final d = await _dir(owner);
    final f = File('${d.path}${Platform.pathSeparator}${_fileName(buddy)}');
    await f.writeAsString('${jsonEncode(line.toJson())}\n', mode: FileMode.append, flush: true);
  }

  Future<Map<String, List<ChatLine>>> loadAll(String owner) async {
    final d = await _dir(owner);
    final out = <String, List<ChatLine>>{};
    await for (final f in d.list()) {
      if (f is! File || !f.path.endsWith('.jsonl')) continue;
      final lines = <ChatLine>[];
      String? buddy;
      for (final l in await f.readAsLines()) {
        if (l.trim().isEmpty) continue;
        try {
          final c = ChatLine.fromJson(jsonDecode(l) as Map<String, dynamic>);
          lines.add(c);
          if (!c.mine) buddy = c.from;
        } catch (_) {}
      }
      final name = buddy ?? f.uri.pathSegments.last.replaceAll('.jsonl', '');
      out[name] = lines;
    }
    return out;
  }

  /// Keeps a picture from a chat on this device (cleared on sign-off with
  /// the history). Returns its path.
  Future<String> savePicture(String owner, Uint8List bytes) async {
    final d = Directory('${(await _dir(owner)).path}${Platform.pathSeparator}pictures');
    await d.create(recursive: true);
    final f = File('${d.path}${Platform.pathSeparator}'
        '${DateTime.now().microsecondsSinceEpoch}${pictureExtension(bytes)}');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  Future<void> clear(String owner) async {
    final d = await _dir(owner);
    if (await d.exists()) await d.delete(recursive: true);
  }
}

/// The file extension for picture bytes, from their first bytes ('.bin' when
/// it isn't a picture the app shows).
String pictureExtension(List<int> b) {
  bool starts(List<int> sig) => b.length >= sig.length && List.generate(sig.length, (i) => b[i] == sig[i]).every((x) => x);
  if (starts(const [0xff, 0xd8, 0xff])) return '.jpg';
  if (starts(const [0x89, 0x50, 0x4e, 0x47])) return '.png';
  if (starts(const [0x47, 0x49, 0x46, 0x38])) return '.gif';
  if (starts(const [0x42, 0x4d])) return '.bmp';
  if (b.length >= 12 && starts(const [0x52, 0x49, 0x46, 0x46]) && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
    return '.webp';
  }
  return '.bin';
}

bool isPicturePath(String path) => !path.endsWith('.bin');
