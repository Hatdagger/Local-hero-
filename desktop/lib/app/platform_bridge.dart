import 'dart:io';

import 'package:flutter/services.dart';

/// Android-only helpers implemented in MainActivity.kt / AimConnectionService.kt:
/// a foreground service that keeps the connection alive while backgrounded,
/// and a detail-free "new messages" notification.
class PlatformBridge {
  static const _ch = MethodChannel('aim/platform');
  static bool get _android => Platform.isAndroid;

  static Future<void> startKeepAlive(String text) async {
    if (!_android) return;
    try {
      await _ch.invokeMethod('startService', {'text': text});
    } catch (_) {}
  }

  static Future<void> stopKeepAlive() async {
    if (!_android) return;
    try {
      await _ch.invokeMethod('stopService');
    } catch (_) {}
  }

  /// Shows "You have N new AIM messages" with no sender or preview.
  static Future<void> showUnread(int count) async {
    if (!_android) return;
    try {
      await _ch.invokeMethod('notifyUnread', {'count': count});
    } catch (_) {}
  }

  static Future<void> clearUnread() async {
    if (!_android) return;
    try {
      await _ch.invokeMethod('clearUnread');
    } catch (_) {}
  }

  /// A short "key click" you can feel. [pad] = the press came from a game
  /// controller, so rumble the controller instead of the phone.
  static void keyClick({bool pad = false}) {
    if (_android) {
      _ch.invokeMethod('keyClick', {'pad': pad}).catchError((_) {
        HapticFeedback.selectionClick();
      });
    } else if (!pad) {
      HapticFeedback.selectionClick(); // no-op on most desktops
    }
  }

  /// Opens a web link in the browser (downloads go to the browser too).
  static Future<void> openUrl(String url) async {
    try {
      if (_android) {
        await _ch.invokeMethod('openUrl', {'url': url});
      } else if (Platform.isWindows) {
        await Process.run('explorer', [url]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else {
        await Process.run('xdg-open', [url]);
      }
    } catch (_) {}
  }

  // ------------------------------------------------------------ received files

  /// This device's own network addresses, Wi-Fi first (Android only; empty
  /// elsewhere, where Dart can list them itself).
  static Future<List<String>> localAddresses() async {
    if (!_android) return const [];
    try {
      final l = await _ch.invokeMethod<List<dynamic>>('localAddresses');
      return [for (final a in l ?? const []) a as String];
    } catch (_) {
      return const [];
    }
  }

  /// Android 11+: the public Download folder, which apps may write to
  /// directly. Null where it can't be written (older Android, desktops).
  static Future<String?> publicDownloads() async {
    if (!_android) return null;
    try {
      return await _ch.invokeMethod<String>('publicDownloads');
    } catch (_) {
      return null;
    }
  }

  /// Android 10: copies a received file into Download/AIM through Android's
  /// media store. Returns its content:// address, or null.
  static Future<String?> saveToDownloads(String path, String name) async {
    if (!_android) return null;
    try {
      return await _ch.invokeMethod<String>('saveToDownloads', {'path': path, 'name': name});
    } catch (_) {
      return null;
    }
  }

  /// Lets Android's Files / Downloads apps see a file saved in a public folder.
  static Future<void> scanFile(String path) async {
    if (!_android) return;
    try {
      await _ch.invokeMethod('scanFile', {'path': path});
    } catch (_) {}
  }

  /// Opens a received file in whatever app handles it. [where] is a file
  /// path or a content:// address. False if nothing could open it.
  static Future<bool> openFile(String where) async {
    try {
      if (_android) return await _ch.invokeMethod<bool>('openFile', {'where': where}) ?? false;
      if (Platform.isWindows) {
        await Process.run('explorer', [where]);
        return true; // explorer's exit code isn't meaningful
      }
      final r = await Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [where]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------ in-app updates

  /// Android's installer said no (message from Android).
  static void Function(String message)? onInstallFailed;

  /// The app came back to the front (e.g. from the "allow installs" switch).
  static void Function()? onResumed;

  /// Whether Android lets AIM install its own updates yet.
  static Future<bool> canInstallUpdates() async {
    if (!_android) return true;
    try {
      return await _ch.invokeMethod<bool>('canInstallUpdates') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens Android's one-time "Allow from this source" switch for AIM.
  static Future<void> allowInstallUpdates() async {
    if (!_android) return;
    await _ch.invokeMethod('allowInstallUpdates');
  }

  /// Hands a downloaded APK to Android's installer (it shows its own prompt).
  static Future<void> installApk(String path) async {
    await _ch.invokeMethod('installApk', {'path': path});
  }

  static Future<void> requestNotificationPermission() async {
    if (!_android) return;
    try {
      await _ch.invokeMethod('requestNotificationPermission');
    } catch (_) {}
  }

  /// Opens the system prompt to exempt the app from battery optimisation so
  /// the connection survives with the screen off.
  static Future<void> requestBackgroundRunning() async {
    if (!_android) return;
    try {
      await _ch.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }
}
