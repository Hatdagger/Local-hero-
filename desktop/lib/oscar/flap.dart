import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'bytes.dart';

class FlapFrame {
  final int channel;
  final Uint8List data;
  const FlapFrame(this.channel, this.data);
}

class Snac {
  final int family;
  final int subtype;
  final int flags;
  final int reqId;
  final Uint8List data;
  const Snac(this.family, this.subtype, this.flags, this.reqId, this.data);

  ByteReader get reader => ByteReader(data);

  bool get moreFollows => (flags & 0x0001) != 0;

  static Snac parse(Uint8List raw) {
    final r = ByteReader(raw);
    final fam = r.u16();
    final sub = r.u16();
    final flags = r.u16();
    final req = r.u32();
    if ((flags & 0x8000) != 0 && r.remaining >= 2) {
      final skip = r.u16();
      r.bytes(min(skip, r.remaining));
    }
    return Snac(fam, sub, flags, req, r.rest());
  }

  @override
  String toString() =>
      'SNAC(0x${family.toRadixString(16)},0x${subtype.toRadixString(16)})';
}

class OscarTimeout implements Exception {
  final String what;
  OscarTimeout(this.what);
  @override
  String toString() => 'Timed out waiting for $what';
}

class ConnectionClosed implements Exception {
  final String reason;
  ConnectionClosed(this.reason);
  @override
  String toString() => 'Connection closed: $reason';
}

/// One TCP connection speaking FLAP framing.
class FlapConnection {
  final Socket _socket;
  int _seq = Random().nextInt(0x7fff);
  int _reqId = 1;
  Uint8List _buf = Uint8List(0);
  bool _closed = false;
  Timer? _keepAlive;

  final _frames = StreamController<FlapFrame>.broadcast();
  final _snacs = StreamController<Snac>.broadcast();
  final _done = Completer<String>();

  FlapConnection._(this._socket) {
    _socket.setOption(SocketOption.tcpNoDelay, true);
    _socket.listen(_onData,
        onError: (Object e) => _finish('socket error: $e'),
        onDone: () => _finish('server closed the connection'),
        cancelOnError: true);
  }

  static Future<FlapConnection> connect(String host, int port,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final s = await Socket.connect(host, port, timeout: timeout);
    return FlapConnection._(s);
  }

  Stream<FlapFrame> get frames => _frames.stream;
  Stream<Snac> get snacs => _snacs.stream;
  Future<String> get done => _done.future;
  bool get isClosed => _closed;
  String get remoteHost => _socket.remoteAddress.address;
  String? get localHost {
    try {
      return _socket.address.address;
    } catch (_) {
      return null;
    }
  }

  int nextReqId() {
    _reqId = (_reqId + 1) & 0x7fffffff;
    if (_reqId == 0) _reqId = 1;
    return _reqId;
  }

  void _onData(Uint8List chunk) {
    if (_buf.isEmpty) {
      _buf = chunk;
    } else {
      final nb = Uint8List(_buf.length + chunk.length);
      nb.setRange(0, _buf.length, _buf);
      nb.setRange(_buf.length, nb.length, chunk);
      _buf = nb;
    }
    var off = 0;
    while (_buf.length - off >= 6) {
      if (_buf[off] != 0x2a) {
        _finish('bad FLAP marker');
        return;
      }
      final ch = _buf[off + 1];
      final len = (_buf[off + 4] << 8) | _buf[off + 5];
      if (_buf.length - off < 6 + len) break;
      final data = Uint8List.fromList(_buf.sublist(off + 6, off + 6 + len));
      off += 6 + len;
      final frame = FlapFrame(ch, data);
      _frames.add(frame);
      if (ch == 2 && data.length >= 10) {
        try {
          _snacs.add(Snac.parse(data));
        } catch (_) {
          // ignore malformed SNAC
        }
      }
    }
    _buf = off == _buf.length ? Uint8List(0) : Uint8List.fromList(_buf.sublist(off));
  }

  void send(int channel, List<int> data) {
    if (_closed) throw ConnectionClosed('not connected');
    _seq = (_seq + 1) & 0xffff;
    final w = ByteWriter()
      ..u8(0x2a)
      ..u8(channel)
      ..u16(_seq)
      ..u16(data.length)
      ..bytes(data);
    _socket.add(w.toBytes());
  }

  /// Sends a SNAC and returns its request id.
  int sendSnac(int family, int subtype, List<int> data, {int? reqId}) {
    final id = reqId ?? nextReqId();
    final w = ByteWriter()
      ..u16(family)
      ..u16(subtype)
      ..u16(0)
      ..u32(id)
      ..bytes(data);
    send(2, w.toBytes());
    return id;
  }

  /// Waits for the first SNAC that matches any of [wanted] (family, subtype)
  /// pairs. Call this BEFORE sending the request so no reply is missed.
  Future<Snac> expect(List<(int, int)> wanted,
      {int? reqId, Duration timeout = const Duration(seconds: 20)}) {
    final c = Completer<Snac>();
    late StreamSubscription<Snac> sub;
    Timer? t;
    void finish() {
      t?.cancel();
      sub.cancel();
    }

    sub = snacs.listen((s) {
      if (reqId != null && s.reqId != reqId && s.subtype != 0x01) return;
      for (final w in wanted) {
        if (s.family == w.$1 && s.subtype == w.$2) {
          finish();
          if (!c.isCompleted) c.complete(s);
          return;
        }
      }
    });
    t = Timer(timeout, () {
      finish();
      if (!c.isCompleted) {
        c.completeError(OscarTimeout(wanted
            .map((w) => '0x${w.$1.toRadixString(16)}/0x${w.$2.toRadixString(16)}')
            .join(' or ')));
      }
    });
    done.then((reason) {
      finish();
      if (!c.isCompleted) c.completeError(ConnectionClosed(reason));
    });
    return c.future;
  }

  Future<FlapFrame> expectFrame(int channel,
      {Duration timeout = const Duration(seconds: 20)}) {
    return Future.any([
      frames.firstWhere((f) => f.channel == channel),
      done.then<FlapFrame>((r) => throw ConnectionClosed(r)),
    ]).timeout(timeout, onTimeout: () => throw OscarTimeout('FLAP channel $channel'));
  }

  void startKeepAlive([Duration every = const Duration(seconds: 50)]) {
    _keepAlive?.cancel();
    _keepAlive = Timer.periodic(every, (_) {
      if (!_closed) {
        try {
          send(5, const []);
        } catch (_) {}
      }
    });
  }

  void _finish(String reason) {
    if (_closed) return;
    _closed = true;
    _keepAlive?.cancel();
    try {
      _socket.destroy();
    } catch (_) {}
    if (!_done.isCompleted) _done.complete(reason);
    _frames.close();
    _snacs.close();
  }

  /// Polite sign-off (FLAP channel 4) then close.
  Future<void> close() async {
    if (_closed) return;
    try {
      send(4, const []);
      await _socket.flush();
    } catch (_) {}
    _finish('closed by client');
  }

  /// Simulates a dropped network link (used by tests).
  void debugKill() => _finish('debug kill');
}
