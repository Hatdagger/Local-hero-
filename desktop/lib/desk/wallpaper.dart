import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'window_manager.dart';
import 'xp_theme.dart';

/// Built-in backgrounds (drawn in code), or 'image' for a picture of yours,
/// or 'none' for a plain colour.
const kBuiltIn = {
  'none': '(None)',
  'hills': 'Green Hills',
  'dusk': 'Dusk',
  'ripple': 'Blue Ripple',
};

const kPositions = {'stretch': 'Stretch', 'fill': 'Fill', 'fit': 'Fit', 'center': 'Center', 'tile': 'Tile'};

const kColors = [
  Color(0xFF3A6EA5),
  Color(0xFF004E98),
  Color(0xFF008080),
  Color(0xFF000000),
  Color(0xFF5A4E9A),
  Color(0xFF3F7F3F),
  Color(0xFF8C4A2F),
  Color(0xFF808080),
];

class WallpaperSettings extends ChangeNotifier {
  String kind = 'hills';
  String? imagePath;
  String position = 'stretch';
  Color color = const Color(0xFF3A6EA5);

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    kind = p.getString('wp.kind') ?? 'hills';
    imagePath = p.getString('wp.image');
    position = p.getString('wp.position') ?? 'stretch';
    color = Color(p.getInt('wp.color') ?? 0xFF3A6EA5);
    if (kind == 'image' && (imagePath == null || !File(imagePath!).existsSync())) kind = 'hills';
  }

  Future<void> apply({required String kind, String? imagePath, required String position, required Color color}) async {
    this.kind = kind;
    this.imagePath = imagePath;
    this.position = position;
    this.color = color;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString('wp.kind', kind);
    if (imagePath != null) await p.setString('wp.image', imagePath);
    await p.setString('wp.position', position);
    await p.setInt('wp.color', color.toARGB32());
  }
}

/// The desktop background itself.
class WallpaperView extends StatelessWidget {
  const WallpaperView({super.key, required this.kind, this.imagePath, required this.position, required this.color});
  final String kind;
  final String? imagePath;
  final String position;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (kind == 'image' && imagePath != null) {
      final img = FileImage(File(imagePath!));
      final (fit, repeat, align) = switch (position) {
        'center' => (BoxFit.none, ImageRepeat.noRepeat, Alignment.center),
        'tile' => (BoxFit.none, ImageRepeat.repeat, Alignment.topLeft),
        'fill' => (BoxFit.cover, ImageRepeat.noRepeat, Alignment.center),
        'fit' => (BoxFit.contain, ImageRepeat.noRepeat, Alignment.center),
        _ => (BoxFit.fill, ImageRepeat.noRepeat, Alignment.center),
      };
      return Container(
        decoration: BoxDecoration(
          color: color,
          image: DecorationImage(image: img, fit: fit, repeat: repeat, alignment: align),
        ),
      );
    }
    if (kind == 'none') return ColoredBox(color: color);
    return CustomPaint(painter: _BuiltInPainter(kind), child: const SizedBox.expand());
  }
}

class _BuiltInPainter extends CustomPainter {
  _BuiltInPainter(this.kind);
  final String kind;

  @override
  void paint(Canvas canvas, Size s) {
    final full = Offset.zero & s;
    switch (kind) {
      case 'dusk':
        canvas.drawRect(
            full,
            Paint()
              ..shader = const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF1B2A5E), Color(0xFF7B4B8F), Color(0xFFF09A5B)],
              ).createShader(full));
        final hill = Path()
          ..moveTo(0, s.height * 0.78)
          ..quadraticBezierTo(s.width * 0.3, s.height * 0.62, s.width * 0.62, s.height * 0.76)
          ..quadraticBezierTo(s.width * 0.85, s.height * 0.86, s.width, s.height * 0.72)
          ..lineTo(s.width, s.height)
          ..lineTo(0, s.height)
          ..close();
        canvas.drawPath(hill, Paint()..color = const Color(0xFF221A33));
      case 'ripple':
        canvas.drawRect(
            full,
            Paint()
              ..shader = const RadialGradient(
                center: Alignment(-0.3, -0.4),
                radius: 1.3,
                colors: [Color(0xFF4FA3F7), Color(0xFF1B4FA8), Color(0xFF0A2A66)],
              ).createShader(full));
        final ring = Paint()
          ..style = PaintingStyle.stroke
          ..color = const Color(0x22FFFFFF);
        for (var i = 1; i < 14; i++) {
          ring.strokeWidth = 18.0 - i;
          canvas.drawCircle(Offset(s.width * 0.35, s.height * 0.3), i * s.shortestSide * 0.09, ring);
        }
      default: // hills
        canvas.drawRect(
            full,
            Paint()
              ..shader = const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF2B66D2), Color(0xFF5C97E6), Color(0xFFA9CCF3)],
                stops: [0, 0.45, 0.75],
              ).createShader(full));
        final cloud = Paint()
          ..color = const Color(0xCCFFFFFF)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22);
        for (final c in const [(0.18, 0.22, 0.16), (0.32, 0.18, 0.11), (0.7, 0.3, 0.14), (0.86, 0.24, 0.09)]) {
          canvas.drawOval(
              Rect.fromCenter(
                  center: Offset(s.width * c.$1, s.height * c.$2), width: s.width * c.$3 * 2, height: s.height * 0.09),
              cloud);
        }
        final back = Path()
          ..moveTo(0, s.height * 0.72)
          ..quadraticBezierTo(s.width * 0.25, s.height * 0.6, s.width * 0.55, s.height * 0.66)
          ..quadraticBezierTo(s.width * 0.8, s.height * 0.7, s.width, s.height * 0.6)
          ..lineTo(s.width, s.height)
          ..lineTo(0, s.height)
          ..close();
        canvas.drawPath(back, Paint()..color = const Color(0xFF4C9A35));
        final front = Path()
          ..moveTo(0, s.height * 0.86)
          ..quadraticBezierTo(s.width * 0.45, s.height * 0.62, s.width, s.height * 0.8)
          ..lineTo(s.width, s.height)
          ..lineTo(0, s.height)
          ..close();
        canvas.drawPath(
            front,
            Paint()
              ..shader = const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF7BC74A), Color(0xFF3E8A23)],
              ).createShader(Rect.fromLTWH(0, s.height * 0.62, s.width, s.height * 0.38)));
    }
  }

  @override
  bool shouldRepaint(_BuiltInPainter old) => old.kind != kind;
}

