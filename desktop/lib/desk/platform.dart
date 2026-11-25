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

  static Future<bool> isDefaultHome() async {
    try {
      return await _ch.invokeMethod<bool>('isDefaultHome') ?? false;
    } catch (_) {
      return false;
    }
  }
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
