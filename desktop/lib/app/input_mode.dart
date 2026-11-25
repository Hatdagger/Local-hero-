import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gamepads/gamepads.dart';

import 'settings.dart';

enum PadAction {
  up, down, left, right, a, b, x, y, start, select, lb, rb,

  /// Select held down for a moment (sent instead of [select]).
  selectHold,

  /// Start pressed while Select is held.
  startSelect,
}

typedef PadHandler = bool Function(PadAction action);

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Tracks whether the user is driving the app with a controller, and turns
/// controller input into focus movement / activation.
///
/// Android delivers controller buttons as key events (handled by [handleKey]);
/// on Windows and Linux (Steam Deck, ROG Ally, XInput pads) the `gamepads`
/// plugin is used.
class InputMode extends ChangeNotifier {
  final AppSettings settings;
  bool _padActive = false;
  final List<PadHandler> _handlers = [];
  StreamSubscription<dynamic>? _padSub;
  Timer? _repeat;
  PadAction? _heldDir;
  final Set<PadAction> _down = {};

  /// Buttons that do something else when held: they act on release, or
  /// after [holdTime] as their "held" action. (Only Select: everything else
  /// acts the moment it's pressed.)
  static const _holdable = {PadAction.select: PadAction.selectHold};
  static const holdTime = Duration(milliseconds: 450);
  final Map<PadAction, Timer?> _holding = {};