/// Display Properties: pick a background, a position and a colour.
DeskWindow displayPropertiesWindow() => DeskWindow(
      id: 'display',
      title: 'Display Properties',
      icon: Icons.desktop_windows,
      size: const Size(400, 470),
      resizable: false,
      canMaximize: false,
      content: (c, w) => _DisplayProperties(w: w),
    );

class _DisplayProperties extends StatefulWidget {
  const _DisplayProperties({required this.w});
  final DeskWindow w;

  @override
  State<_DisplayProperties> createState() => _DisplayPropertiesState();
}

class _DisplayPropertiesState extends State<_DisplayProperties> {
  late WallpaperSettings _s;
  late String _kind;
  String? _image;
  late String _position;
  late Color _color;
  bool _init = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_init) return;
    _init = true;
    _s = context.read<WallpaperSettings>();
    _kind = _s.kind;
    _image = _s.imagePath;
    _position = _s.position;
    _color = _s.color;
  }

  Future<void> _browse() async {
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.image);
      final path = r?.files.single.path;
      if (path == null) return;
      final dir = await getApplicationSupportDirectory();
      final ext = path.contains('.') ? path.substring(path.lastIndexOf('.')) : '.img';
      final dest = '${dir.path}/wallpaper_${DateTime.now().millisecondsSinceEpoch}$ext';
      await File(path).copy(dest);
      setState(() {
        _image = dest;
        _kind = 'image';
      });
    } catch (_) {}
  }

  Future<void> _apply() => _s.apply(kind: _kind, imagePath: _image, position: _position, color: _color);

  @override
  Widget build(BuildContext context) {
    final wm = context.read<WindowManager>();
    final entries = <(String, String)>[
      for (final e in kBuiltIn.entries) (e.key, e.value),
      if (_image != null) ('image', _image!.split('/').last),
    ];
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // A little monitor showing the choice.
        Center(
          child: Container(
            width: 200,
            height: 140,
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 18),
            decoration: BoxDecoration(
              color: const Color(0xFFCFCBC0),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF8B8878)),
            ),
            child: ClipRect(
              child: WallpaperView(kind: _kind, imagePath: _image, position: _position, color: _color),
            ),
          ),
        ),
        const SizedBox(height: 10),
        const Text('Background:', style: Xp.text),
        const SizedBox(height: 4),
        Expanded(
          child: Container(
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Xp.fieldBorder)),
            child: ListView(children: [
              for (final e in entries)
                GestureDetector(
                  onTap: () => setState(() => _kind = e.$1),
                  child: Container(
                    color: _kind == e.$1 ? Xp.selection : null,
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Text(e.$2,
                        style: Xp.text.copyWith(color: _kind == e.$1 ? Colors.white : Colors.black)),
                  ),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          XpButton(label: 'Browse...', onPressed: _browse),
          const Spacer(),
          const Text('Position: ', style: Xp.text),
          DropdownButton<String>(
            value: _position,
            isDense: true,
            style: Xp.text,
            items: [
              for (final e in kPositions.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) => setState(() => _position = v ?? _position),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          const Text('Color: ', style: Xp.text),
          for (final c in kColors)
            GestureDetector(
              onTap: () => setState(() => _color = c),
              child: Container(
                width: 22,
                height: 18,
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  color: c,
                  border: Border.all(color: _color == c ? Colors.black : const Color(0xFF8B8878), width: _color == c ? 2 : 1),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          XpButton(
              label: 'OK',
              isDefault: true,
              onPressed: () async {
                await _apply();
                wm.close(widget.w.id);
              }),
          const SizedBox(width: 6),
          XpButton(label: 'Cancel', onPressed: () => wm.close(widget.w.id)),
          const SizedBox(width: 6),
          XpButton(label: 'Apply', onPressed: _apply),
        ]),
      ]),
    );
  }
}
