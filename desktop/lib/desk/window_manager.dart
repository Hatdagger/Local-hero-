import 'dart:math' as math;

import 'package:flutter/widgets.dart';

typedef WindowContent = Widget Function(BuildContext context, DeskWindow w);

/// One window on the desktop.
class DeskWindow {
  DeskWindow({
    required this.id,
    required this.title,
    required this.icon,
    required this.content,
    Size size = const Size(420, 320),
    this.minSize = const Size(180, 120),
    this.resizable = true,
    this.canMaximize = true,
    this.canMinimize = true,
    this.onClose,
  }) : rect = Offset.zero & size;

  final String id;
  String title;
  IconData icon;
  final WindowContent content;
  Rect rect;
  Rect? restoreRect;
  bool minimized = false;
  bool maximized = false;

  /// Wants attention (orange taskbar button), like a new IM.
  bool flashing = false;
  final Size minSize;
  final bool resizable;
  final bool canMaximize;
  final bool canMinimize;

  /// Runs after the window has closed.
  final VoidCallback? onClose;

  /// Remembers which field inside the window had the keyboard.
  final FocusScopeNode focus = FocusScopeNode(debugLabel: 'window');
}

enum KbMode { none, move, size }

/// Edges for resizing.
class Edge {
  static const left = 1, top = 2, right = 4, bottom = 8;
}

/// Keeps the windows, their stacking order and which one is active, plus the
/// desktop-wide popups (Start menu, Alt+Tab, the Alt+Space window menu).
class WindowManager extends ChangeNotifier {
  /// Bottom to top.
  final List<DeskWindow> _z = [];

  /// Order the windows were opened in (taskbar order).
  final List<DeskWindow> _opened = [];

  /// Most recently used first (Alt+Tab order).
  final List<String> _mru = [];

  /// Area windows live in (screen minus the taskbar). Set by the shell.
  Size desk = const Size(1280, 720);

  String? activeId;
  bool startOpen = false;

  String? menuFor;
  int menuIndex = 0;

  KbMode kbMode = KbMode.none;
  Rect? _kbStart;

  /// Selected entry in the Alt+Tab popup, or null when it is closed.
  int? switcherIndex;

  List<String>? _minimizedAll;
  int _cascade = 0;

  List<DeskWindow> get zOrder => List.unmodifiable(_z);
  List<DeskWindow> get taskOrder => List.unmodifiable(_opened);

  DeskWindow? byId(String id) {
    for (final w in _z) {
      if (w.id == id) return w;
    }
    return null;
  }

  DeskWindow? get active => activeId == null ? null : byId(activeId!);

  bool isOpen(String id) => byId(id) != null;

  /// Where a window is drawn right now.
  Rect shownRect(DeskWindow w) => w.maximized ? Offset.zero & desk : w.rect;

  // ------------------------------------------------------------ open/close

  /// Opens [w], or brings up the window that already has its id.
  /// With [activate] false the window opens behind the active one and
  /// flashes on the taskbar (like an IM arriving while you type elsewhere).
  DeskWindow open(DeskWindow w, {bool activate = true, Offset? at}) {
    final existing = byId(w.id);
    if (existing != null) {
      if (activate) {
        focus(existing.id);
      } else if (existing.id != activeId) {
        existing.flashing = true;
        notifyListeners();
      }
      return existing;
    }
    final size = Size(math.min(w.rect.width, desk.width), math.min(w.rect.height, desk.height));
    Offset pos;
    if (at != null) {
      pos = at;
    } else {
      final step = 26.0 * (_cascade % 8);
      _cascade++;
      pos = Offset(60 + step, 40 + step);
    }
    w.rect = _fit(pos & size);
    _opened.add(w);
    if (activate || _z.isEmpty || activeId == null) {
      _z.add(w);
      _mru.insert(0, w.id);
      _activate(w);
    } else {
      // Just under the active window.
      final a = active;
      final i = a == null ? _z.length : _z.indexOf(a);
      _z.insert(i, w);
      _mru.insert(math.min(1, _mru.length), w.id);
      w.flashing = true;
    }
    notifyListeners();
    return w;
  }

  void close(String id) {
    final w = byId(id);
    if (w == null) return;
    _z.remove(w);
    _opened.remove(w);
    _mru.remove(id);
    if (menuFor == id) menuFor = null;
    if (activeId == id) {
      activeId = null;
      kbMode = KbMode.none;
      _activateTopmost();
    }
    notifyListeners();
    w.onClose?.call();
    WidgetsBinding.instance.addPostFrameCallback((_) => w.focus.dispose());
  }

  void closeWhere(bool Function(DeskWindow w) test) {
    for (final w in _z.where(test).toList()) {
      close(w.id);
    }
  }

  // ------------------------------------------------------------ focus

