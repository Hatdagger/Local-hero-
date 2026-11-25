import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// What kind of thing a file is, from its name.
enum FileKind { folder, text, image, audio, video, web, apk, archive, pdf, other }

const _text = {
  'txt', 'md', 'log', 'ini', 'cfg', 'conf', 'json', 'xml', 'csv', 'tsv', 'kt', 'kts', 'java', 'dart', 'py', 'sh',
  'yaml', 'yml', 'toml', 'c', 'h', 'cpp', 'hpp', 'js', 'ts', 'css', 'gradle', 'properties', 'srt', 'nfo', 'bat', 'cue',
};
const _image = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'heif'};
const _audio = {'mp3', 'flac', 'ogg', 'oga', 'opus', 'm4a', 'aac', 'wav', 'wma', 'mid', 'midi', 'amr'};
const _video = {'mp4', 'mkv', 'webm', 'avi', 'mov', '3gp', 'm4v', 'wmv', 'mpg', 'mpeg', 'ts'};
const _web = {'html', 'htm', 'url', 'webloc', 'mht', 'mhtml', 'xhtml'};
const _archive = {'zip', '7z', 'rar', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'iso'};

/// Pictures Flutter can show itself (for the picture viewer and wallpaper).
const kViewableImages = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

String baseName(String path) {
  final p = path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
  final i = p.lastIndexOf('/');
  return i < 0 ? p : p.substring(i + 1);
}

String parentOf(String path) {
  final p = path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
  final i = p.lastIndexOf('/');
  if (i <= 0) return '/';
  return p.substring(0, i);
}

String extOf(String name) {
  final i = name.lastIndexOf('.');
  if (i <= 0 || i == name.length - 1) return '';
  return name.substring(i + 1).toLowerCase();
}

FileKind kindOf(String name, {bool folder = false}) {
  if (folder) return FileKind.folder;
  final e = extOf(name);
  if (_text.contains(e)) return FileKind.text;
  if (_image.contains(e)) return FileKind.image;
  if (_audio.contains(e)) return FileKind.audio;
  if (_video.contains(e) && e != 'ts') return FileKind.video;
  if (_web.contains(e)) return FileKind.web;
  if (e == 'apk' || e == 'apks' || e == 'xapk') return FileKind.apk;
  if (_archive.contains(e)) return FileKind.archive;
  if (e == 'pdf') return FileKind.pdf;
  return FileKind.other;
}

/// The "Type" column text.
String typeLabel(String name, {bool folder = false}) {
  if (folder) return 'File Folder';
  final e = extOf(name);
  switch (kindOf(name)) {
    case FileKind.text:
      return e == 'txt' ? 'Text Document' : '${e.toUpperCase()} File';
    case FileKind.image:
      return e == 'jpg' || e == 'jpeg' ? 'JPEG Image' : '${e.toUpperCase()} Image';
    case FileKind.audio:
      return '${e.toUpperCase()} Audio';
    case FileKind.video:
      return '${e.toUpperCase()} Video';
    case FileKind.web:
      return e == 'url' ? 'Internet Shortcut' : 'Web Page';
    case FileKind.apk:
      return 'Android App';
    case FileKind.archive:
      return '${e.toUpperCase()} Archive';
    case FileKind.pdf:
      return 'PDF Document';
    case FileKind.folder:
      return 'File Folder';
    case FileKind.other:
      return e.isEmpty ? 'File' : '${e.toUpperCase()} File';
  }
}

(IconData, Color) iconFor(FileKind k) => switch (k) {
      FileKind.folder => (Icons.folder, const Color(0xFFE8B84A)),
      FileKind.text => (Icons.description, const Color(0xFF4A6FB5)),
      FileKind.image => (Icons.image, const Color(0xFF3B9C4A)),
      FileKind.audio => (Icons.music_note, const Color(0xFFE07A1F)),
      FileKind.video => (Icons.movie, const Color(0xFF7A4BC2)),
      FileKind.web => (Icons.public, const Color(0xFF1E7BD8)),
      FileKind.apk => (Icons.android, const Color(0xFF3DAA4E)),
      FileKind.archive => (Icons.inventory_2, const Color(0xFFB8862B)),
      FileKind.pdf => (Icons.picture_as_pdf, const Color(0xFFC62828)),
      FileKind.other => (Icons.insert_drive_file, const Color(0xFF8A8A8A)),
    };

/// "4 KB", "1.2 MB" like the Size column.
String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes bytes';
  const units = ['KB', 'MB', 'GB', 'TB'];
  double v = bytes / 1024;
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  final s = v >= 100 || u == 0 ? v.ceil().toString() : v.toStringAsFixed(1);
  return '$s ${units[u]}';
}