  InputMode(this.settings) {
    settings.addListener(notifyListeners);
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      _listenDesktopPads();
    }
  }

  /// True when the UI should use controller-friendly widgets and the
  /// built-in on-screen keyboard instead of the system keyboard.
  bool get controller => switch (settings.controllerMode) {
        ControllerMode.on => true,
        ControllerMode.off => false,
        ControllerMode.auto => _padActive,
      };

  void notePad() {
    if (!_padActive) {
      _padActive = true;
      notifyListeners();
    }
  }

  void noteTouchOrKeyboard() {
    if (_padActive) {
      _padActive = false;
      notifyListeners();
    }
  }

  void pushHandler(PadHandler h) => _handlers.add(h);
  void removeHandler(PadHandler h) => _handlers.remove(h);

  void dispatch(PadAction a) {
    notePad();
    // Start while Select is down: the Select+Start combo instead of either.
    if (a == PadAction.start && _holding.containsKey(PadAction.select)) {
      _holding[PadAction.select]?.cancel();
      _holding[PadAction.select] = null; // its release does nothing
      a = PadAction.startSelect;
    }
    for (final h in _handlers.reversed.toList()) {
      if (h(a)) return;
    }
    // Nobody wants the "held" version: treat it as a normal press.
    final tap = _holdable.entries.where((e) => e.value == a).firstOrNull?.key;
    if (tap != null) return dispatch(tap);
    _defaultAction(a);
  }

  /// A holdable button went down: wait to see whether it's a tap or a hold.
  void _holdDown(PadAction a) {
    if (_holding.containsKey(a)) return; // key repeat
    notePad();
    _holding[a] = Timer(holdTime, () {
      _holding[a] = null; // fired; the release does nothing
      dispatch(_holdable[a]!);
    });
  }

  void _holdUp(PadAction a) {
    if (!_holding.containsKey(a)) return;
    final t = _holding.remove(a);
    if (t != null && t.isActive) {
      t.cancel();
      dispatch(a);
    }
  }

  void _defaultAction(PadAction a) {
    final focus = FocusManager.instance.primaryFocus;
    TraversalDirection? dir = switch (a) {
      PadAction.up => TraversalDirection.up,
      PadAction.down => TraversalDirection.down,
      PadAction.left => TraversalDirection.left,
      PadAction.right => TraversalDirection.right,
      _ => null,
    };
    if (dir != null) {
      if (focus == null || focus == FocusManager.instance.rootScope) {
        FocusManager.instance.rootScope.nextFocus();
        return;
      }
      if (!focus.focusInDirection(dir)) {
        if (dir == TraversalDirection.down || dir == TraversalDirection.right) {
          focus.nextFocus();
        } else {
          focus.previousFocus();
        }
      }
      return;
    }
    switch (a) {
      case PadAction.a:
        final ctx = focus?.context;
        if (ctx != null) Actions.maybeInvoke(ctx, const ActivateIntent());
      case PadAction.b:
        navigatorKey.currentState?.maybePop();
      case PadAction.lb:
        focus?.previousFocus();
      case PadAction.rb:
        focus?.nextFocus();
      default:
        break;
    }
  }

  /// Root key handler. Returns true if the event was consumed.
  bool handleKey(KeyEvent e) {
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.gameButtonSelect) {
      const a = PadAction.select;
      if (e is KeyUpEvent) {
        _holdUp(a);
      } else {
        _holdDown(a);
      }
      return true;
    }
    if (e is KeyUpEvent) return false;
    PadAction? a;
    if (k == LogicalKeyboardKey.gameButtonB) a = PadAction.b;
    if (k == LogicalKeyboardKey.gameButtonX) a = PadAction.x;
    if (k == LogicalKeyboardKey.gameButtonY) a = PadAction.y;
    if (k == LogicalKeyboardKey.gameButtonStart) a = PadAction.start;
    if (k == LogicalKeyboardKey.gameButtonSelect) a = PadAction.select;
    if (k == LogicalKeyboardKey.gameButtonLeft1) a = PadAction.lb;
    if (k == LogicalKeyboardKey.gameButtonRight1) a = PadAction.rb;
    if (k == LogicalKeyboardKey.gameButtonA) {
      notePad();
      // Let handlers (on-screen keyboard) see it; otherwise Flutter's default
      // ActivateIntent shortcut handles it.
      for (final h in _handlers.reversed.toList()) {
        if (h(PadAction.a)) return true;
      }
      return false;
    }
    if (a != null) {
      dispatch(a);
      return true;
    }
    if (e.character != null && e.character!.isNotEmpty && k != LogicalKeyboardKey.enter) {
      noteTouchOrKeyboard();
    }
    return false;
  }

  void _listenDesktopPads() {
    try {
      _padSub = Gamepads.normalizedEvents.listen((ev) {
        final b = ev.button;
        final ax = ev.axis;
        if (b != null) {
          final a = switch (b) {
            GamepadButton.a => PadAction.a,
            GamepadButton.b => PadAction.b,
            GamepadButton.x => PadAction.x,
            GamepadButton.y => PadAction.y,
            GamepadButton.start => PadAction.start,
            GamepadButton.back => PadAction.select,
            GamepadButton.leftBumper => PadAction.lb,
            GamepadButton.rightBumper => PadAction.rb,
            GamepadButton.dpadUp => PadAction.up,
            GamepadButton.dpadDown => PadAction.down,
            GamepadButton.dpadLeft => PadAction.left,
            GamepadButton.dpadRight => PadAction.right,
            _ => null,
          };
          if (a == null) return;
          final pressed = ev.value > 0.5;
          if (pressed && !_down.contains(a)) {
            _down.add(a);
            if (_holdable.containsKey(a)) {
              scheduleMicrotask(() => _holdDown(a));
            } else {
              _press(a);
            }
          } else if (!pressed && _down.contains(a)) {
            _down.remove(a);
            if (_holdable.containsKey(a)) scheduleMicrotask(() => _holdUp(a));
            if (_heldDir == a) _stopRepeat();
          }
        } else if (ax == GamepadAxis.leftStickX || ax == GamepadAxis.leftStickY) {
          final v = ev.value;
          final isX = ax == GamepadAxis.leftStickX;
          PadAction? dir;
          if (v > 0.6) dir = isX ? PadAction.right : PadAction.up;
          if (v < -0.6) dir = isX ? PadAction.left : PadAction.down;
          if (dir == null) {
            if (_heldDir != null &&
                ((isX && (_heldDir == PadAction.left || _heldDir == PadAction.right)) ||
                    (!isX && (_heldDir == PadAction.up || _heldDir == PadAction.down)))) {
              _stopRepeat();
            }
          } else if (_heldDir != dir) {
            _press(dir);
          }
        }
      });
    } catch (_) {
      // No gamepad support on this machine.
    }
  }

  void _press(PadAction a) {
    final isDir = a == PadAction.up || a == PadAction.down || a == PadAction.left || a == PadAction.right;
    // Plugin callbacks may arrive off the frame; run on the UI loop.
    scheduleMicrotask(() => dispatch(a));
    if (isDir) {
      _stopRepeat();
      _heldDir = a;
      _repeat = Timer(const Duration(milliseconds: 400), () {
        _repeat = Timer.periodic(const Duration(milliseconds: 110), (_) => dispatch(a));
      });
    }
  }

  void _stopRepeat() {
    _repeat?.cancel();
    _repeat = null;
    _heldDir = null;
  }

  @override
  void dispose() {
    _padSub?.cancel();
    _stopRepeat();
    for (final t in _holding.values) {
      t?.cancel();
    }
    settings.removeListener(notifyListeners);
    super.dispose();
  }
}
