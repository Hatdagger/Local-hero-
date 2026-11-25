import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'media_library.dart';

// Auto Mixes: Local Hero's mood and habit mixes (core/Mixes.kt and the
// MoodModel in core/Analysis.kt), ported to Dart. The sound analysis itself
// runs in Kotlin (android_overlay/DeskSound.kt).

// ======================================================================
// Sound features and moods

/// What the sound analysis found for one song. 0..1 unless noted.
class SoundFeatures {
  const SoundFeatures({
    required this.energy,
    required this.tempoBpm,
    required this.beatStrength,
    required this.brightness,
    required this.onsetRate,
    required this.dynamics,
    this.key = 0,
    this.major = true,
    this.modeStrength = 0,
  });

  final double energy;
  final double tempoBpm; // 0 = no clear beat
  final double beatStrength;
  final double brightness;
  final double onsetRate; // hits per second
  final double dynamics;
  final int key;
  final bool major;
  final double modeStrength;

  static SoundFeatures? fromJson(Object? j) {
    if (j is! Map) return null;
    double d(String k) => (j[k] as num? ?? 0).toDouble();
    if (j['energy'] == null) return null;
    return SoundFeatures(
      energy: d('energy'),
      tempoBpm: d('tempo'),
      beatStrength: d('beat'),
      brightness: d('bright'),
      onsetRate: d('onsets'),
      dynamics: d('dyn'),
      key: (j['key'] as num? ?? 0).toInt(),
      major: j['major'] != false,
      modeStrength: d('modeStr'),
    );
  }

  Map<String, Object> toJson() => {
        'energy': _r(energy),
        'tempo': _r(tempoBpm),
        'beat': _r(beatStrength),
        'bright': _r(brightness),
        'onsets': _r(onsetRate),
        'dyn': _r(dynamics),
        'key': key,
        'major': major,
        'modeStr': _r(modeStrength),
      };

  static double _r(double v) => (v * 10000).roundToDouble() / 10000;
}

enum Mood {
  energetic('Energetic', Icons.bolt),
  upbeat('Upbeat', Icons.wb_sunny),
  chill('Chill', Icons.cloud),
  melancholy('Melancholy', Icons.umbrella),
  intense('Intense', Icons.local_fire_department),
  focus('Focus', Icons.center_focus_strong);

  const Mood(this.label, this.icon);
  final String label;
  final IconData icon;
}

class MoodPoint {
  const MoodPoint(this.arousal, this.valence);
  final double arousal;
  final double valence;
}

/// Turns sound features (+ genre words) into mood scores.
class MoodModel {
  static MoodPoint point(SoundFeatures f) {
    final tempoNorm = f.tempoBpm <= 0 ? 0.3 : ((f.tempoBpm - 60) / 120).clamp(0.0, 1.0);
    final arousal = (0.55 * f.energy +
            0.25 * tempoNorm * (0.5 + 0.5 * f.beatStrength) +
            0.2 * (f.onsetRate / 6).clamp(0.0, 1.0))
        .clamp(0.0, 1.0);
    final modeTerm = f.major ? 0.5 + 0.5 * f.modeStrength : 0.5 - 0.5 * f.modeStrength;
    final valence = (0.5 * modeTerm + 0.3 * f.brightness + 0.2 * tempoNorm).clamp(0.0, 1.0);
    return MoodPoint(arousal.toDouble(), valence.toDouble());
  }

  static final List<(RegExp, Map<Mood, double>)> _genreHints = [
    (RegExp(r'metal|hardcore|punk|grind|industrial|drill|dubstep|thrash'), {Mood.intense: 0.35, Mood.energetic: 0.1}),
    (RegExp(r'rock|grunge'), {Mood.energetic: 0.15, Mood.intense: 0.1}),
    (
      RegExp(r'dance|edm|house|techno|trance|electro|disco|drum ?(and|&|n) ?bass|dnb|eurobeat'),
      {Mood.energetic: 0.3, Mood.upbeat: 0.1}
    ),
    (RegExp(r'pop|funk|soul|motown|reggae|ska|k-?pop|j-?pop'), {Mood.upbeat: 0.25}),
    (RegExp(r'hip ?hop|rap|trap'), {Mood.energetic: 0.15, Mood.intense: 0.1}),
    (RegExp(r'ambient|chill|lo-?fi|downtempo|new age|lounge|trip ?hop|bossa'), {Mood.chill: 0.3, Mood.focus: 0.15}),
    (
      RegExp(r'classical|piano|instrumental|soundtrack|score|orchestral|baroque|post-?rock|game'),
      {Mood.focus: 0.3, Mood.chill: 0.05}
    ),
    (RegExp(r'jazz|acoustic|folk|singer|country'), {Mood.chill: 0.15, Mood.upbeat: 0.05}),
    (RegExp(r'blues|emo|sad|slowcore|shoegaze|goth|darkwave'), {Mood.melancholy: 0.3}),
  ];