String formatDate(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final ap = d.hour < 12 ? 'AM' : 'PM';
  return '${d.month}/${d.day}/${d.year} $h:${d.minute.toString().padLeft(2, '0')} $ap';
}

/// A free name in [dir]: "name", then "name - Copy", "name - Copy (2)"...
/// (or "name (2)" when [copySuffix] is false).
String freeName(String dir, String name, {bool copySuffix = true}) {
  bool taken(String n) => FileSystemEntity.typeSync('$dir/$n', followLinks: false) != FileSystemEntityType.notFound;
  if (!taken(name)) return name;
  final e = extOf(name);
  final stem = e.isEmpty ? name : name.substring(0, name.length - e.length - 1);
  final dot = e.isEmpty ? '' : '.$e';
  for (var i = 1; i < 10000; i++) {
    final n = copySuffix
        ? (i == 1 ? '$stem - Copy$dot' : '$stem - Copy ($i)$dot')
        : '$stem (${i + 1})$dot';
    if (!taken(n)) return n;
  }
  return '$stem ${DateTime.now().millisecondsSinceEpoch}$dot';
}

/// Is [path] the folder [dir] or inside it?
bool isInside(String path, String dir) => path == dir || path.startsWith(dir.endsWith('/') ? dir : '$dir/');

// ======================================================================
// Copy / move / delete

class FileOps {
  /// Copies [src] (file or folder) into [destDir]. Returns the new path.
  static Future<String> copyInto(String src, String destDir) async {
    final type = FileSystemEntity.typeSync(src, followLinks: false);
    if (type == FileSystemEntityType.notFound) throw FileSystemException('Not found', src);
    if (type == FileSystemEntityType.directory && isInside(destDir, src)) {
      throw FileSystemException("Can't copy a folder into itself", src);
    }
    final sameFolder = parentOf(src) == destDir;
    final name = freeName(destDir, baseName(src), copySuffix: sameFolder);
    final dest = '$destDir/$name';
    await _copy(src, dest, type);
    return dest;
  }

  static Future<void> _copy(String src, String dest, FileSystemEntityType type) async {
    if (type == FileSystemEntityType.directory) {
      await Directory(dest).create(recursive: true);
      await for (final e in Directory(src).list(followLinks: false)) {
        final t = FileSystemEntity.typeSync(e.path, followLinks: false);
        await _copy(e.path, '$dest/${baseName(e.path)}', t);
      }
    } else if (type == FileSystemEntityType.link) {
      final target = await Link(src).target();
      await Link(dest).create(target);
    } else {
      await File(src).copy(dest);
    }
  }

  /// Moves [src] into [destDir]. Returns the new path (the same path when it
  /// was already there).
  static Future<String> moveInto(String src, String destDir) async {
    if (parentOf(src) == destDir) return src;
    final type = FileSystemEntity.typeSync(src, followLinks: false);
    if (type == FileSystemEntityType.notFound) throw FileSystemException('Not found', src);
    if (type == FileSystemEntityType.directory && isInside(destDir, src)) {
      throw FileSystemException("Can't move a folder into itself", src);
    }
    final dest = '$destDir/${freeName(destDir, baseName(src), copySuffix: false)}';
    return moveTo(src, dest);
  }

  /// Moves/renames [src] to exactly [dest]; copies and deletes when the two
  /// are on different drives.
  static Future<String> moveTo(String src, String dest) async {
    final type = FileSystemEntity.typeSync(src, followLinks: false);
    try {
      if (type == FileSystemEntityType.directory) {
        await Directory(src).rename(dest);
      } else if (type == FileSystemEntityType.link) {
        await Link(src).rename(dest);
      } else {
        await File(src).rename(dest);
      }
    } on FileSystemException {
      await _copy(src, dest, type);
      await deleteForever(src);
    }
    return dest;
  }

  static Future<void> deleteForever(String path) async {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    switch (type) {
      case FileSystemEntityType.directory:
        await Directory(path).delete(recursive: true);
      case FileSystemEntityType.link:
        await Link(path).delete();
      case FileSystemEntityType.notFound:
        break;
      default:
        await File(path).delete();
    }
  }

  /// Total size of a folder (or a file).
  static Future<(int bytes, int files, int folders)> measure(String path) async {
    var bytes = 0, files = 0, folders = 0;
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type != FileSystemEntityType.directory) {
      try {
        return (await File(path).length(), 1, 0);
      } catch (_) {
        return (0, 1, 0);
      }
    }
    try {
      await for (final e in Directory(path).list(recursive: true, followLinks: false)) {
        if (e is File) {
          files++;
          try {
            bytes += await e.length();
          } catch (_) {}
        } else if (e is Directory) {
          folders++;
        }
      }
    } catch (_) {}
    return (bytes, files, folders);
  }
}

