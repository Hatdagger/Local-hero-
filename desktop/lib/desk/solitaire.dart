import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'solitaire_model.dart';
import 'window_manager.dart';
import 'xp_theme.dart';

DeskWindow solitaireWindow() => DeskWindow(
      id: 'solitaire',
      title: 'Solitaire',
      icon: Icons.style,
      size: const Size(680, 520),
      minSize: const Size(420, 340),
      content: (c, w) => _Solitaire(w: w),
    );

const _felt = Color(0xFF0B7A2C);

/// Where everything sits on the table for a given size.
class _Layout {
  _Layout(Size s) : size = s {
    gap = math.max(6.0, s.width * 0.014);
    cardW = math.min((s.width - 8 * gap) / 7, (s.height - 3 * gap) / (1.4 * 3.2));
    cardW = math.max(cardW, 30);
    cardH = cardW * 1.4;
    tableauTop = gap * 2 + cardH;
  }
  final Size size;
  late double gap, cardW, cardH, tableauTop;

  double colX(int i) => gap + i * (cardW + gap);
  Rect slot(PileRef p) {
    final col = switch (p.kind) {
      PileKind.stock => 0,
      PileKind.waste => 1,
      PileKind.foundation => 3 + p.index,
      PileKind.tableau => p.index,
    };
    final y = p.kind == PileKind.tableau ? tableauTop : gap;
    return Rect.fromLTWH(colX(col), y, cardW, cardH);
  }

  /// Vertical spacing for a tableau pile so it fits the table.
  (double, double) fan(List<PlayingCard> pile) {
    var down = cardH * 0.11, up = cardH * 0.25;
    final downs = pile.where((c) => !c.faceUp).length;
    final ups = pile.length - downs;
    final room = size.height - tableauTop - cardH - gap - downs * down;
    if (ups > 1 && up * (ups - 1) > room) up = math.max(cardH * 0.12, room / (ups - 1));
    return (down, up);
  }
}

class _Hit {
  final PileRef pile;
  final int index;
  final Rect rect;
  _Hit(this.pile, this.index, this.rect);
}

class _Drag {
  final PileRef from;
  final int index;
  final Offset grab;
  Offset pos;
  _Drag(this.from, this.index, this.grab, this.pos);
}

class _Bouncer {
  PlayingCard card;
  Offset pos;
  Offset vel;
  _Bouncer(this.card, this.pos, this.vel);
}

class _Solitaire extends StatefulWidget {
  const _Solitaire({required this.w});
  final DeskWindow w;

  @override
  State<_Solitaire> createState() => _SolitaireState();
}

class _SolitaireState extends State<_Solitaire> with SingleTickerProviderStateMixin {
  late Klondike _game = Klondike(drawThree: true);
  final _focus = FocusNode();
  _Drag? _drag;
  _Layout? _layout;
  Timer? _clock;
  int _seconds = 0;
  bool _started = false;
  bool _options = false;
  bool _askDeal = false;
  bool _drawThreeChoice = true;

  // Last click, for double-click detection without delaying single clicks.
  PileRef? _lastTapPile;
  DateTime _lastTapAt = DateTime(0);

  // Winning cascade.
  late final Ticker _ticker = createTicker(_tick);
  final List<PlayingCard> _toLaunch = [];
  _Bouncer? _bouncer;
  ui.Image? _trail;
  int _launchCol = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _ticker.dispose();
    _trail?.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _newGame() {
    _stopCascade();
    setState(() {
      _game = Klondike(drawThree: _game.drawThree);
      _seconds = 0;
      _started = false;
      _askDeal = false;
      _drag = null;
    });
    _clock?.cancel();
  }