  void focus(String id) {
    final w = byId(id);
    if (w == null) return;
    w.minimized = false;
    _minimizedAll = null;
    _z.remove(w);
    _z.add(w);
    _mru.remove(id);
    _mru.insert(0, id);
    startOpen = false;
    _activate(w);
    notifyListeners();
  }

  void _activate(DeskWindow w) {
    activeId = w.id;
    w.flashing = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        if (activeId == w.id) w.focus.requestFocus();
      } catch (_) {}
    });
  }

  void _activateTopmost() {
    for (final w in _z.reversed) {
      if (!w.minimized) {
        _activate(w);
        return;
      }
    }
    activeId = null;
  }

  /// Clicking a taskbar button: minimizes the active window, otherwise
  /// brings that window up.
  void taskbarClick(String id) {
    final w = byId(id);
    if (w == null) return;
    if (id == activeId && !w.minimized) {
      minimize(id);
    } else {
      focus(id);
    }
  }

  void flash(String id) {
    final w = byId(id);
    if (w == null || id == activeId) return;
    w.flashing = true;
    notifyListeners();
  }

  // ------------------------------------------------------------ min/max

  void minimize(String id) {
    final w = byId(id);
    if (w == null || !w.canMinimize) return;
    w.minimized = true;
    if (menuFor == id) menuFor = null;
    if (activeId == id) {
      activeId = null;
      _activateTopmost();
    }
    notifyListeners();
  }

  void toggleMaximize(String id) {
    final w = byId(id);
    if (w == null) return;
    if (w.maximized) {
      restore(id);
    } else {
      maximize(id);
    }
  }

  void maximize(String id) {
    final w = byId(id);
    if (w == null || !w.canMaximize) return;
    w.maximized = true;
    w.minimized = false;
    notifyListeners();
  }

  void restore(String id) {
    final w = byId(id);
    if (w == null) return;
    if (w.minimized) {
      focus(id);
      return;
    }
    w.maximized = false;
    notifyListeners();
  }

  /// Win+M.
  void minimizeAll() {
    final visible = _z.where((w) => !w.minimized && w.canMinimize).map((w) => w.id).toList();
    for (final w in _z) {
      if (w.canMinimize) w.minimized = true;
    }
    _minimizedAll = visible;
    activeId = null;
    menuFor = null;
    _activateTopmost();
    notifyListeners();
  }

  /// Shift+Win+M.
  void undoMinimizeAll() {
    final list = _minimizedAll;
    if (list == null) return;
    for (final id in list) {
      byId(id)?.minimized = false;
    }
    _minimizedAll = null;
    final top = list.isEmpty ? null : list.last;
    if (top != null) {
      focus(top);
    } else {
      notifyListeners();
    }
  }

  /// Win+D: shows the desktop, or puts the windows back.
  void showDesktop() {
    if (_minimizedAll != null && _z.every((w) => w.minimized || !w.canMinimize)) {
      undoMinimizeAll();
    } else {
      minimizeAll();
    }
  }

  // ------------------------------------------------------------ move/size

  Rect _fit(Rect r) {
    // Keep the title bar reachable.
    var dx = r.left, dy = r.top;
    dx = dx.clamp(-r.width + 60, math.max(0.0, desk.width - 60)).toDouble();
    dy = dy.clamp(0.0, math.max(0.0, desk.height - 30)).toDouble();
    return Offset(dx, dy) & r.size;
  }

  void moveBy(String id, Offset delta) {
    final w = byId(id);
    if (w == null || w.maximized) return;
    w.rect = _fit(w.rect.shift(delta));
    notifyListeners();
  }

  void resizeBy(String id, int edges, Offset d) {
    final w = byId(id);
    if (w == null || w.maximized || !w.resizable) return;
    var l = w.rect.left, t = w.rect.top, r = w.rect.right, b = w.rect.bottom;
    if (edges & Edge.left != 0) l = math.min(l + d.dx, r - w.minSize.width);
    if (edges & Edge.right != 0) r = math.max(r + d.dx, l + w.minSize.width);
    if (edges & Edge.top != 0) t = math.max(0.0, math.min(t + d.dy, b - w.minSize.height));
    if (edges & Edge.bottom != 0) b = math.max(b + d.dy, t + w.minSize.height);
    w.rect = Rect.fromLTRB(l, t, r, b);
    notifyListeners();
  }

  // ------------------------------------------------------------ Alt+Space menu

  void openMenu(String id) {
    final w = byId(id);
    if (w == null) return;
    if (activeId != id) focus(id);
    menuFor = id;
    menuIndex = 0;
    startOpen = false;
    notifyListeners();
  }

  void closeMenu() {
    if (menuFor == null) return;
    menuFor = null;
    notifyListeners();
  }

  /// The window menu's entries for [w]: (label, mnemonic index, enabled).
  List<MenuEntry> menuEntries(DeskWindow w) => [
        MenuEntry('Restore', 0, w.maximized || w.minimized, MenuAction.restore),
        MenuEntry('Move', 0, !w.maximized, MenuAction.move),
        MenuEntry('Size', 0, !w.maximized && w.resizable, MenuAction.size),
        MenuEntry('Minimize', 2, w.canMinimize, MenuAction.minimize),
        MenuEntry('Maximize', 2, w.canMaximize && !w.maximized, MenuAction.maximize),
        MenuEntry('Close', 0, true, MenuAction.close, shortcut: 'Alt+F4', bold: true, separatorBefore: true),
      ];

  void menuMove(int delta) {
    final w = menuFor == null ? null : byId(menuFor!);
    if (w == null) return;
    final items = menuEntries(w);
    var i = menuIndex;
    for (var n = 0; n < items.length; n++) {
      i = (i + delta) % items.length;
      if (i < 0) i += items.length;
      if (items[i].enabled) break;
    }
    menuIndex = i;
    notifyListeners();
  }

  /// Runs the entry whose underlined letter is [ch]. True if one matched.
  bool menuLetter(String ch) {
    final w = menuFor == null ? null : byId(menuFor!);
    if (w == null) return false;
    for (final e in menuEntries(w)) {
      if (e.enabled && e.label[e.mnemonic].toLowerCase() == ch.toLowerCase()) {
        runMenu(e.action);
        return true;
      }
    }
    return false;
  }

  void menuActivate() {
    final w = menuFor == null ? null : byId(menuFor!);
    if (w == null) return;
    final e = menuEntries(w)[menuIndex];
    if (e.enabled) runMenu(e.action);
  }

  void runMenu(MenuAction a) {
    final id = menuFor;
    menuFor = null;
    if (id == null) {
      notifyListeners();
      return;
    }
    switch (a) {
      case MenuAction.restore:
        restore(id);
      case MenuAction.move:
        _startKb(id, KbMode.move);
      case MenuAction.size:
        _startKb(id, KbMode.size);
      case MenuAction.minimize:
        minimize(id);
      case MenuAction.maximize:
        maximize(id);
      case MenuAction.close:
        close(id);
    }
    notifyListeners();
  }

  void _startKb(String id, KbMode mode) {
    final w = byId(id);
    if (w == null) return;
    kbMode = mode;
    _kbStart = w.rect;
  }

  /// Arrow keys while moving or sizing with the keyboard.
  void kbArrow(double dx, double dy) {
    final w = active;
    if (w == null || kbMode == KbMode.none) return;
    if (kbMode == KbMode.move) {
      moveBy(w.id, Offset(dx, dy));
    } else {
      final edges = (dx != 0 ? Edge.right : 0) | (dy != 0 ? Edge.bottom : 0);
      resizeBy(w.id, edges, Offset(dx, dy));
    }
  }

  void kbEnd({required bool keep}) {
    final w = active;
    if (!keep && w != null && _kbStart != null) w.rect = _kbStart!;
    kbMode = KbMode.none;
    _kbStart = null;
    notifyListeners();
  }

  // ------------------------------------------------------------ Alt+Tab

  /// Windows in Alt+Tab order.
  List<DeskWindow> get switchList => _mru.map(byId).whereType<DeskWindow>().toList();

  void startSwitch({bool back = false}) {
    final n = switchList.length;
    if (n == 0) return;
    startOpen = false;
    menuFor = null;
    // The first Alt+Tab goes to the previous window, unless the active one
    // is minimized or there is no active one.
    final first = (activeId == null || n == 1) ? 0 : 1;
    switcherIndex = back ? (n - 1) : first;
    notifyListeners();
  }

  void switchStep({bool back = false}) {
    final n = switchList.length;
    if (switcherIndex == null || n == 0) return;
    switcherIndex = (switcherIndex! + (back ? -1 : 1)) % n;
    if (switcherIndex! < 0) switcherIndex = switcherIndex! + n;
    notifyListeners();
  }

  void commitSwitch() {
    final i = switcherIndex;
    switcherIndex = null;
    final list = switchList;
    if (i != null && i < list.length) {
      focus(list[i].id);
    } else {
      notifyListeners();
    }
  }

  void cancelSwitch() {
    switcherIndex = null;
    notifyListeners();
  }

  // ------------------------------------------------------------ Start menu

  void toggleStart() {
    startOpen = !startOpen;
    menuFor = null;
    notifyListeners();
  }

  void closeStart() {
    if (!startOpen) return;
    startOpen = false;
    notifyListeners();
  }
}

enum MenuAction { restore, move, size, minimize, maximize, close }

class MenuEntry {
  final String label;
  final int mnemonic;
  final bool enabled;
  final MenuAction action;
  final String? shortcut;
  final bool bold;
  final bool separatorBefore;
  const MenuEntry(this.label, this.mnemonic, this.enabled, this.action,
      {this.shortcut, this.bold = false, this.separatorBefore = false});
}
