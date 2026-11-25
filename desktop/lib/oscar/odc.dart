import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'aim_html.dart';
import 'bytes.dart';

/// AIM "Direct IM" (ODC) framing, as spoken by AIM 5.x and Pidgin.
/// Every frame is a 76-byte "ODC2" header followed by an optional payload.
class OdcFrame {
  static const headerLength = 76;
  static const flagAutoReply = 0x0001;
  static const flagTyping = 0x0002;
  static const flagTyped = 0x0004;
  static const flagTypingEvent = 0x0008;
  static const flagCookie = 0x0060;

  final int type;
  final int subtype;
  final Uint8List cookie;
  final int encoding;
  final int flags;
  final String screenName;
  final Uint8List payload;

  OdcFrame({
    this.type = 0x0001,
    this.subtype = 0x0006,
    required this.cookie,
    this.encoding = 0,
    this.flags = 0,
    this.screenName = '',
    Uint8List? payload,
  }) : payload = payload ?? Uint8List(0);

  bool get isCookie => (flags & flagCookie) == flagCookie && payload.isEmpty;
  bool get isTyping => (flags & flagTypingEvent) != 0;

  /// 0 stopped, 1 typed (paused), 2 typing.
  int get typingState => (flags & flagTyping) != 0 ? 2 : ((flags & flagTyped) != 0 ? 1 : 0);

  Uint8List encode() {
    final sn = Uint8List(32);
    final snb = ascii.encode(String.fromCharCodes(screenName.codeUnits.where((c) => c > 0 && c < 128)));
    sn.setRange(0, min(31, snb.length), snb);
    final w = ByteWriter()
      ..bytes(ascii.encode('ODC2'))
      ..u16(headerLength)
      ..u16(type)
      ..u16(subtype)
      ..u16(0)
      ..bytes(cookie)
      ..u32(0)
      ..u32(0)
      ..u32(payload.length)
      ..u16(encoding)
      ..u32(0)
      ..u16(flags)
      ..u32(0)
      ..bytes(sn)
      ..bytes(payload);
    return w.toBytes();
  }
}

/// Collects bytes from the socket and cuts them into frames. Pictures can be
/// several megabytes, so chunks are kept as a list rather than re-copied.
class OdcParser {
  final int maxPayload;
  OdcParser({this.maxPayload = 12 * 1024 * 1024});

  final _chunks = <Uint8List>[];
  int _offset = 0;
  int _length = 0;
  Uint8List? _header;
  int _payloadLen = 0;

  /// Bytes received so far of the frame being read (for progress).
  int get pendingPayload => _header == null ? 0 : min(_length, _payloadLen);
  int get expectedPayload => _header == null ? 0 : _payloadLen;

  Uint8List _take(int n, {bool consume = true}) {
    final out = Uint8List(n);
    var w = 0, ci = 0, off = _offset;
    while (w < n) {
      final c = _chunks[ci];
      final k = min(c.length - off, n - w);
      out.setRange(w, w + k, c, off);
      w += k;
      off += k;
      if (off == c.length) {
        ci++;
        off = 0;
      }
    }
    if (consume) {
      _chunks.removeRange(0, ci);
      _offset = off;
      _length -= n;
    }
    return out;
  }

  /// Adds received bytes; returns any complete frames. Throws
  /// [FormatException] on garbage (the caller should hang up).
  List<OdcFrame> add(Uint8List chunk) {
    if (chunk.isNotEmpty) {
      _chunks.add(chunk);
      _length += chunk.length;
    }
    final out = <OdcFrame>[];
    while (true) {
      if (_header == null) {
        if (_length < 6) break;
        final pre = _take(6, consume: false);
        if (ascii.decode(pre.sublist(0, 4), allowInvalid: true) != 'ODC2') {
          throw const FormatException('Not a Direct IM connection');
        }
        final hl = (pre[4] << 8) | pre[5];
        if (hl < OdcFrame.headerLength || hl > 4096) throw const FormatException('Bad Direct IM header');
        if (_length < hl) break;
        final h = _take(hl);
        final r = ByteReader(h, 28);
        _payloadLen = r.u32();
        if (_payloadLen > maxPayload) throw const FormatException('Direct IM message too big');
        _header = h;
      }
      if (_length < _payloadLen) break;
      final h = _header!;
      final payload = _payloadLen == 0 ? Uint8List(0) : _take(_payloadLen);
      _header = null;
      final r = ByteReader(h, 6);
      final type = r.u16();
      final subtype = r.u16();
      r.u16();
      final cookie = Uint8List.fromList(r.bytes(8));
      r.bytes(8);
      r.u32();
      final enc = r.u16();
      r.u32();
      final flags = r.u16();
      r.u32();
      final snb = r.bytes(32);
      final end = snb.indexOf(0);
      out.add(OdcFrame(
        type: type,
        subtype: subtype,
        cookie: cookie,
        encoding: enc,
        flags: flags,
        screenName: latin1.decode(end < 0 ? snb : snb.sublist(0, end)),
        payload: payload,
      ));
    }
    return out;
  }
}

