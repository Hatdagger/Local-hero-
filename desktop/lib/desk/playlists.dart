import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'media_library.dart';

/// A saved list of songs (and videos) in the Media Player.
class Playlist {
  Playlist(this.name, [List<MediaItem>? items]) : items = items ?? [];
  String name;
  List<MediaItem> items;

  int get totalMs => items.fold(0, (t, m) => t + m.durationMs);

  Map<String, Object?> toJson() => {'name': name, 'items': [for (final m in items) mediaToJson(m)]};

  static Playlist fromJson(Map<String, Object?> j) => Playlist(
        j['name'] as String? ?? 'Playlist',
        [
          for (final m in (j['items'] as List? ?? const []))
            if (m is Map) mediaFromJson(Map<String, Object?>.from(m)),
        ],
      );
}

/// Enough of a song to play it and show it, even before the library is read.
Map<String, Object?> mediaToJson(MediaItem m) => {
      'id': m.id,
      'title': m.title,
      if (m.artist.isNotEmpty) 'artist': m.artist,
      if (m.album.isNotEmpty) 'album': m.album,
      if (m.genre.isNotEmpty) 'genre': m.genre,
      if (m.year != 0) 'year': m.year,
      if (m.trackNo != 0) 'track': m.trackNo,
      'duration': m.durationMs,
      if (m.fileName.isNotEmpty) 'name': m.fileName,
      if (m.folder.isNotEmpty) 'folder': m.folder,
      if (m.albumId != 0) 'albumId': m.albumId,
      if (m.uri.isNotEmpty) 'uri': m.uri,
      if (m.path.isNotEmpty) 'path': m.path,
      if (m.video) 'video': true,
    };

MediaItem mediaFromJson(Map<String, Object?> j) {
  int n(String k) => (j[k] as num? ?? 0).toInt();
  String s(String k) => j[k] as String? ?? '';
  return MediaItem(
    id: n('id'),
    title: s('title'),
    artist: s('artist'),
    album: s('album'),
    genre: s('genre'),
    year: n('year'),
    trackNo: n('track'),
    durationMs: n('duration'),
    fileName: s('name'),
    folder: s('folder'),
    albumId: n('albumId'),
    uri: s('uri'),
    path: s('path'),
    video: j['video'] == true,
  );
}

/// Pure list operations (tested in test/playlists_test.dart).
class PlaylistOps {
  /// [base], or "[base] (2)", "[base] (3)"... whichever isn't taken.
  static String uniqueName(String base, Iterable<String> taken) {
    final lower = {for (final t in taken) t.toLowerCase()};
    if (!lower.contains(base.toLowerCase())) return base;
    for (var i = 2;; i++) {
      final n = '$base ($i)';
      if (!lower.contains(n.toLowerCase())) return n;
    }
  }

  /// [items] with [add] on the end, leaving out songs already there.
  /// Returns the new list and how many were added.
  static (List<MediaItem>, int) addAll(List<MediaItem> items, Iterable<MediaItem> add) {
    final have = {for (final m in items) m.key};
    final out = List.of(items);
    var n = 0;
    for (final m in add) {
      if (have.add(m.key)) {
        out.add(m);
        n++;
      }
    }
    return (out, n);
  }

  /// Moves the item at [from] so it ends up at [to] (both in the old list).
  static List<MediaItem> move(List<MediaItem> items, int from, int to) {
    if (from < 0 || from >= items.length) return items;
    final out = List.of(items);
    final m = out.removeAt(from);
    out.insert(to.clamp(0, out.length), m);
    return out;
  }

  /// Swaps stored songs for the library's copies (fresher titles, art), by key.
  static List<MediaItem> refresh(List<MediaItem> items, Map<String, MediaItem> byKey) =>
      [for (final m in items) byKey[m.key] ?? m];

  static String encode(List<Playlist> lists) => jsonEncode([for (final p in lists) p.toJson()]);

  static List<Playlist> decode(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is! List) return [];
      return [for (final p in v) if (p is Map) Playlist.fromJson(Map<String, Object?>.from(p))];
    } catch (_) {
      return [];
    }
  }
}

/// All saved playlists, kept in the app's own storage (playlists.json).
class Playlists extends ChangeNotifier {
  Playlists._() {
    unawaited(load());
  }
  static final instance = Playlists._();

  List<Playlist> lists = [];
  bool loaded = false;
  File? _file;

  Future<void> load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}/playlists.json');
      if (await _file!.exists()) lists = PlaylistOps.decode(await _file!.readAsString());
    } catch (_) {}
    loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    final f = _file;
    if (f == null) return;
    try {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(PlaylistOps.encode(lists), flush: true);
      await tmp.rename(f.path);
    } catch (_) {}
  }

  void _changed() {
    unawaited(_save());
    notifyListeners();
  }

  String freeName([String base = 'New Playlist']) => PlaylistOps.uniqueName(base, lists.map((p) => p.name));

  Playlist create(String name, [List<MediaItem> items = const []]) {
    final p = Playlist(freeName(name.trim().isEmpty ? 'New Playlist' : name.trim()));
    p.items = PlaylistOps.addAll(const [], items).$1;
    lists = [...lists, p];
    _changed();
    return p;
  }

  void rename(Playlist p, String name) {
    final n = name.trim();
    if (n.isEmpty || n == p.name) return;
    p.name = PlaylistOps.uniqueName(n, lists.where((x) => x != p).map((x) => x.name));
    _changed();
  }

  void delete(Playlist p) {
    lists = lists.where((x) => x != p).toList();
    _changed();
  }

  /// Adds songs, skipping ones already in the list. Returns how many went in.
  int add(Playlist p, Iterable<MediaItem> items) {
    final (out, n) = PlaylistOps.addAll(p.items, items);
    if (n > 0) {
      p.items = out;
      _changed();
    }
    return n;
  }

  void removeAt(Playlist p, int i) {
    if (i < 0 || i >= p.items.length) return;
    p.items = List.of(p.items)..removeAt(i);
    _changed();
  }

  void move(Playlist p, int from, int to) {
    p.items = PlaylistOps.move(p.items, from, to);
    _changed();
  }
}
