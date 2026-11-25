import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One song or video. Songs come from Android's media index (the same scan
/// Local Hero does); a file opened from the desktop becomes one too.
class MediaItem {
  final int id;
  final String title;
  final String artist;
  final String album;
  final String genre;
  final int year;
  final int trackNo;
  final int durationMs;
  final int sizeBytes;
  final String fileName;
  final String folder; // e.g. "Music/Downloads/"
  final int addedSec;
  final int albumId;
  final String uri; // content:// uri, or empty for a plain file
  final String path; // file path when known
  final bool video;

  const MediaItem({
    this.id = 0,
    required this.title,
    this.artist = '',
    this.album = '',
    this.genre = '',
    this.year = 0,
    this.trackNo = 0,
    this.durationMs = 0,
    this.sizeBytes = 0,
    this.fileName = '',
    this.folder = '',
    this.addedSec = 0,
    this.albumId = 0,
    this.uri = '',
    this.path = '',
    this.video = false,
  });

  /// Identity for the queue and selection.
  String get key => uri.isNotEmpty ? uri : path;

  String get subtitle => [artist, album].where((s) => s.isNotEmpty).join(' - ');

  static MediaItem fromSong(Map<String, dynamic> m) => MediaItem(
        id: (m['id'] as num? ?? 0).toInt(),
        title: _orName(m['title'] as String?, m['name'] as String?),
        artist: m['artist'] as String? ?? '',
        album: m['album'] as String? ?? '',
        genre: m['genre'] as String? ?? '',
        year: (m['year'] as num? ?? 0).toInt(),
        trackNo: (m['track'] as num? ?? 0).toInt(),
        durationMs: (m['duration'] as num? ?? 0).toInt(),
        sizeBytes: (m['size'] as num? ?? 0).toInt(),
        fileName: m['name'] as String? ?? '',
        folder: _folder(m['folder'] as String?, m['path'] as String?),
        addedSec: (m['added'] as num? ?? 0).toInt(),
        albumId: (m['albumId'] as num? ?? 0).toInt(),
        uri: m['uri'] as String? ?? '',
        path: m['path'] as String? ?? '',
      );

  static MediaItem fromVideo(Map<String, dynamic> m) => MediaItem(
        id: (m['id'] as num? ?? 0).toInt(),
        title: _orName(m['title'] as String?, m['name'] as String?),
        durationMs: (m['duration'] as num? ?? 0).toInt(),
        sizeBytes: (m['size'] as num? ?? 0).toInt(),
        fileName: m['name'] as String? ?? '',
        folder: _folder(m['folder'] as String?, m['path'] as String?),
        addedSec: (m['added'] as num? ?? 0).toInt(),
        uri: m['uri'] as String? ?? '',
        path: m['path'] as String? ?? '',
        video: true,
      );

  /// A file opened from the desktop (not from the library).
  static MediaItem fromPath(String path, {required bool video}) {
    final name = path.substring(path.lastIndexOf('/') + 1);
    final dot = name.lastIndexOf('.');
    return MediaItem(
      title: dot > 0 ? name.substring(0, dot) : name,
      fileName: name,
      folder: path.substring(0, path.lastIndexOf('/') + 1),
      path: path,
      video: video,
    );
  }

  static String _orName(String? title, String? name) {
    if (title != null && title.trim().isNotEmpty) return title;
    final n = name ?? '';
    final dot = n.lastIndexOf('.');
    return dot > 0 ? n.substring(0, dot) : n;
  }

  static String _folder(String? rel, String? path) {
    if (rel != null && rel.isNotEmpty) return rel;
    final p = path ?? '';
    final i = p.lastIndexOf('/');
    return i < 0 ? '' : p.substring(0, i + 1);
  }
}

// ======================================================================
// Sorting, searching and grouping (ported from Local Hero's LibraryOps)