/// A picture inside a Direct IM.
class OdcImage {
  final int id;
  final Uint8List data;
  final String name;
  final int? width;
  final int? height;
  const OdcImage(this.id, this.data, {this.name = 'picture.jpg', this.width, this.height});
}

class DirectMessage {
  final String html;
  final String text;
  final List<OdcImage> images;
  final bool autoResponse;
  const DirectMessage(this.html, this.text, this.images, {this.autoResponse = false});
}

int _indexOfCi(Uint8List hay, String needle, [int from = 0]) {
  final n = ascii.encode(needle.toLowerCase());
  int low(int b) => (b >= 0x41 && b <= 0x5a) ? b + 0x20 : b;
  outer:
  for (var i = max(0, from); i + n.length <= hay.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (low(hay[i + j]) != n[j]) continue outer;
    }
    return i;
  }
  return -1;
}

String? _attr(String tag, String name) {
  final m = RegExp('\\b$name\\s*=\\s*("([^"]*)"|\'([^\']*)\'|([^\\s>]+))', caseSensitive: false).firstMatch(tag);
  if (m == null) return null;
  return m.group(2) ?? m.group(3) ?? m.group(4);
}

/// Builds a Direct IM payload: the message as AIM HTML with an `<IMG>` tag
/// per picture, then the pictures themselves in a `<BINARY>` section.
/// Returns (encoding, payload).
(int, Uint8List) encodeOdcMessage(String text, {List<OdcImage> images = const []}) {
  var html = textToAimHtml(text);
  if (images.isNotEmpty) {
    final tags = StringBuffer();
    for (final im in images) {
      tags.write('<IMG SRC="${escapeHtml(im.name)}" ID="${im.id}"');
      if (im.width != null && im.height != null) tags.write(' WIDTH="${im.width}" HEIGHT="${im.height}"');
      tags.write(' DATASIZE="${im.data.length}">');
    }
    final i = html.toUpperCase().lastIndexOf('</BODY>');
    html = i < 0 ? '$html$tags' : '${html.substring(0, i)}${text.isEmpty ? '' : '<BR>'}$tags${html.substring(i)}';
  }
  final (cs, body) = encodeImText(html);
  if (images.isEmpty) return (cs, body);
  final b = BytesBuilder(copy: false)
    ..add(body)
    ..add(ascii.encode('<BINARY>'));
  for (final im in images) {
    b
      ..add(ascii.encode('<DATA ID="${im.id}" SIZE="${im.data.length}">'))
      ..add(im.data)
      ..add(ascii.encode('</DATA>'));
  }
  b.add(ascii.encode('</BINARY>'));
  return (cs, b.toBytes());
}

/// Reads a Direct IM payload back into text and pictures.
DirectMessage decodeOdcMessage(Uint8List payload, int encoding, {bool autoResponse = false}) {
  final bin = _indexOfCi(payload, '<binary>');
  final textBytes = bin < 0 ? payload : Uint8List.sublistView(payload, 0, bin);
  final html = decodeImText(encoding, textBytes);
  final data = <int, Uint8List>{};
  if (bin >= 0) {
    var pos = bin + 8;
    while (true) {
      final start = _indexOfCi(payload, '<data', pos);
      if (start < 0) break;
      final gt = payload.indexOf(0x3e, start);
      if (gt < 0) break;
      final tag = latin1.decode(payload.sublist(start, gt + 1));
      final id = int.tryParse(_attr(tag, 'id') ?? '');
      final size = int.tryParse(_attr(tag, 'size') ?? '');
      if (id == null || size == null || size < 0 || gt + 1 + size > payload.length) break;
      data[id] = Uint8List.fromList(payload.sublist(gt + 1, gt + 1 + size));
      pos = gt + 1 + size;
    }
  }
  final images = <OdcImage>[];
  for (final m in RegExp(r'<img\b[^>]*>', caseSensitive: false).allMatches(html)) {
    final tag = m.group(0)!;
    final id = int.tryParse(_attr(tag, 'id') ?? '');
    final d = id == null ? null : data.remove(id);
    if (d == null) continue;
    images.add(OdcImage(id!, d,
        name: _attr(tag, 'src') ?? 'picture',
        width: int.tryParse(_attr(tag, 'width') ?? ''),
        height: int.tryParse(_attr(tag, 'height') ?? '')));
  }
  for (final e in data.entries) {
    images.add(OdcImage(e.key, e.value, name: 'picture'));
  }
  return DirectMessage(html, messageText(html), images, autoResponse: autoResponse);
}

