import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'window_manager.dart';
import 'xp_theme.dart';

const double kTitleHeight = 28;
const double kBorder = 4;

/// Draws one window: blue frame, title bar with its buttons, resize edges.
class XpWindowFrame extends StatelessWidget {
  const XpWindowFrame({super.key, required this.w, required this.wm});
  final DeskWindow w;
  final WindowManager wm;

  @override
  Widget build(BuildContext context) {
    final active = wm.activeId == w.id;
    final r = wm.shownRect(w);
    final maximized = w.maximized;
    final frameColor = active ? Xp.frame : Xp.frameInactive;

    final body = Container(
      decoration: BoxDecoration(
        color: frameColor,
        borderRadius: maximized ? null : const BorderRadius.vertical(top: Radius.circular(8)),
        boxShadow: maximized ? null : const [BoxShadow(color: Color(0x55000000), blurRadius: 6, offset: Offset(2, 3))],
      ),
      padding: EdgeInsets.fromLTRB(maximized ? 0 : 3, 0, maximized ? 0 : 3, maximized ? 0 : 3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _TitleBar(w: w, wm: wm, active: active),
        Expanded(
          child: Container(
            color: Xp.face,
            child: FocusScope(
              node: w.focus,
              child: Builder(builder: (c) => w.content(c, w)),
            ),
          ),
        ),
      ]),
    );

    return Positioned.fromRect(
      rect: r,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          if (wm.activeId != w.id) wm.focus(w.id);
        },
        child: Stack(children: [
          Positioned.fill(child: body),
          if (w.resizable && !maximized) ..._handles(),
        ]),
      ),
    );
  }

  List<Widget> _handles() {
    Widget h(int edges, MouseCursor cursor, {double? l, double? t, double? r, double? b, double? width, double? height}) {
      return Positioned(
        left: l,
        top: t,
        right: r,
        bottom: b,
        width: width,
        height: height,
        child: MouseRegion(
          cursor: cursor,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanUpdate: (d) => wm.resizeBy(w.id, edges, d.delta),
          ),
        ),
      );
    }

    const e = 6.0, c = 14.0;
    return [
      h(Edge.left, SystemMouseCursors.resizeLeftRight, l: 0, t: c, b: c, width: e),
      h(Edge.right, SystemMouseCursors.resizeLeftRight, r: 0, t: c, b: c, width: e),
      h(Edge.top, SystemMouseCursors.resizeUpDown, t: 0, l: c, r: c, height: 4),
      h(Edge.bottom, SystemMouseCursors.resizeUpDown, b: 0, l: c, r: c, height: e),
      h(Edge.left | Edge.top, SystemMouseCursors.resizeUpLeftDownRight, l: 0, t: 0, width: c, height: 5),
      h(Edge.right | Edge.top, SystemMouseCursors.resizeUpRightDownLeft, r: 0, t: 0, width: c, height: 5),
      h(Edge.left | Edge.bottom, SystemMouseCursors.resizeUpRightDownLeft, l: 0, b: 0, width: c, height: c),
      h(Edge.right | Edge.bottom, SystemMouseCursors.resizeUpLeftDownRight, r: 0, b: 0, width: c, height: c),
    ];
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.w, required this.wm, required this.active});
  final DeskWindow w;
  final WindowManager wm;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanUpdate: (d) => wm.moveBy(w.id, d.delta),
      onDoubleTap: w.canMaximize ? () => wm.toggleMaximize(w.id) : null,
      onSecondaryTap: () => wm.openMenu(w.id),
      child: Container(
        height: kTitleHeight,
        decoration: BoxDecoration(
          borderRadius: w.maximized ? null : const BorderRadius.vertical(top: Radius.circular(7)),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: active
                ? const [Color(0xFF3D95FF), Xp.titleTop, Xp.titleBottom, Color(0xFF0A3FB0)]
                : const [Color(0xFFB4CBF2), Xp.titleTopInactive, Xp.titleBottomInactive, Color(0xFF7590D3)],
            stops: const [0, 0.12, 0.8, 1],
          ),
        ),
        padding: const EdgeInsets.only(left: 5, right: 4),
        child: Row(children: [
          GestureDetector(
            onTap: () => wm.openMenu(w.id),
            onDoubleTap: () => wm.close(w.id),
            child: Icon(w.icon, size: 17, color: Colors.white),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              w.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: active ? Colors.white : const Color(0xFFDCE6F8),
                fontWeight: FontWeight.bold,
                fontSize: 13,
                shadows: active ? const [Shadow(color: Color(0xFF0A1C5C), offset: Offset(1, 1))] : null,
              ),
            ),
          ),
          if (w.canMinimize) CaptionButton(kind: CaptionKind.minimize, active: active, onTap: () => wm.minimize(w.id)),
          if (w.canMaximize)
            CaptionButton(
                kind: w.maximized ? CaptionKind.restore : CaptionKind.maximize,
                active: active,
                onTap: () => wm.toggleMaximize(w.id)),
          CaptionButton(kind: CaptionKind.close, active: active, onTap: () => wm.close(w.id)),
        ]),
      ),
    );
  }
}