enum SortBy {
  title('Title'),
  artist('Artist'),
  album('Album'),
  recent('Recently added'),
  mostPlayed('Most played'),
  length('Length'),
  folder('Folder');

  const SortBy(this.label);
  final String label;
}

enum GroupBy {
  songs('All Music'),
  artists('Artist'),
  albums('Album'),
  genres('Genre'),
  folders('Folder');

  const GroupBy(this.label);
  final String label;
}

/// One browsable bucket: an album, an artist, a folder...
class Bucket {
  final String name;
  final String sub;
  final List<MediaItem> items;
  final MediaItem? cover;
  const Bucket(this.name, this.sub, this.items, {this.cover});
}

class LibraryOps {
  static String _key(String s) {
    final l = s.toLowerCase().trim();
    return l.startsWith('the ') ? l.substring(4).trim() : l;
  }

  static int _cmpChain(List<int> parts) => parts.firstWhere((c) => c != 0, orElse: () => 0);

  static List<MediaItem> sort(List<MediaItem> list, SortBy by, {int Function(MediaItem)? plays}) {
    final l = List.of(list);
    switch (by) {
      case SortBy.title:
        l.sort((a, b) => _key(a.title).compareTo(_key(b.title)));
      case SortBy.artist:
        l.sort((a, b) => _cmpChain([
              _key(a.artist).compareTo(_key(b.artist)),
              _key(a.album).compareTo(_key(b.album)),
              a.trackNo.compareTo(b.trackNo),
              _key(a.title).compareTo(_key(b.title)),
            ]));
      case SortBy.album:
        l.sort((a, b) => _cmpChain([
              _key(a.album).compareTo(_key(b.album)),
              a.trackNo.compareTo(b.trackNo),
              _key(a.title).compareTo(_key(b.title)),
            ]));
      case SortBy.recent:
        l.sort((a, b) => b.addedSec.compareTo(a.addedSec));
      case SortBy.mostPlayed:
        final p = plays ?? (_) => 0;
        l.sort((a, b) => _cmpChain([p(b).compareTo(p(a)), _key(a.title).compareTo(_key(b.title))]));
      case SortBy.length:
        l.sort((a, b) => b.durationMs.compareTo(a.durationMs));
      case SortBy.folder:
        l.sort((a, b) => _cmpChain([
              a.folder.toLowerCase().compareTo(b.folder.toLowerCase()),
              a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase()),
            ]));
    }
    return l;
  }

  /// Every word must appear in the title, artist, album, genre or file name.
  static List<MediaItem> search(List<MediaItem> list, String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return list;
    return list.where((t) {
      final hay = '${t.title} ${t.artist} ${t.album} ${t.genre} ${t.fileName}'.toLowerCase();
      return words.every(hay.contains);
    }).toList();
  }

  static List<Bucket> group(List<MediaItem> list, GroupBy by) {
    Map<String, List<MediaItem>> buckets(String Function(MediaItem) key) {
      final m = <String, List<MediaItem>>{};
      for (final t in list) {
        (m[key(t)] ??= []).add(t);
      }
      return m;
    }

    switch (by) {
      case GroupBy.songs:
        return const [];
      case GroupBy.albums:
        final m = buckets((t) => '${t.album.isEmpty ? 'Unknown album' : t.album}\u0000${t.artist.toLowerCase()}');
        final out = m.values.map((v) {
          final s = sort(v, SortBy.album);
          final first = v.first;
          return Bucket(first.album.isEmpty ? 'Unknown album' : first.album,
              '${first.artist.isEmpty ? 'Unknown artist' : first.artist} · ${v.length} songs', s,
              cover: first);
        }).toList();
        out.sort((a, b) => _key(a.name).compareTo(_key(b.name)));
        return out;
      case GroupBy.artists:
        final m = buckets((t) => (t.artist.isEmpty ? 'Unknown artist' : t.artist).toLowerCase());
        final out = m.values.map((v) {
          final albums = v.map((t) => t.album).toSet().length;
          return Bucket(v.first.artist.isEmpty ? 'Unknown artist' : v.first.artist,
              '$albums albums · ${v.length} songs', sort(v, SortBy.artist),
              cover: v.first);
        }).toList();
        out.sort((a, b) => _key(a.name).compareTo(_key(b.name)));
        return out;
      case GroupBy.genres:
        final m = buckets((t) => (t.genre.isEmpty ? 'No genre' : t.genre).toLowerCase());
        final out = m.values
            .map((v) => Bucket(v.first.genre.isEmpty ? 'No genre' : v.first.genre, '${v.length} songs',
                sort(v, SortBy.artist), cover: v.first))
            .toList();
        out.sort((a, b) => _key(a.name).compareTo(_key(b.name)));
        return out;
      case GroupBy.folders:
        final m = buckets((t) => t.folder);
        final out = m.entries.map((e) {
          final trimmed = e.key.endsWith('/') ? e.key.substring(0, e.key.length - 1) : e.key;
          final name = trimmed.contains('/') ? trimmed.substring(trimmed.lastIndexOf('/') + 1) : trimmed;
          return Bucket(name.isEmpty ? '/' : name, '${e.key} · ${e.value.length} songs', sort(e.value, SortBy.folder),
              cover: e.value.first);
        }).toList();
        out.sort((a, b) => a.sub.toLowerCase().compareTo(b.sub.toLowerCase()));
        return out;
    }
  }

  static String formatTime(int ms) {
    final s = ms ~/ 1000;
    String two(int n) => n.toString().padLeft(2, '0');
    return s >= 3600 ? '${s ~/ 3600}:${two(s ~/ 60 % 60)}:${two(s % 60)}' : '${s ~/ 60}:${two(s % 60)}';
  }
}

