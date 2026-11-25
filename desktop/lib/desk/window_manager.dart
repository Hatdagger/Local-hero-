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
    this.beforeClose,
    this.alwaysOnTop = false,
    this.dockable = false,
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

  /// Stays above ordinary windows (the mini player).
  final bool alwaysOnTop;

  /// Can be docked to the left or right edge of the screen (the Buddy List).
  final bool dockable;

  /// Which screen edge the window is docked to, if any. A docked window runs
  /// the full height of the screen and other windows maximize beside it.
  DockSide dock = DockSide.none;

  /// Runs after the window has closed.
  final VoidCallback? onClose;

  /// Asked before closing; return false to keep the window open (for
  /// example to ask "Save changes?" first).
  bool Function()? beforeClose;

  /// Remembers which field inside the window had the keyboard.
  final FocusScopeNode focus = FocusScopeNode(debugLabel: 'window');
}

enum KbMode { none, move, size }

enum DockSide { none, left, right }

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

  /// Bottom to top, with always-on-top windows above the rest.
  List<DeskWindow> get zOrder =>
      List.unmodifiable([..._z.where((w) => !w.alwaysOnTop), ..._z.where((w) => w.alwaysOnTop)]);
  List<DeskWindow> get taskOrder => List.unmodifiable(_opened);

  DeskWindow? byId(String id) {
    for (final w in _z) {
      if (w.id == id) return w;
    }
    return null;
  }

  DeskWindow? get active => activeId == null ? null : byId(activeId!);

  bool isOpen(String id) => byId(id) != null;

  /// Called whenever a window docks or undocks (to remember the side).
  void Function(DeskWindow w)? onDockChanged;

  /// The docked window on [side], if one is showing.
  DeskWindow? dockedOn(DockSide side) {
    for (final w in _z) {
      if (w.dock == side && !w.minimized) return w;
    }
    return null;
  }

  /// The part of the desk not taken by docked windows (where maximized
  /// windows and desktop icons go).
  Rect get workArea {
    final l = dockedOn(DockSide.left);
    final r = dockedOn(DockSide.right);
    final left = l == null ? 0.0 : math.min(l.rect.width, desk.width / 2);
    final right = r == null ? desk.width : math.max(desk.width - r.rect.width, desk.width / 2);
    return Rect.fromLTRB(left, 0, math.max(left + 1, right), desk.height);
  }

  /// Where a window is drawn right now.
  Rect shownRect(DeskWindow w) {
    switch (w.dock) {
      case DockSide.left:
        return Rect.fromLTWH(0, 0, math.min(w.rect.width, desk.width / 2), desk.height);
      case DockSide.right:
        final width = math.min(w.rect.width, desk.width / 2);
        return Rect.fromLTWH(desk.width - width, 0, width, desk.height);
      case DockSide.none:
        return w.maximized ? workArea : w.rect;
    }
  }

  /// Docks [id] to [side] (or floats it again with [DockSide.none]).
  void dockTo(String id, DockSide side) {
    final w = byId(id);
    if (w == null || (!w.dockable && side != DockSide.none)) return;
    if (w.dock == side) return;
    if (side != DockSide.none) {
      // Only one window per edge.
      final other = dockedOn(side);
      if (other != null && other != w) _undock(other, notify: false);
      if (w.dock == DockSide.none) w.restoreRect = w.rect;
      w.maximized = false;
      w.dock = side;
    } else {
      _undock(w, notify: false);
    }
    notifyListeners();
    onDockChanged?.call(w);
  }

  void _undock(DeskWindow w, {bool notify = true}) {
    if (w.dock == DockSide.none) return;
    final shown = shownRect(w);
    w.dock = DockSide.none;
    final back = w.restoreRect;
    final height = back?.height ?? math.min(shown.height, 560.0);
    w.rect = _fit(Rect.fromLTWH(shown.left, shown.top, shown.width, height));
    w.restoreRect = null;
    if (notify) {
      notifyListeners();
      onDockChanged?.call(w);
    }
  }

  /// End of a title-bar drag: a dockable window let go at the screen's edge
  /// docks there.
  void dragEnd(String id, Offset pointer) {
    final w = byId(id);
    if (w == null || !w.dockable || w.dock != DockSide.none || w.maximized) return;
    if (pointer.dx <= 6) {
      dockTo(id, DockSide.left);
    } else if (pointer.dx >= desk.width - 6) {
      dockTo(id, DockSide.right);
    }
  }

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
      pos = Offset(workArea.left + 60 + step, 40 + step);
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

  void close(String id, {bool force = false}) {
    final w = byId(id);
    if (w == null) return;
    if (!force && w.beforeClose != null && !w.beforeClose!()) {
      if (activeId != id) focus(id);
      return;
    }
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
      close(w.id, force: true);
    }
  }

  void setTitle(String id, String title) {
    final w = byId(id);
    if (w == null || w.title == title) return;
    w.title = title;
    notifyListeners();
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
    if (w == null || !w.canMaximize || w.dock != DockSide.none) return;
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
    if (w.dock != DockSide.none) {
      // Pulling a docked window away from its edge floats it again.
      final shown = shownRect(w);
      final sideways = w.dock == DockSide.left ? delta.dx > 0 : delta.dx < 0;
      if (!sideways && delta.dy.abs() < 1) return;
      _undock(w, notify: false);
      w.rect = _fit(Rect.fromLTWH(shown.left + delta.dx, math.max(0, delta.dy), w.rect.width, w.rect.height));
      notifyListeners();
      onDockChanged?.call(w);
      return;
    }
    w.rect = _fit(w.rect.shift(delta));
    notifyListeners();
  }

  void resizeBy(String id, int edges, Offset d) {
    final w = byId(id);
    if (w == null || w.maximized || !w.resizable) return;
    if (w.dock != DockSide.none) {
      // Only the inside edge moves; the width is all that changes.
      final dx = w.dock == DockSide.left
          ? (edges & Edge.right != 0 ? d.dx : 0.0)
          : (edges & Edge.left != 0 ? -d.dx : 0.0);
      final width = (w.rect.width + dx).clamp(w.minSize.width, desk.width / 2).toDouble();
      w.rect = Rect.fromLTWH(w.rect.left, w.rect.top, width, w.rect.height);
      notifyListeners();
      return;
    }
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
        MenuEntry('Move', 0, !w.maximized && w.dock == DockSide.none, MenuAction.move),
        MenuEntry('Size', 0, !w.maximized && w.resizable && w.dock == DockSide.none, MenuAction.size),
        MenuEntry('Minimize', 2, w.canMinimize, MenuAction.minimize),
        MenuEntry('Maximize', 2, w.canMaximize && !w.maximized && w.dock == DockSide.none, MenuAction.maximize),
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