/// An open Direct IM link to one buddy.
class OdcConnection {
  final Socket _socket;
  final Uint8List cookie;
  final String myName;
  final OdcParser _parser = OdcParser();
  final _frames = StreamController<OdcFrame>.broadcast();
  final _done = Completer<String>();
  bool _closed = false;
  StreamSubscription<Uint8List>? _sub;

  /// Frames that arrived before anyone listened (the first frame is read
  /// while the link is still being checked).
  final List<OdcFrame> _early = [];
  bool _listening = false;

  OdcConnection(this._socket, this.cookie, this.myName) {
    try {
      _socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    _sub = _socket.listen((chunk) {
      try {
        for (final f in _parser.add(chunk)) {
          if (_listening) {
            _frames.add(f);
          } else {
            _early.add(f);
            _earlyArrived?.complete();
            _earlyArrived = null;
          }
        }
        _progress?.call(_parser.pendingPayload, _parser.expectedPayload);
      } on FormatException catch (e) {
        _finish(e.message);
      }
    }, onError: (Object e) => _finish('$e'), onDone: () => _finish('closed'), cancelOnError: true);
  }

  Completer<void>? _earlyArrived;
  void Function(int got, int total)? _progress;

  /// Called while a big message (a picture) is coming in.
  set onProgress(void Function(int got, int total)? f) => _progress = f;

  String get remoteHost => _socket.remoteAddress.address;
  bool get isClosed => _closed;
  Future<String> get done => _done.future;

  /// Waits for the first frame (used to check the other side's cookie).
  Future<OdcFrame> firstFrame(Duration timeout) async {
    final end = DateTime.now().add(timeout);
    while (_early.isEmpty) {
      if (_closed) throw const SocketException('Direct IM link closed');
      final left = end.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('No Direct IM greeting');
      final c = _earlyArrived ??= Completer<void>();
      await Future.any([c.future, _done.future]).timeout(left, onTimeout: () => null);
    }
    return _early.removeAt(0);
  }

  /// Starts delivering frames; any that arrived early come first.
  Stream<OdcFrame> get frames {
    if (!_listening) {
      _listening = true;
      final early = List.of(_early);
      _early.clear();
      scheduleMicrotask(() {
        for (final f in early) {
          if (!_frames.isClosed) _frames.add(f);
        }
      });
    }
    return _frames.stream;
  }

  /// Frames go out one after another: a socket can't take new bytes while
  /// it is still flushing a big picture.
  Future<void> _tail = Future.value();

  Future<void> _send(OdcFrame f) {
    if (_closed) return Future.error(const SocketException('Direct IM link closed'));
    final bytes = f.encode();
    final sent = _tail.then((_) async {
      if (_closed) throw const SocketException('Direct IM link closed');
      _socket.add(bytes);
      await _socket.flush();
    });
    _tail = sent.catchError((Object _) {});
    return sent;
  }

  Future<void> sendCookie() => _send(OdcFrame(cookie: cookie, flags: OdcFrame.flagCookie, screenName: myName));

  /// Sends text and pictures; completes when the bytes have left this device.
  Future<void> sendMessage(String text, {List<OdcImage> images = const [], bool autoResponse = false}) async {
    final (enc, payload) = encodeOdcMessage(text, images: images);
    await _send(OdcFrame(
      cookie: cookie,
      encoding: enc,
      flags: autoResponse ? OdcFrame.flagAutoReply : 0,
      screenName: myName,
      payload: payload,
    ));
  }

  void sendTyping(int state) {
    if (_closed) return;
    final f = OdcFrame.flagTypingEvent |
        (state == 2 ? OdcFrame.flagTyping : (state == 1 ? OdcFrame.flagTyped : 0));
    _send(OdcFrame(cookie: cookie, flags: f, screenName: myName)).ignore();
  }

  void _finish(String reason) {
    if (_closed) return;
    _closed = true;
    _sub?.cancel();
    try {
      _socket.destroy();
    } catch (_) {}
    _earlyArrived?.complete();
    _earlyArrived = null;
    if (!_done.isCompleted) _done.complete(reason);
    _frames.close();
  }

  Future<void> close() async {
    if (_closed) return;
    try {
      await _tail.timeout(const Duration(seconds: 2));
    } catch (_) {}
    _finish('closed by you');
  }
}
