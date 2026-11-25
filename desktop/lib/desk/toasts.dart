import 'dart:async';

import 'package:flutter/material.dart';

import 'xp_theme.dart';

/// One little pop-up in the bottom-right corner ("Bob has signed on.").
class DeskToast {
  DeskToast({required this.title, required this.text, this.icon = Icons.info, this.onTap});
  final String title;
  final String text;
  final IconData icon;
  final VoidCallback? onTap;
  final int id = _next++;
  static int _next = 0;
}

/// The pop-ups currently showing. Each one stays for a few seconds.
class Toasts extends ChangeNotifier {
  static const shownFor = Duration(seconds: 5);
  static const maxShown = 4;

  final List<DeskToast> items = [];

  void show(DeskToast t) {
    items.add(t);
    while (items.length > maxShown) {
      items.removeAt(0);
    }
    notifyListeners();
    Timer(shownFor, () => dismiss(t));
  }

  void dismiss(DeskToast t) {
    if (items.remove(t)) notifyListeners();
  }
}

/// Stacks the pop-ups upwards from just above the taskbar's clock.
class ToastStack extends StatelessWidget {
  const ToastStack({super.key, required this.toasts});
  final Toasts toasts;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: toasts,
      builder: (c, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final t in toasts.items)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _ToastCard(key: ValueKey(t.id), t: t, onClose: () => toasts.dismiss(t)),
            ),
        ],
      ),
    );
  }
}

class _ToastCard extends StatefulWidget {
  const _ToastCard({super.key, required this.t, required this.onClose});
  final DeskToast t;
  final VoidCallback onClose;

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard> with SingleTickerProviderStateMixin {
  late final AnimationController _a =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 260))..forward();

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final card = GestureDetector(
      onTap: () {
        widget.onClose();
        t.onTap?.call();
      },
      child: Container(
        width: 230,
        decoration: BoxDecoration(
          color: const Color(0xFFFFFFE1),
          border: Border.all(color: const Color(0xFF0A246A)),
          boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 6, offset: Offset(2, 3))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            height: 20,
            padding: const EdgeInsets.only(left: 5, right: 2),
            decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [Xp.titleTop, Color(0xFF3D95FF)]),
            ),
            child: Row(children: [
              Icon(t.icon, size: 13, color: const Color(0xFFFFD000)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
              ),
              GestureDetector(
                onTap: widget.onClose,
                child: const Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
            child: Row(children: [
              Icon(t.icon, size: 26, color: const Color(0xFFF5B800)),
              const SizedBox(width: 8),
              Expanded(child: Text(t.text, style: Xp.text)),
            ]),
          ),
        ]),
      ),
    );
    return SizeTransition(
      sizeFactor: CurvedAnimation(parent: _a, curve: Curves.easeOut),
      axisAlignment: 1,
      child: FadeTransition(opacity: _a, child: card),
    );
  }
}
