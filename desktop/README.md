# ClassicDesk

A classic-style desktop for Android tablets in desktop mode (monitor + keyboard + mouse).
It runs as a home screen: windows you can drag and resize, a taskbar, a Start menu, and
AIM built in (buddy list plus one window per conversation).

Built with Flutter. The AIM engine (`lib/app`, `lib/oscar`) is copied from
[Aim-for-android](https://github.com/Hatdagger/Aim-for-android). The desktop itself is in `lib/desk`.

## Getting the APK
Every push that touches `desktop/` builds it: Actions tab, **Build ClassicDesk**, artifact
**ClassicDesk-apk**. The APK is signed with `android_overlay/desk.jks`, so new builds install
over old ones.

## Switching
- Make it the home screen: Start > Choose Home Screen (or Android Settings > Default apps).
- Start > Log Off opens Android's home-app picker to go back to your normal home screen.
- The "Switch to Desktop" widget (add it on your normal home screen) opens the same picker.

## Shortcuts
Alt+Tab, Alt+Shift+Tab, Alt+Space (window menu: R/M/S/N/X/C, arrows + Enter when moving or
sizing), Alt+F4, Win (Start), Win+M, Shift+Win+M, Win+D, Win+R (Run), Win+E (My Computer).

Run box understands: `aim`, `display`, `explorer`, `internet`, `brave`, `downloads`, `music`
(Local Hero mini player), folder paths like `/storage/emulated/0/Download`, website addresses,
and installed app names.

## File browser (My Computer)
Explorer-style windows: address bar, Icons / List / Details views, sort by clicking column
headers, cut/copy/paste, drag files between windows (hold Ctrl to copy), right-click menus,
Recycle Bin (also a drop target on the desktop), F2 rename, Delete (Shift+Delete = permanently),
Backspace = back, Alt+Left/Right/Up, Ctrl+A, F5. Needs Android's "All files access" (asked once;
Tools > Allow Access to All Files). Text files open in Notepad, pictures in a viewer (with
"Set as Desktop Background"), music in Local Hero, web pages and .url shortcuts in the browser.

## Internet
Built-in browser windows with tabs (Ctrl+T / Ctrl+W / Ctrl+L / F5 / Alt+Left / Alt+Right),
favorites and a links bar, downloads into Download (or My Downloads), and basic ad blocking
(Tools > Block Ads). The Brave button opens the page in Brave as a floating window over the
desktop; that only gets sized when Android's desktop / freeform windows are on, and Brave
doesn't appear on the taskbar.

## Local Hero mini player
A small always-on-top window that remote-controls Local Hero (artwork, title, play/pause,
previous/next, seek). It needs notification access once ("ClassicDesk mini player").
