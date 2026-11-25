import 'package:flutter/services.dart';

import 'desk.dart';
import 'window_manager.dart';

/// Desktop-wide keyboard shortcuts:
/// Alt+Tab, Alt+Space, Alt+F4, Win, Win+M, Shift+Win+M, Win+D, Win+R.
class DeskKeys {
  DeskKeys(this.desk);
  final Desk desk;
  WindowManager get wm => desk.wm;

  bool _metaAlone = false;

  static bool _isAlt(LogicalKeyboardKey k) => k == LogicalKeyboardKey.altLeft || k == LogicalKeyboardKey.altRight;
  static bool _isMeta(LogicalKeyboardKey k) => k == LogicalKeyboardKey.metaLeft || k == LogicalKeyboardKey.metaRight;

  bool handle(KeyEvent e) {
    final hk = HardwareKeyboard.instance;
    final key = e.logicalKey;
    final down = e is KeyDownEvent || e is KeyRepeatEvent;
    final alt = hk.isAltPressed;
    final meta = hk.isMetaPressed;
    final shift = hk.isShiftPressed;

    // Letting go of Alt picks the window chosen in Alt+Tab.
    if (e is KeyUpEvent && _isAlt(key) && wm.switcherIndex != null) {
      wm.commitSwitch();
      return true;
    }

    // The Windows key on its own opens the Start menu.
    if (_isMeta(key)) {
      if (e is KeyDownEvent) _metaAlone = true;
      if (e is KeyUpEvent) {
        if (_metaAlone) wm.toggleStart();
        _metaAlone = false;
        return true;
      }
      return false;
    }
    if (!down) return false;
    if (meta) _metaAlone = false;

    if (alt && key == LogicalKeyboardKey.tab) {
      if (wm.switcherIndex == null) {
        wm.startSwitch(back: shift);
      } else {
        wm.switchStep(back: shift);
      }
      return true;
    }
    if (wm.switcherIndex != null) {
      if (key == LogicalKeyboardKey.escape) wm.cancelSwitch();
      if (key == LogicalKeyboardKey.arrowRight) wm.switchStep();
      if (key == LogicalKeyboardKey.arrowLeft) wm.switchStep(back: true);
      return true;
    }

    // Alt+Space window menu is open.
    if (wm.menuFor != null) {
      if (key == LogicalKeyboardKey.arrowDown) {
        wm.menuMove(1);
      } else if (key == LogicalKeyboardKey.arrowUp) {
        wm.menuMove(-1);
      } else if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
        wm.menuActivate();
      } else if (key == LogicalKeyboardKey.escape || (alt && key == LogicalKeyboardKey.space)) {
        wm.closeMenu();
      } else if (key == LogicalKeyboardKey.f4 && alt) {
        wm.closeMenu();
        final a = wm.active;
        if (a != null) wm.close(a.id);
      } else {
        final ch = key.keyLabel;
        if (ch.length == 1) wm.menuLetter(ch);
      }
      return true;
    }

    // Moving or sizing with the arrow keys (after Alt+Space, M or S).
    if (wm.kbMode != KbMode.none) {
      final step = hk.isControlPressed ? 2.0 : 12.0;
      if (key == LogicalKeyboardKey.arrowLeft) wm.kbArrow(-step, 0);
      if (key == LogicalKeyboardKey.arrowRight) wm.kbArrow(step, 0);
      if (key == LogicalKeyboardKey.arrowUp) wm.kbArrow(0, -step);
      if (key == LogicalKeyboardKey.arrowDown) wm.kbArrow(0, step);
      if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) wm.kbEnd(keep: true);
      if (key == LogicalKeyboardKey.escape) wm.kbEnd(keep: false);
      return true;
    }

    if (alt && key == LogicalKeyboardKey.space) {
      final a = wm.active;
      if (a != null) wm.openMenu(a.id);
      return true;
    }
    if (alt && key == LogicalKeyboardKey.f4) {
      final a = wm.active;
      if (a != null) wm.close(a.id);
      return true;
    }
    if (meta && key == LogicalKeyboardKey.keyM) {
      if (shift) {
        wm.undoMinimizeAll();
      } else {
        wm.minimizeAll();
      }
      return true;
    }
    if (meta && key == LogicalKeyboardKey.keyD) {
      wm.showDesktop();
      return true;
    }
    if (meta && key == LogicalKeyboardKey.keyR) {
      wm.closeStart();
      desk.openRun();
      return true;
    }
    if (wm.startOpen && key == LogicalKeyboardKey.escape) {
      wm.closeStart();
      return true;
    }
    return false;
  }
}
