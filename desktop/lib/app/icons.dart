import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../oscar/bytes.dart';

/// Classic AIM 5.x buddy icon limits.
const int kIconSide = 48;
const int kIconMaxBytes = 7168;

/// A picture decoded at a manageable size for cropping on the device.
class WorkingImage {
  final img.Image image;
  final ui.Image preview;
  WorkingImage(this.image, this.preview);
  int get width => image.width;
  int get height => image.height;
}

Future<WorkingImage> loadWorkingImage(Uint8List bytes, {int maxSide = 1024}) async {
  final probe = await ui.instantiateImageCodec(bytes);
  final first = await probe.getNextFrame();
  final w0 = first.image.width, h0 = first.image.height;
  first.image.dispose();
  probe.dispose();
  int? tw, th;
  if (w0 >= h0 && w0 > maxSide) tw = maxSide;
  if (h0 > w0 && h0 > maxSide) th = maxSide;
  final codec = await ui.instantiateImageCodec(bytes, targetWidth: tw, targetHeight: th);
  final frame = await codec.getNextFrame();
  final pic = frame.image;
  final data = await pic.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) throw const FormatException('Could not read that picture');
  final im = img.Image.fromBytes(
    width: pic.width,
    height: pic.height,
    bytes: data.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return WorkingImage(im, pic);
}

/// Crop [rect] (in working-image pixels), scale to 48x48 and encode within the
/// size limit. GIF first (most compatible with old clients), JPEG if too big.
Uint8List makeCroppedIcon(WorkingImage src, ui.Rect rect) {
  final x = rect.left.round().clamp(0, src.width - 1).toInt();
  final y = rect.top.round().clamp(0, src.height - 1).toInt();
  final w = rect.width.round().clamp(1, src.width - x).toInt();
  final h = rect.height.round().clamp(1, src.height - y).toInt();
  final cropped = img.copyCrop(src.image, x: x, y: y, width: w, height: h);
  final sized = img.copyResize(cropped, width: kIconSide, height: kIconSide, interpolation: img.Interpolation.average);
  return _encodeWithinLimit(sized);
}

/// Shrink the whole picture to fit in 48x48, padding with [background].
Uint8List makeFittedIcon(WorkingImage src, {int background = 0xffffffff}) {
  final scale = kIconSide / (src.width > src.height ? src.width : src.height);
  final w = (src.width * scale).round().clamp(1, kIconSide).toInt();
  final h = (src.height * scale).round().clamp(1, kIconSide).toInt();
  final sized = img.copyResize(src.image, width: w, height: h, interpolation: img.Interpolation.average);
  final canvas = img.Image(width: kIconSide, height: kIconSide, numChannels: 4);
  img.fill(canvas,
      color: img.ColorRgba8((background >> 16) & 0xff, (background >> 8) & 0xff, background & 0xff, (background >> 24) & 0xff));
  img.compositeImage(canvas, sized, dstX: (kIconSide - w) ~/ 2, dstY: (kIconSide - h) ~/ 2);
  return _encodeWithinLimit(canvas);
}

Uint8List _encodeWithinLimit(img.Image im) {
  final gif = img.encodeGif(im);
  if (gif.length <= kIconMaxBytes) return gif;
  for (final q in const [90, 80, 65, 50, 35]) {
    final jpg = img.encodeJpg(im, quality: q);
    if (jpg.length <= kIconMaxBytes) return jpg;
  }
  return img.encodeJpg(im, quality: 20);
}

/// On-disk cache of other people's buddy icons, keyed by hash.
class IconCache {
  Directory? _dir;
  final Map<String, Uint8List> _mem = {};

  Future<Directory> dir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}icons');
    await d.create(recursive: true);
    return _dir = d;
  }

  Uint8List? memory(List<int> hash) => _mem[hex(hash)];

  Future<Uint8List?> get(List<int> hash) async {
    final k = hex(hash);
    final m = _mem[k];
    if (m != null) return m;
    final f = File('${(await dir()).path}${Platform.pathSeparator}$k.img');
    if (await f.exists()) return _mem[k] = await f.readAsBytes();
    return null;
  }

  Future<void> put(List<int> hash, Uint8List bytes) async {
    final k = hex(hash);
    _mem[k] = bytes;
    await File('${(await dir()).path}${Platform.pathSeparator}$k.img').writeAsBytes(bytes, flush: true);
  }

  Future<String> saveOwn(String sn, Uint8List bytes) async {
    final f = File('${(await dir()).path}${Platform.pathSeparator}own_${normalizeSn(sn)}.img');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }
}
