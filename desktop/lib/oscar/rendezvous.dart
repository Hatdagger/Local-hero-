import 'dart:io';
import 'dart:typed_data';

import 'bytes.dart';

/// AIM capability for Direct IM ("Direct Connect").
final capDirectIm = unhex('094613454c7f11d18222444553540000');

/// AIM capability for Send File (OFT file transfer).
final capSendFile = unhex('094613434c7f11d18222444553540000');

/// Our own extra TLV in a proposal: every IPv4 address (4 bytes each) the
/// sender thinks it can be reached on. Classic clients ignore unknown TLVs.
const tagAllAddresses = 0x7a01;

/// Our own extra TLV: public IPv6 addresses (16 bytes each). Many phone and
/// home connections have these with no router in the way, so they often
/// connect directly when IPv4 can't.
const tagAddresses6 = 0x7a02;

/// Our own extra TLV: one piece of a hole-punching description (see
/// HolePuncher): kind (1 offer, 2 answer), piece number, piece count, data.
const tagSignal = 0x7a20;

/// One ICBM channel-2 "rendezvous" payload (TLV 0x0005): a proposal to
/// connect directly, an accept, or a cancel. Only this tiny handshake goes
/// through the server; the connection itself is device to device.
class Rendezvous {
  static const propose = 0x0000;
  static const cancel = 0x0001;
  static const accept = 0x0002;

  static const reasonUnknown = 0x0000;
  static const reasonDeclined = 0x0001;
  static const reasonTimeout = 0x0002;

  final int type;
  final Uint8List cookie;
  final Uint8List cap;
  final TlvList tlvs;

  Rendezvous(this.type, this.cookie, this.cap, this.tlvs);

  bool get isDirectIm => hex(cap) == hex(capDirectIm);
  bool get isSendFile => hex(cap) == hex(capSendFile);

  /// 1 = first proposal, 2 = "you can't reach me, I'll listen instead".
  int get seq => tlvs[0x000a]?.asU16 ?? 1;
  int? get port => tlvs[0x0005]?.asU16;
  int get cancelReason => tlvs[0x000b]?.asU16 ?? reasonUnknown;

  /// Addresses to try, best first: what the sender says (its own network),
  /// what the server saw, then any extra ones the sender listed.
  List<String> get addresses {
    final out = <String>[];
    void add(Uint8List? v) {
      if (v == null || v.length != 4) return;
      final ip = v.join('.');
      if (ip == '0.0.0.0' || out.contains(ip)) return;
      out.add(ip);
    }

    add(tlvs[0x0002]?.value);
    final extra = tlvs[tagAllAddresses]?.value;
    if (extra != null) {
      for (var i = 0; i + 4 <= extra.length; i += 4) {
        add(Uint8List.sublistView(extra, i, i + 4));
      }
    }
    add(tlvs[0x0003]?.value);
    add(tlvs[0x0004]?.value);
    // Loopback last: only useful when both apps run on one machine.
    return [...out.where((a) => !a.startsWith('127.')), ...out.where((a) => a.startsWith('127.'))];
  }

  /// IPv6 addresses the sender listed (see [tagAddresses6]).
  List<String> get addresses6 {
    final out = <String>[];
    final v = tlvs[tagAddresses6]?.value;
    if (v == null) return out;
    for (var i = 0; i + 16 <= v.length; i += 16) {
      try {
        final a = InternetAddress.fromRawAddress(Uint8List.fromList(v.sublist(i, i + 16)),
            type: InternetAddressType.IPv6);
        if (!out.contains(a.address)) out.add(a.address);
      } catch (_) {}
    }
    return out;
  }

  static Rendezvous parse(Uint8List data) {
    final r = ByteReader(data);
    final type = r.u16();
    final cookie = Uint8List.fromList(r.bytes(8));
    final cap = Uint8List.fromList(r.bytes(16));
    return Rendezvous(type, cookie, cap, r.tlvs());
  }

  static Uint8List _ip(String ip) {
    final a = InternetAddress.tryParse(ip);
    if (a == null || a.type != InternetAddressType.IPv4) return Uint8List(4);
    return Uint8List.fromList(a.rawAddress);
  }

  static ByteWriter _head(int type, Uint8List cookie, [Uint8List? cap]) => ByteWriter()
    ..u16(type)
    ..bytes(cookie)
    ..bytes(cap ?? capDirectIm);

  /// A Direct IM proposal like AIM 5 sends: "connect to me at ip:port".
  static Uint8List encodePropose(Uint8List cookie,
      {required String ip,
      required int port,
      int seq = 1,
      List<String> extra = const [],
      List<String> ipv6 = const [],
      Uint8List? cap,
      List<(int, List<int>)> moreTlvs = const []}) {
    final raw = _ip(ip);
    final xor = Uint8List.fromList(raw.map((b) => b ^ 0xff).toList());
    final w = _head(propose, cookie, cap)
      ..tlv(0x0002, raw)
      ..tlv(0x0003, raw) // the server replaces this with the address it sees
      ..tlvU16(0x0005, port)
      ..tlvU16(0x000a, seq)
      ..tlv(0x000f, const [])
      ..tlv(0x0016, xor)
      ..tlvU16(0x0017, port ^ 0xffff);
    final all = <int>[];
    for (final e in extra) {
      if (e == ip) continue;
      final b = _ip(e);
      if (b.any((x) => x != 0)) all.addAll(b);
    }
    if (all.isNotEmpty) w.tlv(tagAllAddresses, all);
    final six = <int>[];
    for (final e in ipv6) {
      final a = InternetAddress.tryParse(e);
      if (a != null && a.type == InternetAddressType.IPv6) six.addAll(a.rawAddress);
    }
    if (six.isNotEmpty) w.tlv(tagAddresses6, six);
    for (final (t, v) in moreTlvs) {
      w.tlv(t, v);
    }
    return w.toBytes();
  }

  /// A small message carrying [tlvs] (hole-punching signals).
  static Uint8List encodeSignal(Uint8List cookie, Uint8List cap, List<(int, List<int>)> tlvs) {
    final w = _head(accept, cookie, cap);
    for (final (t, v) in tlvs) {
      w.tlv(t, v);
    }
    return w.toBytes();
  }

  static Uint8List encodeAccept(Uint8List cookie, {Uint8List? cap}) => _head(accept, cookie, cap).toBytes();

  static Uint8List encodeCancel(Uint8List cookie, [int reason = reasonDeclined, Uint8List? cap]) =>
      (_head(cancel, cookie, cap)..tlvU16(0x000b, reason)).toBytes();
}