  void _startClock() {
    if (_started) return;
    _started = true;
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _game.won) return;
      setState(() => _seconds++);
    });
  }

  void _afterMove() {
    _startClock();
    if (_game.won) {
      _clock?.cancel();
      _startCascade();
    }
    setState(() {});
  }

  // ------------------------------------------------------------ hit testing

  List<_Hit> _hits(_Layout l) {
    final out = <_Hit>[];
    out.add(_Hit(const PileRef(PileKind.stock), _game.stock.length - 1, l.slot(const PileRef(PileKind.stock))));
    final w = _game.waste;
    if (w.isNotEmpty) {
      final shown = _game.drawThree ? math.min(3, w.length) : 1;
      final base = l.slot(const PileRef(PileKind.waste));
      final topRect = base.shift(Offset((shown - 1) * l.cardW * 0.22, 0));
      out.add(_Hit(const PileRef(PileKind.waste), w.length - 1, topRect));
    }
    for (var f = 0; f < 4; f++) {
      final p = PileRef(PileKind.foundation, f);
      out.add(_Hit(p, _game.foundations[f].length - 1, l.slot(p)));
    }
    for (var t = 0; t < 7; t++) {
      final p = PileRef(PileKind.tableau, t);
      final pile = _game.tableau[t];
      final (down, up) = l.fan(pile);
      var r = l.slot(p);
      if (pile.isEmpty) {
        out.add(_Hit(p, -1, r));
        continue;
      }
      for (var i = 0; i < pile.length; i++) {
        out.add(_Hit(p, i, r));
        r = r.shift(Offset(0, pile[i].faceUp ? up : down));
      }
    }
    return out;
  }

  _Hit? _hitAt(Offset pos) {
    final l = _layout;
    if (l == null) return null;
    final hits = _hits(l);
    for (final h in hits.reversed) {
      if (h.rect.contains(pos)) return h;
    }
    return null;
  }

  // ------------------------------------------------------------ input

  void _tapUp(TapUpDetails d) {
    _focus.requestFocus();
    if (_cascading) {
      _stopCascade();
      setState(() => _askDeal = true);
      return;
    }
    final h = _hitAt(d.localPosition);
    if (h == null) return;
    final now = DateTime.now();
    final isDouble = _lastTapPile == h.pile && now.difference(_lastTapAt) < const Duration(milliseconds: 450);
    _lastTapPile = h.pile;
    _lastTapAt = now;

    switch (h.pile.kind) {
      case PileKind.stock:
        _game.drawFromStock();
        _afterMove();
        _lastTapPile = null; // fast clicks on the stock just deal again
      case PileKind.tableau:
        final pile = _game.tableau[h.pile.index];
        if (pile.isNotEmpty && !pile.last.faceUp && h.index == pile.length - 1) {
          _game.flip(h.pile.index);
          _afterMove();
          _lastTapPile = null;
        } else if (isDouble && h.index == pile.length - 1) {
          if (_game.sendHome(h.pile)) _afterMove();
        }
      case PileKind.waste:
        if (isDouble && _game.sendHome(h.pile)) _afterMove();
      case PileKind.foundation:
        break;
    }
  }

  void _panStart(DragStartDetails d) {
    if (_cascading) return;
    final h = _hitAt(d.localPosition);
    if (h == null || h.index < 0 || !_game.canPick(h.pile, h.index)) return;
    setState(() => _drag = _Drag(h.pile, h.index, d.localPosition - h.rect.topLeft, d.localPosition));
  }

  void _panUpdate(DragUpdateDetails d) {
    final dr = _drag;
    if (dr == null) return;
    setState(() => dr.pos = d.localPosition);
  }

  void _panEnd(DragEndDetails _) {
    final dr = _drag;
    final l = _layout;
    if (dr == null || l == null) return;
    final cardRect = Rect.fromLTWH(dr.pos.dx - dr.grab.dx, dr.pos.dy - dr.grab.dy, l.cardW, l.cardH);
    PileRef? best;
    var bestArea = 0.0;
    final targets = [
      for (var f = 0; f < 4; f++) PileRef(PileKind.foundation, f),
      for (var t = 0; t < 7; t++) PileRef(PileKind.tableau, t),
    ];
    for (final p in targets) {
      var r = l.slot(p);
      if (p.kind == PileKind.tableau && _game.tableau[p.index].isNotEmpty) {
        final pile = _game.tableau[p.index];
        final (down, up) = l.fan(pile);
        var y = r.top;
        for (var i = 0; i < pile.length - 1; i++) {
          y += pile[i].faceUp ? up : down;
        }
        r = Rect.fromLTRB(r.left, r.top, r.right, y + l.cardH);
      }
      final inter = r.intersect(cardRect);
      final area = (inter.width > 0 && inter.height > 0) ? inter.width * inter.height : 0.0;
      if (area > bestArea && _game.canDrop(_game.pile(dr.from).sublist(dr.index), p)) {
        bestArea = area;
        best = p;
      }
    }
    if (best != null && _game.move(dr.from, dr.index, best)) {
      _drag = null;
      _afterMove();
    } else {
      setState(() => _drag = null);
    }
  }

  void _rightClick() {
    if (_cascading) return;
    if (_game.autoPlay() > 0) _afterMove();
  }

  // ------------------------------------------------------------ winning cascade

  bool get _cascading => _ticker.isActive;

  void _startCascade() {
    _toLaunch.clear();
    _launchCol = 0;
    // Kings first, one foundation after another, like the classic game.
    for (var r = 12; r >= 0; r--) {
      for (var f = 0; f < 4; f++) {
        if (r < _game.foundations[f].length) _toLaunch.add(_game.foundations[f][r]);
      }
    }
    _bouncer = null;
    _trail?.dispose();
    _trail = null;
    _ticker.start();
  }

  void _stopCascade() {
    if (_ticker.isActive) _ticker.stop();
    _bouncer = null;
    _trail?.dispose();
    _trail = null;
    _toLaunch.clear();
  }

  final _rng = math.Random();

  void _tick(Duration _) {
    final l = _layout;
    if (l == null) return;
    var b = _bouncer;
    if (b == null) {
      if (_toLaunch.isEmpty) {
        _ticker.stop();
        setState(() => _askDeal = true);
        return;
      }
      final card = _toLaunch.removeAt(0)..faceUp = true;
      final start = l.slot(PileRef(PileKind.foundation, _launchCol % 4)).topLeft;
      _launchCol++;
      final dir = _rng.nextBool() ? 1 : -1;
      b = _bouncer = _Bouncer(card, start,
          Offset(dir * (2 + _rng.nextDouble() * 5) * l.cardW / 70, -_rng.nextDouble() * 9 * l.cardW / 70));
    }
    // A couple of physics steps per frame, each leaving a copy behind.
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    if (_trail != null) canvas.drawImage(_trail!, Offset.zero, Paint());
    for (var step = 0; step < 2; step++) {
      b.vel = b.vel + Offset(0, 0.55 * l.cardW / 70);
      b.pos = b.pos + b.vel;
      if (b.pos.dy + l.cardH > l.size.height) {
        b.pos = Offset(b.pos.dx, l.size.height - l.cardH);
        b.vel = Offset(b.vel.dx, -b.vel.dy * 0.72);
      }
      paintCard(canvas, Rect.fromLTWH(b.pos.dx, b.pos.dy, l.cardW, l.cardH), b.card);
    }
    final pic = recorder.endRecording();
    final img = pic.toImageSync(l.size.width.ceil(), l.size.height.ceil());
    pic.dispose();
    _trail?.dispose();
    _trail = img;
    if (b.pos.dx > l.size.width || b.pos.dx + l.cardW < 0) _bouncer = null;
    setState(() {});
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final wm = context.read<WindowManager>();
    final menus = XpMenuBar(menus: [
      ('Game', [
        MenuBarEntry('Deal', _newGame, shortcut: 'F2'),
        const MenuBarEntry.separator(),
        MenuBarEntry('Undo', _game.canUndo && !_cascading ? () => setState(_game.undo) : null, shortcut: 'Ctrl+Z'),
        MenuBarEntry('Options...', () => setState(() {
              _drawThreeChoice = _game.drawThree;
              _options = true;
            })),
        const MenuBarEntry.separator(),
        MenuBarEntry('Exit', () => wm.close(widget.w.id)),
      ]),
    ]);

    final table = LayoutBuilder(builder: (c, box) {
      final l = _layout = _Layout(Size(box.maxWidth, box.maxHeight));
      return GestureDetector(
        onTapUp: _tapUp,
        onSecondaryTap: _rightClick,
        onPanStart: _panStart,
        onPanUpdate: _panUpdate,
        onPanEnd: _panEnd,
        onPanCancel: () => setState(() => _drag = null),
        child: CustomPaint(
          size: Size(box.maxWidth, box.maxHeight),
          painter: _TablePainter(_game, l, _drag, _trail, _cascading),
        ),
      );
    });

    final m = _seconds ~/ 60, s = _seconds % 60;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.f2): _newGame,
          const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () {
            if (_game.canUndo && !_cascading) setState(_game.undo);
          },
        },
        child: Stack(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            menus,
            Expanded(child: ColoredBox(color: _felt, child: table)),
            Container(
              height: 20,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                Text(_game.drawThree ? 'Draw Three' : 'Draw One', style: Xp.text.copyWith(fontSize: 11)),
                const Spacer(),
                Text('Score: ${_game.score}', style: Xp.text.copyWith(fontSize: 11)),
                const SizedBox(width: 16),
                Text('Time: ${m > 0 ? '$m:${s.toString().padLeft(2, '0')}' : '$s'}', style: Xp.text.copyWith(fontSize: 11)),
              ]),
            ),
          ]),
          if (_options) _dialog(_optionsBox()),
          if (_askDeal) _dialog(_dealBox()),
        ]),
      ),
    );
  }

  Widget _dialog(Widget child) => Positioned.fill(
        child: ColoredBox(
          color: const Color(0x33000000),
          child: Center(
            child: Container(
              width: 280,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Xp.face,
                border: Border.all(color: Xp.frame, width: 2),
                boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 6, offset: Offset(2, 2))],
              ),
              child: child,
            ),
          ),
        ),
      );

  Widget _optionsBox() => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Draw', style: Xp.textBold),
        RadioGroup<bool>(
          groupValue: _drawThreeChoice,
          onChanged: (v) => setState(() => _drawThreeChoice = v ?? true),
          child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Radio<bool>(value: false), Text('Draw One', style: Xp.text)]),
            Row(children: [Radio<bool>(value: true), Text('Draw Three', style: Xp.text)]),
          ]),
        ),
        const SizedBox(height: 6),
        const Text('Changing this deals a new game.', style: Xp.textGrey),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          XpButton(
              label: 'OK',
              isDefault: true,
              onPressed: () {
                final changed = _drawThreeChoice != _game.drawThree;
                setState(() => _options = false);
                if (changed) {
                  _game.drawThree = _drawThreeChoice;
                  _newGame();
                }
              }),
          const SizedBox(width: 6),
          XpButton(label: 'Cancel', onPressed: () => setState(() => _options = false)),
        ]),
      ]);

  Widget _dealBox() => Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_game.won ? 'You won! Deal again?' : 'Deal again?', style: Xp.textBold),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          XpButton(label: 'Yes', isDefault: true, onPressed: _newGame),
          const SizedBox(width: 6),
          XpButton(label: 'No', onPressed: () => setState(() => _askDeal = false)),
        ]),
      ]);
}