  /// Mood -> score 0..2.
  static Map<Mood, double> scores(SoundFeatures? f, String genre) {
    final out = <Mood, double>{};
    if (f != null) {
      final p = point(f);
      double near(double a, double v, [double spread = 0.28]) {
        final d2 = (p.arousal - a) * (p.arousal - a) + (p.valence - v) * (p.valence - v);
        return math.exp(-d2 / (2 * spread * spread));
      }

      out[Mood.energetic] = near(0.85, 0.6);
      out[Mood.upbeat] = near(0.6, 0.8);
      out[Mood.chill] = near(0.25, 0.6);
      out[Mood.melancholy] = near(0.25, 0.2);
      out[Mood.intense] = near(0.85, 0.25);
      out[Mood.focus] = 0.85 * near(0.35, 0.45, 0.25) * (1 - 0.4 * f.dynamics);
    } else {
      for (final m in Mood.values) {
        out[m] = 0.2;
      }
    }
    final g = genre.toLowerCase();
    if (g.trim().isNotEmpty) {
      for (final (re, hints) in _genreHints) {
        if (re.hasMatch(g)) {
          hints.forEach((m, add) => out[m] = (out[m] ?? 0) + add);
        }
      }
    }
    return out.map((m, v) => MapEntry(m, v.clamp(0.0, 2.0).toDouble()));
  }
}

// ======================================================================
// Listening history

/// One time a song was played (or skipped).
class PlayEvent {
  const PlayEvent(this.key, this.startedAtMs, this.playedMs, this.durationMs, this.completed);
  final String key;
  final int startedAtMs;
  final int playedMs;
  final int durationMs;
  final bool completed;

  /// Abandoned early: under 30 s, or under a quarter of the song, without finishing.
  bool get skipped => !completed && (playedMs < 30000 || (durationMs > 0 && playedMs < durationMs ~/ 4));

  List<Object> toJson() => [key, startedAtMs, playedMs, durationMs, completed ? 1 : 0];

  static PlayEvent? fromJson(Object? j) {
    if (j is! List || j.length < 5) return null;
    try {
      return PlayEvent(j[0] as String, (j[1] as num).toInt(), (j[2] as num).toInt(), (j[3] as num).toInt(), j[4] == 1);
    } catch (_) {
      return null;
    }
  }
}

class HabitStat {
  int plays = 0, completes = 0, skips = 0;
  int lastPlayedMs = 0;
  double affinity = 0; // decayed like/dislike signal
  double recent = 0; // plays in the last ~2 weeks, decayed
  final hours = List<double>.filled(24, 0);
}

/// What the listening history says about each song.
class Habits {
  Habits(Iterable<PlayEvent> events, int nowMs) {
    for (final e in events) {
      final s = byKey.putIfAbsent(e.key, HabitStat.new);
      final ageDays = math.max(0.0, (nowMs - e.startedAtMs) / 86400000.0);
      final decay = math.exp(-ageDays * math.ln2 / 45); // 45-day half-life
      s.plays++;
      if (e.completed) s.completes++;
      if (e.skipped) s.skips++;
      s.lastPlayedMs = math.max(s.lastPlayedMs, e.startedAtMs);
      final signal = e.completed ? 1.0 : (e.skipped ? -1.0 : 0.4);
      s.affinity += signal * decay;
      if (!e.skipped) {
        s.recent += math.exp(-ageDays * math.ln2 / 7);
        s.hours[DateTime.fromMillisecondsSinceEpoch(e.startedAtMs).hour] += 1;
      }
    }
  }

  final Map<String, HabitStat> byKey = {};

  HabitStat? operator [](String key) => byKey[key];

  double skipRate(String key) {
    final s = byKey[key];
    return s == null || s.plays == 0 ? 0 : s.skips / s.plays;
  }