// ======================================================================
// The library itself

class MediaLibrary extends ChangeNotifier {
  MediaLibrary._();
  static final instance = MediaLibrary._();
  static const _ch = MethodChannel('desk/library');

  List<MediaItem> songs = const [];
  List<MediaItem> videos = const [];
  bool scanned = false;
  bool scanning = false;
  bool permission = true;

  final Map<String, Uint8List?> _art = {};
  final Map<String, Future<Uint8List?>> _artLoading = {};

  Future<void> scan() async {
    if (scanning) return;
    scanning = true;
    notifyListeners();
    try {
      final r = Map<String, dynamic>.from(await _ch.invokeMethod<Map>('scan') ?? const {});
      permission = r['permission'] as bool? ?? false;
      songs = [
        for (final e in (r['audio'] as List? ?? const [])) MediaItem.fromSong(Map<String, dynamic>.from(e as Map)),
      ];
      videos = [
        for (final e in (r['video'] as List? ?? const [])) MediaItem.fromVideo(Map<String, dynamic>.from(e as Map)),
      ];
      videos.sort((a, b) => b.addedSec.compareTo(a.addedSec));
      scanned = true;
    } catch (_) {
      scanned = true;
    }
    scanning = false;
    notifyListeners();
  }

  Future<void> askPermission() async {
    try {
      await _ch.invokeMethod('askPermission');
    } catch (_) {}
  }

  /// Album art (or a video frame) for [item], cached. Null if there is none.
  Uint8List? artFor(MediaItem item) => _art[item.uri];

  Future<Uint8List?> loadArt(MediaItem item, {int size = 256}) {
    if (item.uri.isEmpty) return Future.value(null);
    if (_art.containsKey(item.uri)) return Future.value(_art[item.uri]);
    return _artLoading[item.uri] ??= () async {
      Uint8List? bytes;
      try {
        bytes = await _ch.invokeMethod<Uint8List>('art', {'uri': item.uri, 'size': size});
      } catch (_) {}
      _art[item.uri] = bytes;
      _artLoading.remove(item.uri);
      notifyListeners();
      return bytes;
    }();
  }
}
