# Local Hero handover

**Repo:** https://github.com/Hatdagger/local-hero- (branch `main`, v0.1). Every push builds an APK
(Actions tab, artifact **Local-Hero-apk**). Package id `com.hatdagger.localhero`, minSdk 30.

**What it is:** Android music player for local files (Kotlin, no AndroidX, plain views, framework
MediaPlayer + MediaSession). Library browsing, playback service, audio-analysis moods, habit
mixes, playlists, and a Tidy section for duplicates and messy names.

**User:** not a programmer; wants plain-language updates. Allowed to push to `main`.
Test device: Lenovo Legion Tab Y700 Gen 2.

## Layout
- `core/` (pure Kotlin, 11 JUnit tests): `Analysis.kt` (FFT; tempo via onset autocorrelation +
  octave fix; energy; brightness; Krumhansl key/mode; 29-value "sound print"; `MoodModel`
  arousal/valence → 6 moods + genre hints + user override), `Mixes.kt` (`Habits`: 45-day decay,
  skip = <30 s or <25%; `MixMaker`: mood mixes, Right now, On repeat, Forgotten favourites,
  Fresh finds, Sounds like), `Tidy.kt` (`Names` cleanup/filename guessing, `NameFixer.plan`,
  `Duplicates.find`: exact size, name+length, sounds-identical), `Library.kt`.
- `android/`: `MainActivity` (tabs Library/Mixes/Playlists/Tidy, mini player, now-playing overlay,
  side-by-side in landscape), `PlayerService` + `Playback` object (gapless via setNextMediaPlayer,
  focus, noisy, notification, sleep timer, queue saved in prefs), `Hero` (MediaStore scan,
  MediaCodec decode of 40 s from 30% in, background analysis thread), `Store` (SQLite: plays,
  features, moods, playlists, overrides, renames), `FileOps` (createTrashRequest /
  createWriteRequest + MediaStore DISPLAY_NAME/RELATIVE_PATH updates), `Ui`.
- Cleaned names are stored as in-app overrides; file tags are never rewritten.
- Local tests: `tools/run-core-tests.sh` (Gradle's bundled Kotlin compiler + JUnit). No Android
  SDK locally; Android code is checked by the GitHub build (`gh run list -R Hatdagger/local-hero-`).

## Status
- v0.1 builds. Nothing tested on the device yet.

## Ideas not done
Write real ID3/FLAC tags, MusicBrainz lookups for unknown songs, album-art grid, equalizer,
M3U import/export, home-screen widget, Android Auto.
