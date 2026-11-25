import 'dart:math' as math;

import 'package:classic_desk/desk/media_library.dart';
import 'package:classic_desk/desk/mixes.dart';
import 'package:flutter_test/flutter_test.dart';

MediaItem song(String name, {String artist = 'A', String genre = '', int added = 0}) =>
    MediaItem(title: name, artist: artist, genre: genre, uri: 'content://$name', durationMs: 200000, addedSec: added);

const loud = SoundFeatures(
    energy: 0.95, tempoBpm: 170, beatStrength: 0.9, brightness: 0.7, onsetRate: 6, dynamics: 0.2, major: true, modeStrength: 0.5);
const calm = SoundFeatures(
    energy: 0.15, tempoBpm: 70, beatStrength: 0.2, brightness: 0.5, onsetRate: 0.8, dynamics: 0.3, major: true, modeStrength: 0.3);
const sad = SoundFeatures(
    energy: 0.2, tempoBpm: 65, beatStrength: 0.2, brightness: 0.1, onsetRate: 0.8, dynamics: 0.3, major: false, modeStrength: 0.8);

void main() {
  const day = 86400000;
  final now = DateTime(2026, 11, 25, 20).millisecondsSinceEpoch;

  test('skips: under 30 s or under a quarter, without finishing', () {
    expect(const PlayEvent('a', 0, 10000, 200000, false).skipped, isTrue);
    expect(const PlayEvent('a', 0, 40000, 200000, false).skipped, isTrue);
    expect(const PlayEvent('a', 0, 60000, 200000, false).skipped, isFalse);
    expect(const PlayEvent('a', 0, 10000, 200000, true).skipped, isFalse);
    final e = PlayEvent.fromJson(const PlayEvent('k', 5, 6, 7, true).toJson())!;
    expect([e.key, e.startedAtMs, e.playedMs, e.durationMs, e.completed], ['k', 5, 6, 7, true]);
  });

  test('moods follow the sound and the genre', () {
    Mood top(SoundFeatures? f, [String g = '']) =>
        MoodModel.scores(f, g).entries.reduce((a, b) => b.value > a.value ? b : a).key;
    expect(top(loud), Mood.energetic);
    expect(top(calm), Mood.chill);
    expect(top(sad), Mood.melancholy);
    expect(top(null, 'Death Metal'), Mood.intense);
  });

  test('mood mixes pick songs that sound right; unheard songs need a genre hint', () {
    final a = song('a'), b = song('b'), c = song('c'), d = song('d', genre: 'Ambient');
    final m = MixMaker([a, b, c, d], {a.key: loud, b.key: calm, c.key: sad}, Habits(const [], now),
        random: math.Random(1));
    final chill = m.moodMix(Mood.chill).items.map((x) => x.title);
    expect(chill, contains('b'));
    expect(chill, isNot(contains('a')));
    expect(m.moodMix(Mood.energetic).items.map((x) => x.title), ['a']);
  });

  test('habit mixes: on repeat, forgotten favorites, fresh finds, right now', () {
    final a = song('a'), b = song('b', artist: 'B'), c = song('c', added: 50), d = song('d', added: 99);
    final events = [
      for (var i = 0; i < 5; i++) PlayEvent(a.key, now - i * day ~/ 2, 200000, 200000, true),
      for (var i = 0; i < 3; i++) PlayEvent(b.key, now - (60 + i) * day - 6 * 3600000, 200000, 200000, true),
    ];
    final m = MixMaker([a, b, c, d], const {}, Habits(events, now), random: math.Random(2));
    expect(m.onRepeat().items.map((x) => x.title), ['a']);
    expect(m.forgottenFavorites(now).items.map((x) => x.title), ['b']);
    expect(m.freshFinds().items.map((x) => x.title), ['d', 'c']);
    final rightNow = m.rightNow(DateTime.fromMillisecondsSinceEpoch(now).hour);
    expect(rightNow.items.first.title, 'a');
    expect(rightNow.title, 'Evening Mix');
  });

  test('songs you skip drop out of mood mixes', () {
    final a = song('a'), b = song('b');
    final skips = [for (var i = 0; i < 6; i++) PlayEvent(a.key, now - i * day, 5000, 200000, false)];
    final m = MixMaker([a, b], {a.key: calm, b.key: calm}, Habits(skips, now), random: math.Random(3));
    expect(m.moodMix(Mood.chill).items.map((x) => x.title), ['b']);
  });

  test('songs like this starts with the song and prefers close sounds', () {
    final seed = song('seed'), close = song('close', artist: 'X'), far = song('far', artist: 'Y');
    final m = MixMaker([seed, close, far], {seed.key: calm, close.key: calm, far.key: loud}, Habits(const [], now),
        random: math.Random(4));
    expect(m.soundsLike(seed).items.map((x) => x.title), ['seed', 'close', 'far']);
  });

  test('no artist twice in a row when it can be helped', () {
    final list = [song('1', artist: 'A'), song('2', artist: 'A'), song('3', artist: 'B'), song('4', artist: 'B')];
    final out = MixMaker.spreadArtists(list);
    for (var i = 1; i < out.length; i++) {
      expect(out[i].artist == out[i - 1].artist, isFalse);
    }
  });

  test('features survive a save and load', () {
    final f = SoundFeatures.fromJson(loud.toJson())!;
    expect(f.energy, loud.energy);
    expect(f.tempoBpm, loud.tempoBpm);
    expect(f.major, isTrue);
  });
}