  /// How much this song fits a given hour (±1 h smoothing), 0..1.
  double hourFit(String key, int hour) {
    final s = byKey[key];
    if (s == null) return 0;
    final n = s.hours.fold(0.0, (a, b) => a + b);
    if (n < 1) return 0;
    final near = s.hours[hour] + 0.5 * s.hours[(hour + 23) % 24] + 0.5 * s.hours[(hour + 1) % 24];
    return (near / n).clamp(0.0, 1.0);
  }
}

// ======================================================================
// Mix maker

/// A generated playlist.
class Mix {
  const Mix(this.key, this.title, this.subtitle, this.icon, this.items);
  final String key;
  final String title;
  final String subtitle;
  final IconData icon;
  final List<MediaItem> items;
}

/// Builds playlists from the library, the sound features and listening habits.
class MixMaker {
  MixMaker(this.library, this.features, this.habits, {math.Random? random}) : random = random ?? math.Random();

  final List<MediaItem> library;
  final Map<String, SoundFeatures> features;
  final Habits habits;
  final math.Random random;

  static const _dayMs = 86400000;

  double moodScore(MediaItem t, Mood mood) => MoodModel.scores(features[t.key], t.genre)[mood] ?? 0;

  /// Positive if you tend to finish it, negative if you skip it.
  double _liking(MediaItem t) {
    final s = habits[t.key];
    return s == null ? 0 : (s.affinity / 4).clamp(-1.0, 1.0);
  }

  Mix moodMix(Mood mood, {int size = 40}) {
    final scored = [
      for (final t in library)
        (
          t,
          moodScore(t, mood) +
              0.25 * _liking(t) -
              0.4 * habits.skipRate(t.key) +
              (features.containsKey(t.key) ? 0.0 : -0.3) +
              random.nextDouble() * 0.12
        ),
    ].where((e) => e.$2 > 0.35).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    final picked = [for (final e in scored.take(size)) e.$1];
    final ordered = flow(picked, rising: mood == Mood.energetic || mood == Mood.intense);
    return Mix('mood:${mood.name}', mood.label, '${ordered.length} songs picked by sound', mood.icon, ordered);
  }

  /// Songs played a lot lately.
  Mix onRepeat({int size = 30}) {
    final list = library.where((t) => (habits[t.key]?.recent ?? 0) > 0.5).toList()
      ..sort((a, b) => _repeatScore(b).compareTo(_repeatScore(a)));
    return Mix('habit:repeat', 'On Repeat', "What you've played most lately", Icons.repeat,
        spreadArtists(list.take(size).toList()));
  }

  double _repeatScore(MediaItem t) => (habits[t.key]?.recent ?? 0) + 0.3 * _liking(t);

