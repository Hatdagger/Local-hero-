import 'package:classic_desk/desk/media_library.dart';
import 'package:flutter_test/flutter_test.dart';

MediaItem t(String title, String artist, String album, {int track = 0, int added = 0, String genre = '', String folder = 'Music/'}) =>
    MediaItem(title: title, artist: artist, album: album, trackNo: track, addedSec: added, genre: genre, folder: folder, uri: 'u:$title');

void main() {
  final lib = [
    t('Song B', 'The Zebras', 'Alpha', track: 2, added: 5),
    t('Song A', 'Apples', 'Beta', track: 1, added: 9, genre: 'Rock'),
    t('Intro', 'The Zebras', 'Alpha', track: 1, added: 1, folder: 'Music/Old/'),
  ];

  test('sort like Local Hero', () {
    expect(LibraryOps.sort(lib, SortBy.title).map((e) => e.title), ['Intro', 'Song A', 'Song B']);
    // "The" is ignored, then album, then track number.
    expect(LibraryOps.sort(lib, SortBy.artist).map((e) => e.title), ['Song A', 'Intro', 'Song B']);
    expect(LibraryOps.sort(lib, SortBy.recent).first.title, 'Song A');
  });

  test('search needs every word', () {
    expect(LibraryOps.search(lib, 'zebras intro').map((e) => e.title), ['Intro']);
    expect(LibraryOps.search(lib, '  ').length, 3);
  });

  test('groups', () {
    final albums = LibraryOps.group(lib, GroupBy.albums);
    expect(albums.map((b) => b.name), ['Alpha', 'Beta']);
    expect(albums.first.items.map((e) => e.title), ['Intro', 'Song B']);
    expect(LibraryOps.group(lib, GroupBy.genres).map((b) => b.name), ['No genre', 'Rock']);
    expect(LibraryOps.group(lib, GroupBy.folders).length, 2);
  });

  test('times and files', () {
    expect(LibraryOps.formatTime(65000), '1:05');
    expect(LibraryOps.formatTime(3723000), '1:02:03');
    final f = MediaItem.fromPath('/storage/emulated/0/Movies/clip one.mp4', video: true);
    expect(f.title, 'clip one');
    expect(f.video, isTrue);
    expect(f.key, '/storage/emulated/0/Movies/clip one.mp4');
  });
}
