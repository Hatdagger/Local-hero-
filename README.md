# Local Hero

A music player for Android that plays the music already on your device, tidies up messy
libraries, and makes playlists from your habits and the *sound* of your songs. No account, no
internet, nothing leaves the device.

## Get the app
Every push builds an APK: open the **Actions** tab → latest run → download **Local-Hero-apk**,
unzip, install `Local-Hero.apk`. Needs Android 11 or newer.

## What it does
- **Library** – browse by songs, albums, artists, genres, folders or mood. Search, sort, hold a
  song for options (play next, add to playlist, set mood, songs like this, info).
- **Player** – background playback with notification and lock-screen controls, gapless, shuffle,
  repeat, queue editing, sleep timer, headphone-unplug pause, remembers where you left off.
- **Mixes** – the app listens to each song once (tempo, energy, brightness, key, major/minor) and
  works out its mood: Energetic, Upbeat, Chill, Melancholy, Intense, Focus. It also learns from
  what you finish and skip and when you listen: *Morning/Evening mix*, *On repeat*, *Forgotten
  favourites*, *Fresh finds*, *Like this song*. Save any mix as a playlist.
- **Playlists** – make, rename, reorder, delete.
- **Tidy**
  - *Duplicates*: exact copies, the same song in different folders, and files that sound
    identical. Keeps the best copy (★); ticked extras go to the system trash (restorable for 30 days).
  - *Fix names*: spots "Track 01", "<unknown>", website junk, "(Official Video)", "copy (2)",
    underscores and ALL CAPS, and guesses the real artist/title from tags, file name and folder.
    Rename files to "Artist - Title", optionally sort into `Music/Artist/Album/`, or just fix the
    names inside the app. Hold an entry to correct a guess.
  - *Undo*: put renamed/moved files back.

## Layout
- `app/src/main/java/com/hatdagger/localhero/core/` – plain Kotlin, unit-tested: audio analysis
  (`Analysis.kt`), moods, habits + mixes (`Mixes.kt`), name cleanup + duplicates (`Tidy.kt`),
  sorting/grouping (`Library.kt`).
- `.../android/` – `MainActivity` (all screens), `PlayerService` (+ `Playback` state),
  `Hero` (library scan, MediaCodec decoding, background analysis), `Store` (SQLite),
  `FileOps` (trash/rename via MediaStore), `Ui` (styling + list adapter).