// ======================================================================
// Clipboard and "something changed" signal shared by all Explorer windows

class FileClipboard extends ChangeNotifier {
  FileClipboard._();
  static final instance = FileClipboard._();

  List<String> paths = const [];
  bool cut = false;

  void set(List<String> p, {required bool cut}) {
    paths = List.unmodifiable(p);
    this.cut = cut;
    notifyListeners();
  }

  void clear() {
    paths = const [];
    cut = false;
    notifyListeners();
  }

  bool isCut(String path) => cut && paths.contains(path);
}

/// Ticks whenever any window changed files, so the others refresh.
class FsEvents extends ChangeNotifier {
  FsEvents._();
  static final instance = FsEvents._();
  void changed() => notifyListeners();
}

// ======================================================================
// Recycle Bin

class RecycledItem {
  final String id; // folder name inside the bin
  final String name;
  final String original; // full original path
  final DateTime deleted;
  final bool folder;
  RecycledItem(this.id, this.name, this.original, this.deleted, this.folder);

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'original': original, 'deleted': deleted.toIso8601String(), 'folder': folder};

  static RecycledItem fromJson(Map<String, dynamic> m) => RecycledItem(
        m['id'] as String,
        m['name'] as String,
        m['original'] as String,
        DateTime.tryParse(m['deleted'] as String? ?? '') ?? DateTime.now(),
        m['folder'] as bool? ?? false,
      );
}

/// Deleted files wait here until the bin is emptied. Each item sits in its
/// own numbered folder; index.json remembers where it came from.
class RecycleBin extends ChangeNotifier {
  RecycleBin._();
  static final instance = RecycleBin._();

  String? _dir;
  List<RecycledItem> items = [];

  /// Picks where the bin lives: on the device's storage when the desktop may
  /// write there, otherwise inside the desktop's own storage.
  Future<void> init({required String preferred, required String fallback}) async {
    for (final d in [preferred, fallback]) {
      try {
        final dir = Directory(d);
        await dir.create(recursive: true);
        final probe = File('$d/.probe');
        await probe.writeAsString('ok');
        await probe.delete();
        if (_dir != d) {
          _dir = d;
          await _load();
        }
        return;
      } catch (_) {}
    }
  }

  String? get folder => _dir;
  bool get isEmpty => items.isEmpty;

  Future<void> _load() async {
    try {
      final f = File('$_dir/index.json');
      if (await f.exists()) {
        final list = jsonDecode(await f.readAsString()) as List<dynamic>;
        items = list.map((e) => RecycledItem.fromJson(Map<String, dynamic>.from(e as Map))).toList();
        // Forget entries whose files are gone.
        items.removeWhere((i) => !Directory('$_dir/${i.id}').existsSync());
      } else {
        items = [];
      }
    } catch (_) {
      items = [];
    }
    notifyListeners();
  }

  Future<void> _save() async {
    await File('$_dir/index.json').writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()));
  }

  String pathOf(RecycledItem i) => '$_dir/${i.id}/${i.name}';

  /// Moves [paths] into the bin.
  Future<void> recycle(List<String> paths) async {
    if (_dir == null) throw const FileSystemException('The Recycle Bin is not ready');
    for (final p in paths) {
      if (isInside(p, _dir!)) continue;
      final folder = FileSystemEntity.isDirectorySync(p);
      final id = '${DateTime.now().microsecondsSinceEpoch}';
      await Directory('$_dir/$id').create();
      final name = baseName(p);
      await FileOps.moveTo(p, '$_dir/$id/$name');
      items.insert(0, RecycledItem(id, name, p, DateTime.now(), folder));
    }
    await _save();
    notifyListeners();
    FsEvents.instance.changed();
  }

  Future<void> restore(List<RecycledItem> list) async {
    for (final i in list) {
      final dir = parentOf(i.original);
      await Directory(dir).create(recursive: true);
      final dest = '$dir/${freeName(dir, baseName(i.original), copySuffix: false)}';
      await FileOps.moveTo(pathOf(i), dest);
      await FileOps.deleteForever('$_dir/${i.id}');
      items.remove(i);
    }
    await _save();
    notifyListeners();
    FsEvents.instance.changed();
  }

  Future<void> purge(List<RecycledItem> list) async {
    for (final i in list) {
      await FileOps.deleteForever('$_dir/${i.id}');
      items.remove(i);
    }
    await _save();
    notifyListeners();
  }

  Future<void> empty() => purge(List.of(items));
}
