import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'window_manager.dart';

/// One window that was open when the desktop last stopped.
class SavedWindow {
  final String reopen;
  final Rect rect;
  final bool maximized;
  final bool minimized;
  final bool active;
  const SavedWindow(this.reopen, this.rect, {this.maximized = false, this.minimized = false, this.active = false});

  Map<String, Object?> toJson() => {
        'reopen': reopen,
        'rect': rectToJson(rect),
        if (maximized) 'max': true,
        if (minimized) 'min': true,
        if (active) 'active': true,
      };

  static SavedWindow? fromJson(Object? j) {
    if (j is! Map) return null;
    final reopen = j['reopen'];
    final rect = rectFromJson(j['rect']);
    if (reopen is! String || rect == null) return null;
    return SavedWindow(reopen, rect, maximized: j['max'] == true, minimized: j['min'] == true, active: j['active'] == true);
  }
}

List<double> rectToJson(Rect r) => [r.left, r.top, r.width, r.height].map((v) => (v * 10).roundToDouble() / 10).toList();

Rect? rectFromJson(Object? j) {
  if (j is! List || j.length != 4 || j.any((v) => v is! num)) return null;
  final v = [for (final x in j) (x as num).toDouble()];
  if (v[2] <= 0 || v[3] <= 0) return null;
  return Rect.fromLTWH(v[0], v[1], v[2], v[3]);
}

/// Pure save/load helpers (tested in test/session_test.dart).
class SessionCodec {
  static String encodeWindows(List<SavedWindow> list) => jsonEncode([for (final w in list) w.toJson()]);

  static List<SavedWindow> decodeWindows(String? raw) {
    if (raw == null) return [];
    try {
      final v = jsonDecode(raw);
      if (v is! List) return [];
      return [for (final j in v) if (SavedWindow.fromJson(j) case final w?) w];
    } catch (_) {
      return [];
    }
  }

  static String encodeBounds(Map<String, SavedBounds> m) => jsonEncode({
        for (final e in m.entries) e.key: {'rect': rectToJson(e.value.rect), if (e.value.maximized) 'max': true},
      });

  static Map<String, SavedBounds> decodeBounds(String? raw) {
    if (raw == null) return {};
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return {};
      return {
        for (final e in v.entries)
          if (e.value is Map)
            if (rectFromJson((e.value as Map)['rect']) case final r?)
              e.key as String: SavedBounds(r, (e.value as Map)['max'] == true),
      };
    } catch (_) {
      return {};
    }
  }

  /// The windows worth reopening, bottom to top. [reopenOf] gives a window's
  /// reopen string (or null to leave it out).
  static List<SavedWindow> snapshot(List<DeskWindow> zOrder, String? activeId, String? Function(DeskWindow) reopenOf) => [
        for (final w in zOrder)
          if (reopenOf(w) case final r?)
            SavedWindow(r, w.rect, maximized: w.maximized, minimized: w.minimized, active: w.id == activeId),
      ];
}

/// Remembers where windows are, and which were open, across restarts
/// (updates, Restart, Android closing the app).
class DeskSession {
  DeskSession(this.wm, {required this.reopen, required this.reopenOf});

  final WindowManager wm;

  /// Opens a window from its reopen string; null if it can't any more.
  final DeskWindow? Function(String spec) reopen;

  /// The reopen string for an open window, or null.
  final String? Function(DeskWindow w) reopenOf;

  bool _ready = false;
  Timer? _timer;

  /// Loads the remembered places and opens last time's windows. Call once
  /// the desktop has its size.
  Future<void> restore() async {
    if (_ready) return;
    try {
      final p = await SharedPreferences.getInstance();
      wm.savedBounds.addAll(SessionCodec.decodeBounds(p.getString('winBounds')));
      final saved = SessionCodec.decodeWindows(p.getString('winSession'));
      String? active;
      for (final s in saved) {
        DeskWindow? w;
        try {
          w = reopen(s.reopen);
        } catch (_) {}
        if (w == null) continue;
        wm.placeRestored(w, s.rect, maximized: s.maximized, minimized: s.minimized);
        if (s.active && !s.minimized) active = w.id;
      }
      if (active != null) wm.focus(active);
    } catch (_) {}
    _ready = true;
    wm.addListener(_changed);
  }

  void _changed() {
    if (!_ready) return;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 800), () => unawaited(save()));
  }

  Future<void> save() async {
    if (!_ready) return;
    final order = wm.zOrder;
    for (final w in order) {
      wm.rememberBounds(w);
    }
    final p = await SharedPreferences.getInstance();
    await p.setString('winBounds', SessionCodec.encodeBounds(wm.savedBounds));
    await p.setString('winSession', SessionCodec.encodeWindows(SessionCodec.snapshot(order, wm.activeId, reopenOf)));
  }
}
