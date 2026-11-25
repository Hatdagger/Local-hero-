import 'dart:convert';
import 'dart:typed_data';

import 'bytes.dart';

/// AIM "Send File" (OFT2) headers, as spoken by AIM 5.x and Pidgin.
///
/// After two devices connect, every step is one header: the sender offers a
/// file ([prompt]), the receiver says "go" ([ack]), the raw file bytes follow,
/// then the receiver says it got them ([done]). Repeat for the next file.
///
/// The classic header only has room for 4 GB sizes. Bigger files (phone
/// videos) carry their real size in a few spare bytes ("SZ64"), which classic
/// clients ignore.
class OftHeader {
  static const prompt = 0x0101;
  static const ack = 0x0202;
  static const done = 0x0204;

  /// Bytes before the file name.
  static const fixedLength = 192;
  static const minLength = 256;

  final int type;
  final Uint8List cookie;
  final int totalFiles;
  final int filesLeft;
  final int totalSize;
  final int size;
  final int modTime;
  final int received;
  final String name;

  OftHeader({
    required this.type,
    required this.cookie,
    this.totalFiles = 1,
    this.filesLeft = 1,
    this.totalSize = 0,
    this.size = 0,
    this.modTime = 0,
    this.received = 0,
    this.name = '',
  });

  OftHeader copyWith({int? type, int? received}) => OftHeader(
        type: type ?? this.type,
        cookie: cookie,
        totalFiles: totalFiles,
        filesLeft: filesLeft,
        totalSize: totalSize,
        size: size,
        modTime: modTime,
        received: received ?? this.received,
        name: name,
      );

  static int _u32(int v) => v > 0xffffffff ? 0xffffffff : v;

  Uint8List encode() {
    // Names go as UTF-8 (encoding 0x0000 means plain ASCII to classic clients,
    // which is what most file names are anyway).
    final nameBytes = utf8.encode(name.replaceAll('\u0000', ''));
    final nameField = Uint8List(nameBytes.length + 1 < 64 ? 64 : nameBytes.length + 1)..setRange(0, nameBytes.length, nameBytes);
    final idString = Uint8List(32)..setRange(0, 13, ascii.encode('Cool FileXfer'));
    final dummy = Uint8List(69);
    if (size > 0xffffffff || totalSize > 0xffffffff) {
      dummy.setRange(0, 4, ascii.encode('SZ64'));
      final bd = ByteData.sublistView(dummy);
      bd.setUint64(4, size);
      bd.setUint64(12, totalSize);
    }
    final w = ByteWriter()
      ..bytes(ascii.encode('OFT2'))
      ..u16(fixedLength + nameField.length)
      ..u16(type)
      ..bytes(cookie)
      ..u16(0) // encryption
      ..u16(0) // compression
      ..u16(totalFiles)
      ..u16(filesLeft)
      ..u16(1) // parts
      ..u16(1) // parts left
      ..u32(_u32(totalSize))
      ..u32(_u32(size))
      ..u32(modTime)
      ..u32(0xffff0000) // checksum (not used; TCP already checks the data)
      ..u32(0xffff0000) // resource fork checksum
      ..u32(0) // resource fork size
      ..u32(0) // creation time
      ..u32(0xffff0000) // resource fork checksum
      ..u32(_u32(received))
      ..u32(0xffff0000) // received checksum
      ..bytes(idString)
      ..u8(0x20) // flags
      ..u8(0x1c) // name offset
      ..u8(0x11) // size offset
      ..bytes(dummy)
      ..bytes(Uint8List(16)) // mac file info
      ..u16(0) // name encoding: ASCII / UTF-8
      ..u16(0) // language
      ..bytes(nameField);
    return w.toBytes();
  }

  /// Length of the header starting with [first6] ("OFT2" + length), or throws.
  static int lengthOf(Uint8List first6) {
    if (first6.length < 6 || ascii.decode(first6.sublist(0, 4), allowInvalid: true) != 'OFT2') {
      throw const FormatException('Not a file transfer connection');
    }
    final n = (first6[4] << 8) | first6[5];
    if (n < minLength || n > 8192) throw const FormatException('Bad file transfer header');
    return n;
  }