// ======================================================================
// Drawing

class _TablePainter extends CustomPainter {
  _TablePainter(this.game, this.l, this.drag, this.trail, this.cascading);
  final Klondike game;
  final _Layout l;
  final _Drag? drag;
  final ui.Image? trail;
  final bool cascading;

  @override
  void paint(Canvas canvas, Size size) {
    if (cascading && trail != null) {
      canvas.drawImage(trail!, Offset.zero, Paint());
      return;
    }
    final slotPaint = Paint()
      ..color = const Color(0xFF07591F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    RRect rr(Rect r) => RRect.fromRectAndRadius(r, Radius.circular(l.cardW * 0.07));

    // Empty slots.
    for (final p in [
      const PileRef(PileKind.stock),
      for (var f = 0; f < 4; f++) PileRef(PileKind.foundation, f),
      for (var t = 0; t < 7; t++) PileRef(PileKind.tableau, t),
    ]) {
      canvas.drawRRect(rr(l.slot(p)), slotPaint);
    }
    // Recycle mark on an empty stock.
    if (game.stock.isEmpty) {
      final c = l.slot(const PileRef(PileKind.stock)).center;
      canvas.drawCircle(c, l.cardW * 0.25, slotPaint..strokeWidth = 4);
      slotPaint.strokeWidth = 1.5;
    }

    final d = drag;
    bool dragged(PileRef p, int i) => d != null && d.from == p && i >= d.index;

    // Stock.
    if (game.stock.isNotEmpty) {
      final r = l.slot(const PileRef(PileKind.stock));
      final layers = math.min(3, (game.stock.length / 8).ceil());
      for (var i = 0; i < layers; i++) {
        paintCard(canvas, r.shift(Offset(i * 1.5, i * 1.0)), game.stock.last);
      }
    }
    // Waste (top 1 or 3 fanned).
    final w = game.waste;
    if (w.isNotEmpty) {
      final shown = game.drawThree ? math.min(3, w.length) : 1;
      final base = l.slot(const PileRef(PileKind.waste));
      for (var k = 0; k < shown; k++) {
        final i = w.length - shown + k;
        if (dragged(const PileRef(PileKind.waste), i)) continue;
        paintCard(canvas, base.shift(Offset(k * l.cardW * 0.22, 0)), w[i]);
      }
    }
    // Foundations.
    for (var f = 0; f < 4; f++) {
      final p = PileRef(PileKind.foundation, f);
      final pile = game.foundations[f];
      if (pile.isEmpty) continue;
      if (dragged(p, pile.length - 1)) {
        if (pile.length > 1) paintCard(canvas, l.slot(p), pile[pile.length - 2]);
      } else {
        paintCard(canvas, l.slot(p), pile.last);
      }
    }
    // Tableau.
    for (var t = 0; t < 7; t++) {
      final p = PileRef(PileKind.tableau, t);
      final pile = game.tableau[t];
      final (down, up) = l.fan(pile);
      var r = l.slot(p);
      for (var i = 0; i < pile.length; i++) {
        if (!dragged(p, i)) paintCard(canvas, r, pile[i]);
        r = r.shift(Offset(0, pile[i].faceUp ? up : down));
      }
    }
    // Cards being dragged, on top.
    if (d != null) {
      final cards = game.pile(d.from).sublist(d.index);
      var r = Rect.fromLTWH(d.pos.dx - d.grab.dx, d.pos.dy - d.grab.dy, l.cardW, l.cardH);
      final (_, up) = l.fan(game.pile(d.from));
      for (final c in cards) {
        paintCard(canvas, r, c, shadow: true);
        r = r.shift(Offset(0, d.from.kind == PileKind.tableau ? up : 0));
      }
    }
  }

  @override
  bool shouldRepaint(_TablePainter old) => true;
}

final Map<String, TextPainter> _textCache = {};

TextPainter _tp(String s, double size, Color color, {bool bold = true}) {
  final key = '$s|${size.toStringAsFixed(1)}|${color.toARGB32()}|$bold';
  return _textCache.putIfAbsent(key, () {
    if (_textCache.length > 400) _textCache.clear();
    return TextPainter(
      text: TextSpan(
          text: s,
          style: TextStyle(fontSize: size, color: color, fontWeight: bold ? FontWeight.bold : FontWeight.normal, height: 1)),
      textDirection: TextDirection.ltr,
    )..layout();
  });
}

void _center(Canvas c, TextPainter tp, Offset at) => tp.paint(c, at - Offset(tp.width / 2, tp.height / 2));

/// Draws one card (our own simple design).
void paintCard(Canvas canvas, Rect r, PlayingCard card, {bool shadow = false}) {
  final radius = Radius.circular(r.width * 0.07);
  final rr = RRect.fromRectAndRadius(r, radius);
  if (shadow) canvas.drawRRect(rr.shift(const Offset(3, 3)), Paint()..color = const Color(0x55000000));
  if (!card.faceUp) {
    canvas.drawRRect(rr, Paint()..color = Colors.white);
    final inner = RRect.fromRectAndRadius(r.deflate(r.width * 0.07), radius);
    canvas.drawRRect(inner, Paint()..color = const Color(0xFF1F4FB0));
    canvas.save();
    canvas.clipRRect(inner);
    final lp = Paint()
      ..color = const Color(0xFF5C86D6)
      ..strokeWidth = 1.2;
    final step = r.width / 7;
    for (var x = -r.height; x < r.width + r.height; x += step) {
      canvas.drawLine(Offset(r.left + x, r.top), Offset(r.left + x + r.height, r.bottom), lp);
      canvas.drawLine(Offset(r.left + x + r.height, r.top), Offset(r.left + x, r.bottom), lp);
    }
    canvas.restore();
    canvas.drawRRect(rr, Paint()
      ..color = const Color(0xFF333333)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8);
    return;
  }

  canvas.drawRRect(rr, Paint()..color = Colors.white);
  canvas.drawRRect(rr, Paint()
    ..color = const Color(0xFF555555)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.8);
  final color = card.suit.red ? const Color(0xFFD01010) : Colors.black;
  final w = r.width;

  // Corner: rank over suit (top-left and bottom-right).
  final rank = _tp(card.rankLabel, w * 0.2, color);
  final small = _tp(card.suit.symbol, w * 0.17, color, bold: false);
  final cx = r.left + w * 0.13;
  rank.paint(canvas, Offset(cx - rank.width / 2, r.top + w * 0.05));
  small.paint(canvas, Offset(cx - small.width / 2, r.top + w * 0.05 + rank.height));
  canvas.save();
  canvas.translate(r.right, r.bottom);
  canvas.rotate(math.pi);
  rank.paint(canvas, Offset(w * 0.13 - rank.width / 2, w * 0.05));
  small.paint(canvas, Offset(w * 0.13 - small.width / 2, w * 0.05 + rank.height));
  canvas.restore();

  final inner = Rect.fromLTRB(r.left + w * 0.26, r.top + w * 0.12, r.right - w * 0.26, r.bottom - w * 0.12);
  if (card.rank == 1) {
    _center(canvas, _tp(card.suit.symbol, w * 0.55, color, bold: false), r.center);
  } else if (card.rank > 10) {
    final box = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawRect(inner, box);
    canvas.drawRect(inner, Paint()..color = (card.suit.red ? const Color(0xFFFFF1D6) : const Color(0xFFE9EEFF)));
    canvas.drawRect(inner, box);
    _center(canvas, _tp(card.rankLabel, w * 0.42, color), inner.center - Offset(0, w * 0.12));
    _center(canvas, _tp(card.suit.symbol, w * 0.3, color, bold: false), inner.center + Offset(0, w * 0.22));
  } else {
    final pip = _tp(card.suit.symbol, w * 0.2, color, bold: false);
    for (final (fx, fy) in _pips[card.rank]!) {
      _center(canvas, pip, Offset(inner.left + inner.width * fx, inner.top + inner.height * fy));
    }
  }
}

const _l = 0.18, _c = 0.5, _r = 0.82;
const Map<int, List<(double, double)>> _pips = {
  2: [(_c, 0.08), (_c, 0.92)],
  3: [(_c, 0.08), (_c, 0.5), (_c, 0.92)],
  4: [(_l, 0.08), (_r, 0.08), (_l, 0.92), (_r, 0.92)],
  5: [(_l, 0.08), (_r, 0.08), (_c, 0.5), (_l, 0.92), (_r, 0.92)],
  6: [(_l, 0.08), (_r, 0.08), (_l, 0.5), (_r, 0.5), (_l, 0.92), (_r, 0.92)],
  7: [(_l, 0.08), (_r, 0.08), (_c, 0.29), (_l, 0.5), (_r, 0.5), (_l, 0.92), (_r, 0.92)],
  8: [(_l, 0.08), (_r, 0.08), (_c, 0.29), (_l, 0.5), (_r, 0.5), (_c, 0.71), (_l, 0.92), (_r, 0.92)],
  9: [(_l, 0.08), (_r, 0.08), (_l, 0.36), (_r, 0.36), (_c, 0.5), (_l, 0.64), (_r, 0.64), (_l, 0.92), (_r, 0.92)],
  10: [
    (_l, 0.08), (_r, 0.08), (_c, 0.22), (_l, 0.36), (_r, 0.36),
    (_l, 0.64), (_r, 0.64), (_c, 0.78), (_l, 0.92), (_r, 0.92),
  ],
};
