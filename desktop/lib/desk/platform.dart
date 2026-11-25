import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidApp {
  final String label;
  final String package;
  final Uint8List icon;
  AndroidApp(this.label, this.package, this.icon);
}

/// The desktop's calls into Android (see DeskBridge.kt).
class DeskPlatform {
  static const _ch = MethodChannel('desk/platform');

  static Future<List<AndroidApp>> listApps() async {
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('listApps') ?? const [];
      return raw.map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        final icon = m['icon'];
        return AndroidApp(m['label'] as String? ?? '', m['package'] as String? ?? '',
            icon is Uint8List ? icon : Uint8List(0));
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<bool> launch(String package) async {
    try {
      return await _ch.invokeMethod<bool>('launchApp', {'package': package}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Android's "Default home app" picker.
  static Future<void> homeSettings() async {
    try {
      await _ch.invokeMethod('homeSettings');
    } catch (_) {}
  }

  /// Shortcuts typed while a web page had the keyboard (see DeskBridge.kt).
  static void listenForShortcuts(void Function(String name, bool shift) onShortcut) {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'shortcut') {
        final m = Map<String, dynamic>.from(call.arguments as Map);
        onShortcut(m['name'] as String? ?? '', m['shift'] as bool? ?? false);
      }
      return null;
    });
  }

  /// Gives the keyboard back to the desktop (away from a web page).
  static Future<void> focusDesktop() async {
    try {
      await _ch.invokeMethod('focusDesktop');
    } catch (_) {}
  }

  /// Closes the whole app (or restarts it).
  static Future<void> shutdown({bool restart = false}) async {
    try {
      await _ch.invokeMethod('shutdown', {'restart': restart});
    } catch (_) {}
  }

  static Future<bool> isDefaultHome() async {
    try {
      return await _ch.invokeMethod<bool>('isDefaultHome') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Tells Android whether a browser window is active, so Ctrl+T/W/L, F5
  /// and Alt+Left/Right are passed over while a web page has the keyboard.
  static Future<void> setBrowserKeys(bool on) async {
    try {
      await _ch.invokeMethod('setBrowserKeys', {'on': on});
    } catch (_) {}
  }

  /// Whether the file browser may see the whole device ("All files access").
  static Future<bool> hasAllFiles() async {
    try {
      return await _ch.invokeMethod<bool>('hasAllFiles') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens Android's "All files access" switch for the desktop.
  static Future<void> askAllFiles() async {
    try {
      await _ch.invokeMethod('askAllFiles');
    } catch (_) {}
  }

  static Future<String> storageRoot() async {
    try {
      return await _ch.invokeMethod<String>('storageRoot') ?? '/storage/emulated/0';
    } catch (_) {
      return '/storage/emulated/0';
    }
  }

  /// Internal storage, SD cards, USB drives.
  static Future<List<StorageVolume>> volumes() async {
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('volumes') ?? const [];
      return raw.map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return StorageVolume(m['name'] as String? ?? 'Drive', m['path'] as String? ?? '/', m['removable'] as bool? ?? false);
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Opens a file in another app: [package] if given (falls back to the
  /// "Open with" chooser). False if nothing could open it.
  static Future<bool> openWith(String path, {String? package}) async {
    try {
      return await _ch.invokeMethod<bool>('openWith', {'path': path, 'package': package}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Starts [package] as a floating window covering [bounds] (in screen
  /// pixels). Only sized when Android's desktop / freeform windows are on.
  static Future<bool> launchBounded(String package, {String? url, required Rect bounds}) async {
    try {
      return await _ch.invokeMethod<bool>('launchBounded', {
            'package': package,
            'url': url,
            'left': bounds.left.round(),
            'top': bounds.top.round(),
            'right': bounds.right.round(),
            'bottom': bounds.bottom.round(),
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }
}

class StorageVolume {
  final String name;
  final String path;
  final bool removable;
  const StorageVolume(this.name, this.path, this.removable);
}

/// Installed Android apps, loaded once and refreshed when asked.
class AppList extends ChangeNotifier {
  List<AndroidApp> apps = const [];
  bool loaded = false;
  bool _loading = false;

  Future<void> load({bool force = false}) async {
    if (_loading || (loaded && !force)) return;
    _loading = true;
    apps = await DeskPlatform.listApps();
    loaded = true;
    _loading = false;
    notifyListeners();
  }

  /// Finds an app by name the way the Run box needs: exact label, then
  /// package name, then the first label starting with [name].
  AndroidApp? find(String name) {
    final n = name.trim().toLowerCase();
    if (n.isEmpty) return null;
    for (final a in apps) {
      if (a.label.toLowerCase() == n) return a;
    }
    for (final a in apps) {
      if (a.package.toLowerCase() == n) return a;
    }
    for (final a in apps) {
      if (a.label.toLowerCase().startsWith(n)) return a;
    }
    return null;
  }
}