enum CaptionKind { minimize, maximize, restore, close }

class CaptionButton extends StatefulWidget {
  const CaptionButton({super.key, required this.kind, required this.onTap, this.active = true});
  final CaptionKind kind;
  final VoidCallback onTap;
  final bool active;

  @override
  State<CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<CaptionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final close = widget.kind == CaptionKind.close;
    List<Color> colors;
    if (close) {
      colors = _hover ? const [Color(0xFFF7A588), Color(0xFFE5612F)] : const [Color(0xFFE88E6E), Color(0xFFC6421B)];
    } else {
      colors = _hover ? const [Color(0xFF7FB2FF), Color(0xFF3A7BEA)] : const [Color(0xFF5B9BFF), Color(0xFF2361DA)];
    }
    if (!widget.active) colors = colors.map((c) => Color.lerp(c, const Color(0xFFB9CBF0), 0.45)!).toList();
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        // Keep the title bar's drag from starting on a button.
        onPanStart: (_) {},
        child: Container(
          width: 21,
          height: 21,
          margin: const EdgeInsets.only(left: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: Colors.white, width: 1),
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
          ),
          child: CustomPaint(painter: _GlyphPainter(widget.kind)),
        ),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.kind);
  final CaptionKind kind;

  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = Colors.white
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    switch (kind) {
      case CaptionKind.minimize:
        canvas.drawRect(Rect.fromLTWH(5, s.height - 7, 7, 2.5), p..style = PaintingStyle.fill);
      case CaptionKind.maximize:
        canvas.drawRect(Rect.fromLTWH(5, 5, s.width - 10, s.height - 10), p..strokeWidth = 1.5);
        canvas.drawLine(const Offset(5, 6), Offset(s.width - 5, 6), p..strokeWidth = 2.5);
      case CaptionKind.restore:
        p.strokeWidth = 1.3;
        canvas.drawRect(const Rect.fromLTWH(8, 4, 7, 6), p);
        canvas.drawRect(const Rect.fromLTWH(4, 8, 7, 6), p);
      case CaptionKind.close:
        p.strokeWidth = 2.2;
        canvas.drawLine(const Offset(5.5, 5.5), Offset(s.width - 5.5, s.height - 5.5), p);
        canvas.drawLine(Offset(s.width - 5.5, 5.5), Offset(5.5, s.height - 5.5), p);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.kind != kind;
}

/// Swallows Back so the desktop (a home screen) never closes itself.
class NoBack extends StatelessWidget {
  const NoBack({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope(canPop: false, child: child);
}

/// Keyboard helper: is [k] Enter (either one)?
bool isEnter(LogicalKeyboardKey k) => k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter;
