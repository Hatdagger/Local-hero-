import 'dart:convert';
import 'dart:typed_data';

/// Big-endian byte writer used to build FLAP/SNAC payloads.
class ByteWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);

  void u8(int v) => _b.addByte(v & 0xff);

  void u16(int v) {
    _b.addByte((v >> 8) & 0xff);
    _b.addByte(v & 0xff);
  }

  void u32(int v) {
    u16((v >> 16) & 0xffff);
    u16(v & 0xffff);
  }

  void bytes(List<int> b) => _b.add(b);

  /// u8 length-prefixed string (screen names).
  void str8(String s) {
    final e = ascii.encode(_asciiSafe(s));
    u8(e.length);
    bytes(e);
  }

  /// u16 length-prefixed string.
  void str16(String s) {
    final e = utf8.encode(s);
    u16(e.length);
    bytes(e);
  }

  void tlv(int type, List<int> data) {
    u16(type);
    u16(data.length);
    bytes(data);
  }

  void tlvString(int type, String s) => tlv(type, utf8.encode(s));

  void tlvU8(int type, int v) => tlv(type, [v & 0xff]);

  void tlvU16(int type, int v) => tlv(type, [(v >> 8) & 0xff, v & 0xff]);

  void tlvU32(int type, int v) => tlv(type, [
        (v >> 24) & 0xff,
        (v >> 16) & 0xff,
        (v >> 8) & 0xff,
        v & 0xff,
      ]);

  int get length => _b.length;

  Uint8List toBytes() => _b.toBytes();

  static String _asciiSafe(String s) =>
      String.fromCharCodes(s.codeUnits.where((c) => c > 0 && c < 128));
}

class ByteReader {
  final Uint8List d;
  int pos;
  final int end;

  ByteReader(List<int> data, [this.pos = 0, int? end])
      : d = data is Uint8List ? data : Uint8List.fromList(data),
        end = end ?? data.length;

  int get remaining => end - pos;
  bool get isEmpty => pos >= end;

  void _need(int n) {
    if (pos + n > end) {
      throw const FormatException('OSCAR packet truncated');
    }
  }

  int u8() {
    _need(1);
    return d[pos++];
  }

  int u16() {
    _need(2);
    final v = (d[pos] << 8) | d[pos + 1];
    pos += 2;
    return v;
  }

  int u32() {
    _need(4);
    final v = (d[pos] << 24) | (d[pos + 1] << 16) | (d[pos + 2] << 8) | d[pos + 3];
    pos += 4;
    return v;
  }

  Uint8List bytes(int n) {
    _need(n);
    final v = Uint8List.sublistView(d, pos, pos + n);
    pos += n;
    return v;
  }

  Uint8List rest() => bytes(remaining);

  String str8() => latin1.decode(bytes(u8()));

  String str16() => utf8.decode(bytes(u16()), allowMalformed: true);

  /// Reads TLVs until the end of the reader (or [count] TLVs if given).
  TlvList tlvs([int? count]) {
    final list = <Tlv>[];
    while (!isEmpty && (count == null || list.length < count)) {
      if (remaining < 4) break;
      final t = u16();
      final l = u16();
      if (l > remaining) break;
      list.add(Tlv(t, bytes(l)));
    }
    return TlvList(list);
  }

  /// Reads a block of TLVs whose total byte length is given first as u16.
  TlvList tlvBlockByLength() {
    final len = u16();
    final sub = ByteReader(d, pos, pos + len);
    pos += len;
    return sub.tlvs();
  }
}

class Tlv {
  final int type;
  final Uint8List value;
  const Tlv(this.type, this.value);

  int get asU8 => value.isEmpty ? 0 : value[0];
  int get asU16 => value.length < 2 ? 0 : (value[0] << 8) | value[1];
  int get asU32 => value.length < 4
      ? asU16
      : (value[0] << 24) | (value[1] << 16) | (value[2] << 8) | value[3];
  String get asString => utf8.decode(value, allowMalformed: true);
  ByteReader get reader => ByteReader(value);
}

class TlvList {
  final List<Tlv> items;
  const TlvList(this.items);

  Tlv? operator [](int type) {
    for (final t in items) {
      if (t.type == type) return t;
    }
    return null;
  }

  bool has(int type) => this[type] != null;
}

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// AIM screen names compare case-insensitively and ignore spaces.
String normalizeSn(String sn) => sn.replaceAll(' ', '').toLowerCase();