  /// Liked songs you haven't heard in a while.
  Mix forgottenFavorites(int nowMs, {int size = 30}) {
    final list = [
      for (final t in library)
        if (habits[t.key] case final s?)
          if (s.completes >= 2 && nowMs - s.lastPlayedMs > 30 * _dayMs && s.skips * 2 < s.plays)
            (t, s.completes + random.nextDouble()),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    return Mix('habit:forgotten', 'Forgotten Favorites', "Songs you loved but haven't played in a month+",
        Icons.history, spreadArtists([for (final e in list.take(size)) e.$1]));
  }

  /// Fits what you usually play at this time of day.
  Mix rightNow(int hour, {int size = 30}) {
    final moodWeight = <Mood, double>{};
    for (final t in library) {
      final fit = habits.hourFit(t.key, hour);
      if (fit <= 0) continue;
      MoodModel.scores(features[t.key], t.genre).forEach((m, v) => moodWeight[m] = (moodWeight[m] ?? 0) + fit * v);
    }
    final total = moodWeight.values.fold(0.0, (a, b) => a + b);
    final scored = [
      for (final t in library)
        (
          t,
          1.2 * habits.hourFit(t.key, hour) +
              0.6 *
                  (total > 0
                      ? MoodModel.scores(features[t.key], t.genre)
                              .entries
                              .fold(0.0, (a, e) => a + e.value * (moodWeight[e.key] ?? 0)) /
                          total
                      : 0.0) +
              0.2 * _liking(t) -
              0.5 * habits.skipRate(t.key) +
              random.nextDouble() * 0.15
        ),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    final label = switch (hour) {
      >= 5 && <= 11 => 'Morning',
      >= 12 && <= 16 => 'Afternoon',
      >= 17 && <= 21 => 'Evening',
      _ => 'Late Night',
    };
    return Mix('habit:now', '$label Mix', 'Based on what you play around this time', Icons.schedule,
        spreadArtists([for (final e in scored.take(size)) e.$1]));
  }

  /// Never played, newest first.
  Mix freshFinds({int size = 40}) {
    final list = library.where((t) => habits[t.key] == null).toList()
      ..sort((a, b) => b.addedSec.compareTo(a.addedSec));
    return Mix('habit:fresh', 'Fresh Finds', 'In your library but never played', Icons.fiber_new,
        spreadArtists(list.take(size).toList()));
  }

  /// Songs that sound like [seed], weighted toward ones you like.
  Mix soundsLike(MediaItem seed, {int size = 30}) {
    final sf = features[seed.key];
    final sp = sf == null ? null : MoodModel.point(sf);
    final scored = [
      for (final t in library)
        if (t.key != seed.key) (t, _likeScore(seed, sf, sp, t)),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    return Mix('like:${seed.key}', 'Like "${seed.title}"', 'Songs that sound similar', Icons.graphic_eq,
        [seed, ...spreadArtists([for (final e in scored.take(size - 1)) e.$1])]);
  }

  double _likeScore(MediaItem seed, SoundFeatures? sf, MoodPoint? sp, MediaItem t) {
    final f = features[t.key];
    var score = 0.0;
    if (sf != null && f != null && sp != null) {
      final p = MoodModel.point(f);
      final d = (p.arousal - sp.arousal).abs() + (p.valence - sp.valence).abs();
      final tempoClose = sf.tempoBpm > 0 && f.tempoBpm > 0
          ? 1 - ((math.log(f.tempoBpm / sf.tempoBpm)).abs() / math.ln2).clamp(0.0, 1.0)
          : 0.5;
      score = 1.2 - d + 0.3 * tempoClose;
    }
    if (seed.artist.trim().isNotEmpty && t.artist.toLowerCase() == seed.artist.toLowerCase()) score += 0.25;
    if (seed.genre.trim().isNotEmpty && t.genre.toLowerCase() == seed.genre.toLowerCase()) score += 0.2;
    return score + 0.15 * _liking(t) + random.nextDouble() * 0.1;
  }

  /// Every mix worth showing (3 songs or more).
  List<Mix> all(int nowMs, int hour) => [
        rightNow(hour),
        onRepeat(),
        forgottenFavorites(nowMs),
        freshFinds(),
        for (final m in Mood.values) moodMix(m),
      ].where((m) => m.items.length >= 3).toList();

  /// Orders songs so energy changes gently instead of jumping around.
  List<MediaItem> flow(List<MediaItem> list, {required bool rising}) {
    if (list.length < 3) return list;
    final withE = [for (final t in list) (t, features[t.key]?.energy ?? 0.5)]
      ..sort((a, b) => rising ? a.$2.compareTo(b.$2) : b.$2.compareTo(a.$2));
    final out = <MediaItem>[];
    for (var i = 0; i < withE.length; i += 4) {
      final chunk = [for (final e in withE.sublist(i, math.min(i + 4, withE.length))) e.$1]..shuffle(random);
      out.addAll(chunk);
    }
    return spreadArtists(out);
  }

  /// Avoids the same artist twice in a row where possible.
  static List<MediaItem> spreadArtists(List<MediaItem> list) {
    final pool = List.of(list);
    final out = <MediaItem>[];
    while (pool.isNotEmpty) {
      final last = out.isEmpty ? null : out.last.artist.toLowerCase();
      final idx = pool.indexWhere((t) => last == null || t.artist.trim().isEmpty || t.artist.toLowerCase() != last);
      out.add(pool.removeAt(idx >= 0 ? idx : 0));
    }
    return out;
  }
}

// ======================================================================
// Auto Mixes: history + analysis + the current set of mixes

class AutoMixes extends ChangeNotifier {
  AutoMixes._() {
    unawaited(_load());
  }
  static final instance = AutoMixes._();
  static const _ch = MethodChannel('desk/library');
  static const _maxEvents = 8000;

  List<PlayEvent> events = [];
  Map<String, SoundFeatures> features = {};

  /// Songs analysed so far, by key, with the file size seen (so a changed
  /// file gets listened to again). Songs that couldn't be read are in here
  /// too, without features.
  Map<String, int> _done = {};

  bool loaded = false;
  bool analysing = false;
  bool paused = false;
  int analysisDone = 0;
  int analysisTotal = 0;

  List<Mix>? _mixes;
  File? _historyFile, _soundFile;
  Timer? _saveSound;

  Future<void> _load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _historyFile = File('${dir.path}/listening_history.json');
      _soundFile = File('${dir.path}/sound_features.json');
      if (await _historyFile!.exists()) {
        final j = jsonDecode(await _historyFile!.readAsString());
        if (j is List) events = [for (final e in j) PlayEvent.fromJson(e)].whereType<PlayEvent>().toList();
      }
      if (await _soundFile!.exists()) {
        final j = jsonDecode(await _soundFile!.readAsString());
        if (j is Map) {
          j.forEach((k, v) {
            if (v is! Map) return;
            _done['$k'] = (v['size'] as num? ?? 0).toInt();
            final f = SoundFeatures.fromJson(v['f']);
            if (f != null) features['$k'] = f;
          });
        }
      }
    } catch (_) {}
    loaded = true;
    notifyListeners();
  }

  // ------------------------------------------------------------ history

  /// Called by the player when a song stops (finished, skipped or replaced).
  void record(PlayEvent e) {
    events.add(e);
    if (events.length > _maxEvents) events = events.sublist(events.length - _maxEvents);
    unawaited(_write(_historyFile, jsonEncode([for (final e in events) e.toJson()])));
  }

  Future<void> _write(File? f, String text) async {
    if (f == null) return;
    try {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(f.path);
    } catch (_) {}
  }

  // ------------------------------------------------------------ analysis

  /// Listens to every song not analysed yet, one at a time, in the background.
  Future<void> analyse(List<MediaItem> songs) async {
    if (analysing || kIsWeb || !Platform.isAndroid) return;
    while (!loaded) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final todo = songs.where((s) => s.uri.isNotEmpty && !s.video && _done[s.key] != s.sizeBytes).toList();
    if (todo.isEmpty) return;
    analysing = true;
    paused = false;
    analysisDone = 0;
    analysisTotal = todo.length;
    notifyListeners();
    var sinceNotify = 0;
    for (final s in todo) {
      if (paused) break;
      SoundFeatures? f;
      try {
        f = SoundFeatures.fromJson(await _ch.invokeMethod<Map>('analyze', {'uri': s.uri, 'duration': s.durationMs}));
      } catch (_) {}
      _done[s.key] = s.sizeBytes;
      if (f != null) features[s.key] = f;
      analysisDone++;
      _queueSoundSave();
      if (++sinceNotify >= 10) {
        sinceNotify = 0;
        notifyListeners();
      }
    }
    analysing = false;
    _mixes = null; // fresh mixes with the new moods
    notifyListeners();
  }

  void pause() {
    paused = true;
    notifyListeners();
  }

  void _queueSoundSave() {
    _saveSound?.cancel();
    _saveSound = Timer(const Duration(seconds: 3), () {
      final out = <String, Object>{
        for (final e in _done.entries)
          e.key: {'size': e.value, if (features[e.key] != null) 'f': features[e.key]!.toJson()},
      };
      unawaited(_write(_soundFile, jsonEncode(out)));
    });
  }

  // ------------------------------------------------------------ mixes

  MixMaker maker(List<MediaItem> songs) =>
      MixMaker(songs, features, Habits(events, DateTime.now().millisecondsSinceEpoch));

  /// The current mixes. They stay the same until [refresh], so the list
  /// doesn't reshuffle while you look at it.
  List<Mix> mixes(List<MediaItem> songs) {
    final now = DateTime.now();
    return _mixes ??= maker(songs).all(now.millisecondsSinceEpoch, now.hour);
  }

  void refresh() {
    _mixes = null;
    notifyListeners();
  }

  Mix soundsLike(List<MediaItem> songs, MediaItem seed) => maker(songs).soundsLike(seed);

  /// The mood a song sounds most like, or null if it hasn't been listened to.
  Mood? moodOf(MediaItem m) {
    final f = features[m.key];
    if (f == null) return null;
    final s = MoodModel.scores(f, m.genre);
    return s.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }
}
