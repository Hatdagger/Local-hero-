import 'package:classic_desk/desk/media_library.dart';
import 'package:classic_desk/desk/playlists.dart';
import 'package:flutter_test/flutter_test.dart';

MediaItem song(String k, {String title = 't', int ms = 1000}) =>
    MediaItem(title: title, uri: 'content://media/$k', durationMs: ms, artist: 'A', album: 'B');

void main() {
  test('playlists survive saving and loading', () {
    final lists = [
      Playlist('Road trip', [song('1', title: 'One'), MediaItem.fromPath('/sdcard/Music/x.mp3', video: false)]),
      Playlist('Empty'),
    ];
    final back = PlaylistOps.decode(PlaylistOps.encode(lists));
    expect(back.length, 2);
    expect(back[0].name, 'Road trip');
    expect(back[0].items[0].title, 'One');
    expect(back[0].items[0].key, 'content://media/1');
    expect(back[0].items[0].artist, 'A');
    expect(back[0].items[1].path, '/sdcard/Music/x.mp3');
    expect(back[1].items, isEmpty);
    expect(PlaylistOps.decode('not json'), isEmpty);
  });

  test('names are kept unique', () {
    expect(PlaylistOps.uniqueName('Mix', []), 'Mix');
    expect(PlaylistOps.uniqueName('Mix', ['mix']), 'Mix (2)');
    expect(PlaylistOps.uniqueName('Mix', ['Mix', 'Mix (2)']), 'Mix (3)');
  });

  test('adding skips songs already in the list', () {
    final (out, n) = PlaylistOps.addAll([song('1')], [song('1'), song('2'), song('2')]);
    expect(n, 1);
    expect(out.map((m) => m.key), ['content://media/1', 'content://media/2']);
  });

  test('moving a song', () {
    final l = [song('a'), song('b'), song('c')];
    expect(PlaylistOps.move(l, 0, 2).map((m) => m.uri.split('/').last), ['b', 'c', 'a']);
    expect(PlaylistOps.move(l, 2, 0).map((m) => m.uri.split('/').last), ['c', 'a', 'b']);
  });

  test('total length', () {
    expect(Playlist('x', [song('1', ms: 1500), song('2', ms: 500)]).totalMs, 2000);
  });
}
