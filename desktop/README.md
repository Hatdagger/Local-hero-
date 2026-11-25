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
sizing), Alt+F4, Win (Start), Win+M, Shift+Win+M, Win+D, Win+R (Run).

Run box understands: `aim`, `display`, website addresses, and installed app names.
