import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'history.dart';

/// Longest side of a picture sent over Direct Connect.
const kPictureMaxSide = 1600;

/// Pictures already small enough go as they are (GIFs keep their animation).
const kPictureKeepBytes = 1536 * 1024;

/// Makes a picture ready to send: small JPEG/PNG/GIF files go as they are,
/// anything else is shrunk to [kPictureMaxSide] and saved as JPEG.
/// Returns null if it isn't a picture.
Future<Uint8List?> preparePicture(Uint8List bytes) async {
  final ext = pictureExtension(bytes);
  if (bytes.length <= kPictureKeepBytes && (ext == '.jpg' || ext == '.png' || ext == '.gif')) return bytes;
  return Isolate.run(() {
    final im = img.decodeImage(bytes);
    if (im == null) return null;
    var out = im;
    final side = im.width > im.height ? im.width : im.height;
    if (side > kPictureMaxSide) {
      out = im.width >= im.height
          ? img.copyResize(im, width: kPictureMaxSide, interpolation: img.Interpolation.average)
          : img.copyResize(im, height: kPictureMaxSide, interpolation: img.Interpolation.average);
    }
    return Uint8List.fromList(img.encodeJpg(out, quality: 85));
  });
}