  static OftHeader parse(Uint8List h) {
    lengthOf(h);
    final r = ByteReader(h, 6);
    final type = r.u16();
    final cookie = Uint8List.fromList(r.bytes(8));
    r.u16();
    r.u16();
    final totalFiles = r.u16();
    final filesLeft = r.u16();
    r.u16();
    r.u16();
    var totalSize = r.u32();
    var size = r.u32();
    final modTime = r.u32();
    r.u32();
    r.u32();
    r.u32();
    r.u32();
    r.u32();
    final received = r.u32();
    r.u32();
    r.bytes(32);
    r.u8();
    r.u8();
    r.u8();
    final dummy = r.bytes(69);
    if (ascii.decode(dummy.sublist(0, 4), allowInvalid: true) == 'SZ64') {
      final bd = ByteData.sublistView(dummy);
      size = bd.getUint64(4);
      totalSize = bd.getUint64(12);
    }
    r.bytes(16);
    final enc = r.u16();
    r.u16();
    final raw = r.rest();
    final end = raw.indexOf(0);
    final nb = end < 0 ? raw : raw.sublist(0, end);
    final String name;
    if (enc == 0x0002) {
      // UTF-16BE from classic clients
      final units = <int>[];
      for (var i = 0; i + 1 < raw.length; i += 2) {
        final u = (raw[i] << 8) | raw[i + 1];
        if (u == 0) break;
        units.add(u);
      }
      name = String.fromCharCodes(units);
    } else {
      name = utf8.decode(nb, allowMalformed: true);
    }
    return OftHeader(
      type: type,
      cookie: cookie,
      totalFiles: totalFiles,
      filesLeft: filesLeft,
      totalSize: totalSize,
      size: size,
      modTime: modTime,
      received: received,
      name: name,
    );
  }
}

/// The file details inside a Send File invite (rendezvous TLV 0x2711), plus
/// our own 64-bit total size (TLV 0x7a03) for transfers over 4 GB.
class OftOffer {
  static const tagServiceData = 0x2711;
  static const tagNameCharset = 0x2712;
  static const tagBigTotal = 0x7a03;
  static const tagMessage = 0x000c;

  final int count;
  final int totalSize;

  /// The file name, or for several files the name of the first one.
  final String name;

  const OftOffer(this.count, this.totalSize, this.name);

  List<(int, List<int>)> toTlvs() {
    final w = ByteWriter()
      ..u16(count > 1 ? 2 : 1)
      ..u16(count)
      ..u32(totalSize > 0xffffffff ? 0xffffffff : totalSize)
      ..bytes(utf8.encode(name))
      ..u8(0);
    final big = ByteData(8)..setUint64(0, totalSize);
    return [
      (tagServiceData, w.toBytes()),
      (tagNameCharset, ascii.encode('utf-8')),
      (tagBigTotal, big.buffer.asUint8List()),
    ];
  }

  static OftOffer? fromTlvs(TlvList tlvs) {
    final v = tlvs[tagServiceData]?.value;
    if (v == null || v.length < 8) return null;
    final r = ByteReader(v);
    r.u16();
    final count = r.u16();
    var total = r.u32();
    final raw = r.rest();
    final end = raw.indexOf(0);
    final charset = tlvs[tagNameCharset]?.asString.toLowerCase() ?? '';
    final nb = end < 0 ? raw : raw.sublist(0, end);
    final name = charset.contains('utf-8') || charset.contains('us-ascii') || charset.isEmpty
        ? utf8.decode(nb, allowMalformed: true)
        : latin1.decode(nb);
    final big = tlvs[tagBigTotal]?.value;
    if (big != null && big.length == 8) total = ByteData.sublistView(big).getUint64(0);
    return OftOffer(count < 1 ? 1 : count, total, name);
  }
}

/// A file name that's safe to save: no folders, no odd characters.
String safeFileName(String name) {
  var n = name.split(RegExp(r'[\\/]')).last.trim();
  n = n.replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_');
  while (n.startsWith('.')) {
    n = n.substring(1);
  }
  if (n.isEmpty) n = 'file';
  if (n.length > 120) {
    final dot = n.lastIndexOf('.');
    final ext = dot > 0 && n.length - dot <= 10 ? n.substring(dot) : '';
    n = n.substring(0, 120 - ext.length) + ext;
  }
  return n;
}

/// "512 KB", "3.4 MB", "1.2 GB".
String formatBytes(num n) {
  if (n < 1024) return '${n.round()} bytes';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = n / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v >= 100 || i == 0 ? v.round() : v.toStringAsFixed(1)} ${units[i]}';
}
