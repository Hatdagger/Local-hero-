import 'dart:async';

import 'package:flutter/services.dart';

import 'browser.dart';
import 'desk.dart';
import 'media_player.dart';
import 'mini_player.dart';
import 'window_manager.dart';

/// Desktop-wide keyboard shortcuts:
/// Alt+Tab, Alt+Space, Alt+F4, Win, Win+M, Shift+Win+M, Win+D, Win+R, Win+E.
class DeskKeys {
  DeskKeys(this.desk);
  final Desk desk;
  WindowManager get wm => desk.wm;

  bool _metaAlone = false;

  static bool _isAlt(LogicalKeyboardKey k) => k == LogicalKeyboardKey.altLeft || k == LogicalKeyboardKey.altRight;
  static bool _isMeta(LogicalKeyboardKey k) => k == LogicalKeyboardKey.metaLeft || k == LogicalKeyboardKey.metaRight;

  /// The same shortcuts, passed over from Android while a web page has the
  /// keyboard.
  void external(String name, bool shift) {
    switch (name) {
      case 'altTab':
        if (wm.switcherIndex == null) {
          wm.startSwitch(back: shift);
        } else {
          wm.switchStep(back: shift);
        }
      case 'altUp':
        if (wm.switcherIndex != null) wm.commitSwitch();
      case 'altSpace':
        final a = wm.active;
        if (a != null) wm.openMenu(a.id);
      case 'altF4':
        final a = wm.active;
        if (a != null) wm.close(a.id);
      case 'meta':
        wm.toggleStart();
      case 'metaM':
        if (shift) {
          wm.undoMinimizeAll();
        } else {
          wm.minimizeAll();
        }
      case 'metaD':
        wm.showDesktop();
      case 'metaR':
        wm.closeStart();
        desk.openRun();
      case 'metaE':
        wm.closeStart();
        desk.openExplorer();
      case 'ctrlT' || 'ctrlW' || 'ctrlL' || 'f5' || 'altLeft' || 'altRight':
        final a = wm.activeId;
        if (a != null) browserKeyHandlers[a]?.call(name);
    }
  }

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

    // Full-screen video: Esc / F11 / Ctrl+F leave, Space pauses, arrows skip 10 s.
    final player = DeskPlayer.instance;
    final ctrl = hk.isControlPressed;
    if (player.fullScreen && player.isVideo) {
      if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.f11 || (ctrl && key == LogicalKeyboardKey.keyF)) {
        player.setFullScreen(false);
        return true;
      }
      if (key == LogicalKeyboardKey.space) {
        unawaited(player.toggle());
        return true;
      }
      if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
        final d = Duration(seconds: key == LogicalKeyboardKey.arrowLeft ? -10 : 10);
        unawaited(player.seek(player.position + d < Duration.zero ? Duration.zero : player.position + d));
        return true;
      }
      if (alt && key == LogicalKeyboardKey.tab) player.setFullScreen(false);
    } else if ((ctrl && key == LogicalKeyboardKey.keyF) || key == LogicalKeyboardKey.f11) {
      if (wm.activeId == kMediaPlayerId && player.isVideo) {
        player.setFullScreen(true);
        return true;
      }
    }
    // Media Player: Ctrl+2 = mini player, Ctrl+1 (in the mini player) = full player.
    if (ctrl && key == LogicalKeyboardKey.digit2 && wm.activeId == kMediaPlayerId) {
      wm.close(kMediaPlayerId);
      desk.openMiniPlayer();
      return true;
    }
    if (ctrl && key == LogicalKeyboardKey.digit1 && wm.activeId == kMiniPlayerId) {
      wm.close(kMiniPlayerId);
      desk.openMediaPlayer();
      return true;
    }

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
    if (meta && key == LogicalKeyboardKey.keyE) {
      wm.closeStart();
      desk.openExplorer();
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
