import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'bytes.dart';
import 'oft.dart';
import 'peer_link.dart';
import 'peer_path.dart';
import 'rendezvous.dart';
import 'session.dart';

enum XferState {
  offering, // we offered files; waiting for them to accept
  offered, // they offered files; waiting for us to accept or decline
  connecting, // accepted; finding a way to each other
  moving, // the files are going across
  done,
  declined, // they said no (or we did)
  cancelled, // stopped by us, or the offer was withdrawn
  failed, // couldn't connect, or the connection dropped
}

class XferFile {
  final String name;
  final int size;

  /// Outgoing: the file to read. Incoming: where it was saved, once done.
  String? path;
  XferFile(this.name, this.size, [this.path]);
}

/// One Send File: one or more files to or from one buddy.
class FileXfer {
  final String peer;
  final Uint8List cookie;
  final bool outgoing;
  final List<XferFile> files;
  XferState state;

  /// Total of all files, and how much has gone across so far.
  int totalSize;
  int moved = 0;

  /// For several files: how many there are, and the name of the first one.
  int count;
  String firstName;

  /// Bytes per second right now.
  double speed = 0;

  DateTime since = DateTime.now();
  DateTime? startedAt;

  /// Why it failed (for troubleshooting; the chat just says it failed).
  String? failReason;
  Rendezvous? proposal;

  List<ServerSocket> _listeners = const [];

  /// Addresses we told them (for troubleshooting).
  String _ours = '';
  PortLease? _lease;
  Timer? _timer;
  Timer? _watchdog;
  PeerLink? _sock;

  // hole punching
  final Map<int, List<int>> _sigParts = {};
  int _sigKind = 0;
  PunchCall? _call;
  void Function()? _punchCancel;

  /// How the files went: "TCP" or "punched" (for troubleshooting).
  String? via;
  String? _partial;
  DateTime _lastMoved = DateTime.now();
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _speedAt = DateTime.now();
  int _speedBytes = 0;
  bool _stopping = false;

  FileXfer(this.peer, this.cookie, this.state,
      {required this.outgoing, required this.files, required this.totalSize, required this.count, required this.firstName});

  String get id => hex(cookie);
  bool get isPending => state == XferState.offering || state == XferState.offered || state == XferState.connecting;
  bool get isActive => isPending || state == XferState.moving;

  /// 0..1
  double get fraction => totalSize <= 0 ? 0 : min(1, moved / totalSize);

  /// Saved files (incoming, once done).
  List<String> get saved => [for (final f in files) if (f.path != null) f.path!];

  /// "photo.jpg" or "photo.jpg and 3 more".
  String get label => count > 1 ? '$firstName and ${count - 1} more' : firstName;
}

class XferChanged {
  final FileXfer xfer;
  final XferState state;
  XferChanged(this.xfer) : state = xfer.state;
}

/// AIM Send File, device to device. The server only carries the tiny
/// "here are some files" / "yes please" handshake; the files themselves go
/// straight between the two devices over the fastest path found (see
/// [PeerPath]) and are never sent to, stored on or relayed by the server.
///
/// If no direct path works, the transfer just fails.
class FileTransfers {
  /// Sends a handshake message to a buddy through the server.
  final Future<SendResult> Function(String to, Uint8List cookie, Uint8List data) sendRdv;

  /// The folder to save incoming files in.
  final Future<String> Function() receiveDir;

  final PeerPath path;

  /// Hole punching, for when neither device can reach the other directly.
  /// Optional (tests and platforms without it just fail as before).
  HolePuncher? puncher;

  /// How long hole punching may take to find a path.
  Duration punchTimeout;

  /// When false, offers are declined without asking.
  bool allowIncoming = true;

  Duration inviteTimeout;
  Duration reverseTimeout;

  /// A connection that moves nothing for this long is given up.
  Duration stallTimeout;

  /// The header type a buddy that connects to us sends first, to show it's
  /// really them (it has to know the secret cookie from the invite).
  static const helloType = 0x7a01;

  FileTransfers({
    required this.sendRdv,
    required this.receiveDir,
    PeerPath? path,
    this.inviteTimeout = const Duration(minutes: 2),
    this.reverseTimeout = const Duration(seconds: 40),
    this.stallTimeout = const Duration(seconds: 45),
    this.puncher,
    this.punchTimeout = const Duration(seconds: 45),
  }) : path = path ?? PeerPath();

  final Map<String, FileXfer> xfers = {};
  final _events = StreamController<XferChanged>.broadcast();
  Stream<XferChanged> get events => _events.stream;

  /// Transfers with [sn] that are still going (offers included).
  List<FileXfer> activeWith(String sn) {
    final k = normalizeSn(sn);
    return [for (final x in xfers.values) if (normalizeSn(x.peer) == k && x.isActive) x];
  }

  FileXfer? byId(String id) => xfers[id];

  void _emit(FileXfer x) {
    x._lastEmit = DateTime.now();
    if (!_events.isClosed) _events.add(XferChanged(x));
  }

  void _set(FileXfer x, XferState s) {
    if (!x.isActive) return; // already finished
    x.state = s;
    x.since = DateTime.now();
    if (s == XferState.moving) {
      x.startedAt = DateTime.now();
      x._speedAt = DateTime.now();
      x._speedBytes = 0;
      x._lastMoved = DateTime.now();
    }
    if (!x.isPending) _cleanup(x);
    if (!x.isActive) {
      x._watchdog?.cancel();
      x._watchdog = null;
      final s = x._sock;
      x._sock = null;
      if (s != null) {
        if (x.state == XferState.done) {
          unawaited(s.close());
        } else {
          s.destroy();
        }
      }
      if (x.state != XferState.done || s == null) {
        x._punchCancel?.call();
      }
      x._punchCancel = null;
      x._call = null;
      final part = x._partial;
      x._partial = null;
      if (part != null) File(part).delete().catchError((_) => File(part));
    }
    _emit(x);
  }

  void _fail(FileXfer x, String why) {
    x.failReason ??= why;
    _set(x, XferState.failed);
  }

  void _moved(FileXfer x, int n) {
    x.moved += n;
    final now = DateTime.now();
    x._lastMoved = now;
    final dt = now.difference(x._speedAt).inMilliseconds;
    if (dt >= 1000) {
      final recent = (x.moved - x._speedBytes) * 1000 / dt;
      x.speed = x.speed == 0 ? recent : x.speed * 0.5 + recent * 0.5;
      x._speedAt = now;
      x._speedBytes = x.moved;
    }
    if (now.difference(x._lastEmit) > const Duration(milliseconds: 250)) _emit(x);
  }

  static Uint8List _newCookie() {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(8, (_) => r.nextInt(256)));
  }

  Future<bool> _rdv(FileXfer x, Uint8List data) async {
    try {
      return await sendRdv(x.peer, x.cookie, data) == SendResult.delivered;
    } catch (_) {
      return false;
    }
  }

  void _cancelRdv(FileXfer x, int reason) =>
      _rdv(x, Rendezvous.encodeCancel(x.cookie, reason, capSendFile)).ignore();

  // ---------------------------------------------------------------- actions

  /// Offers [files] (path, name) to [sn]. Returns the transfer.
  Future<FileXfer> offer(String sn, List<(String, String)> files) async {
    final list = <XferFile>[];
    for (final (p, n) in files) {
      list.add(XferFile(n, await File(p).length(), p));
    }
    final total = list.fold<int>(0, (a, f) => a + f.size);
    final x = FileXfer(sn, _newCookie(), XferState.offering,
        outgoing: true, files: list, totalSize: total, count: list.length, firstName: list.isEmpty ? '' : list.first.name);
    xfers[x.id] = x;
    _emit(x);
    if (list.isEmpty) {
      _fail(x, 'no files');
      return x;
    }
    try {
      final port = await _listen(x, sender: true);
      final (lan, extra, six, lease) = await path.addresses(port);
      x._lease = lease;
      x._ours = '${[lan, ...extra, ...six].join(', ')} port $port';
      if (x.state != XferState.offering) {
        _cleanup(x);
        return x;
      }
      final ok = await _rdv(
          x,
          Rendezvous.encodePropose(x.cookie,
              ip: lan,
              port: port,
              extra: extra,
              ipv6: six,
              cap: capSendFile,
              moreTlvs: OftOffer(x.count, total, x.firstName).toTlvs()));
      if (!ok) {
        _fail(x, 'invite not delivered');
        return x;
      }
      x._timer = Timer(inviteTimeout, () {
        if (x.state == XferState.offering) {
          _cancelRdv(x, Rendezvous.reasonTimeout);
          _fail(x, 'no answer in time');
        }
      });
    } catch (e) {
      _fail(x, 'offer setup error: $e');
    }
    return x;
  }

  /// Accepts an offer: connect to them, or let them connect to us.
  Future<void> accept(String id) async {
    final x = xfers[id];
    final p = x?.proposal;
    if (x == null || p == null || x.state != XferState.offered) return;
    _set(x, XferState.connecting);
    final sock = await PeerPath.connectAny(PeerPath.order(p.addresses, p.addresses6), p.port ?? 0);
    if (x.state != XferState.connecting) {
      sock?.destroy();
      return;
    }
    if (sock != null) {
      _rdv(x, Rendezvous.encodeAccept(x.cookie, cap: capSendFile)).ignore();
      unawaited(_receive(x, SocketLink(sock), sayHello: true));
      return;
    }
    // Couldn't reach them: listen, and ask them to connect to us instead.
    try {
      final port = await _listen(x, sender: false);
      final (lan, extra, six, lease) = await path.addresses(port);
      x._lease = lease;
      x._ours = '${[lan, ...extra, ...six].join(', ')} port $port';
      if (x.state != XferState.connecting) {
        _cleanup(x);
        return;
      }
      final ok = await _rdv(
          x,
          Rendezvous.encodePropose(x.cookie,
              ip: lan, port: port, seq: 2, extra: extra, ipv6: six, cap: capSendFile));
      if (!ok) {
        _fail(x, 'reverse invite not delivered');
        return;
      }
      x._timer?.cancel();
      x._timer = Timer(reverseTimeout, () {
        if (x.state == XferState.connecting) {
          _cancelRdv(x, Rendezvous.reasonTimeout);
          _fail(x, 'buddy never connected back; we offered ${x._ours}');
        }
      });
    } catch (e) {
      _fail(x, 'accept setup error: $e');
    }
  }

  void decline(String id) {
    final x = xfers[id];
    if (x == null || x.state != XferState.offered) return;
    _cancelRdv(x, Rendezvous.reasonDeclined);
    _set(x, XferState.declined);
  }

  /// Withdraws an offer or stops a transfer.
  void cancel(String id) {
    final x = xfers[id];
    if (x == null || !x.isActive) return;
    if (x.state == XferState.offered) {
      decline(id);
      return;
    }
    x._stopping = true;
    if (x.isPending) _cancelRdv(x, Rendezvous.reasonUnknown);
    _set(x, XferState.cancelled);
  }

  Future<void> closeAll() async {
    for (final x in xfers.values.toList()) {
      if (x.isActive) {
        x._stopping = true;
        _set(x, XferState.cancelled);
      }
    }
  }

  Future<void> dispose() async {
    await closeAll();
    await _events.close();
  }

  // ---------------------------------------------------------------- handshake from the server

  void onRendezvous(String from, Rendezvous r) {
    final x = xfers[hex(r.cookie)];
    final mine = x != null && normalizeSn(x.peer) == normalizeSn(from) ? x : null;
    final sig = r.tlvs[tagSignal];
    if (sig != null) {
      if (mine != null) unawaited(_onSignal(mine, sig.value));
      return;
    }
    switch (r.type) {
      case Rendezvous.propose:
        if (mine != null) {
          // They couldn't reach us; they're listening now, so we connect.
          if (r.seq >= 2 && mine.outgoing && mine.state == XferState.offering) unawaited(_reverse(mine, r));
          return;
        }
        if (x != null) return; // someone else reusing a cookie
        if (!allowIncoming) {
          sendRdv(from, r.cookie, Rendezvous.encodeCancel(r.cookie, Rendezvous.reasonDeclined, capSendFile)).ignore();
          return;
        }
        final o = OftOffer.fromTlvs(r.tlvs);
        if (o == null) return;
        final n = FileXfer(from, Uint8List.fromList(r.cookie), XferState.offered,
            outgoing: false, files: [], totalSize: o.totalSize, count: o.count, firstName: o.name);
        n.proposal = r;
        xfers[n.id] = n;
        n._timer = Timer(inviteTimeout, () {
          if (n.state == XferState.offered) _set(n, XferState.cancelled);
        });
        _emit(n);
      case Rendezvous.cancel:
        if (mine == null || !mine.isPending) return;
        mine.failReason ??= 'buddy called it off (reason ${r.cancelReason}); we offered ${mine._ours}';
        _set(
            mine,
            mine.state == XferState.offering && r.cancelReason == Rendezvous.reasonDeclined
                ? XferState.declined
                : (mine.state == XferState.offered ? XferState.cancelled : XferState.failed));
      case Rendezvous.accept:
        if (mine != null && mine.state == XferState.offering) {
          mine._timer?.cancel();
          mine._timer = Timer(reverseTimeout, () {
            if (mine.isPending) _fail(mine, 'buddy accepted but never connected');
          });
          mine.state = XferState.connecting;
          _emit(mine);
        }
      default:
        break;
    }
  }

  Future<void> _reverse(FileXfer x, Rendezvous r) async {
    x.state = XferState.connecting;
    _emit(x);
    final tried = PeerPath.order(r.addresses, r.addresses6);
    final sock = await PeerPath.connectAny(tried, r.port ?? 0);
    if (x.state != XferState.connecting) {
      sock?.destroy();
      return;
    }
    if (sock == null) {
      final why = 'could not reach buddy either way; tried ${tried.join(', ')} port ${r.port}; we offered ${x._ours}';
      if (puncher != null) {
        unawaited(_punchCall(x, why));
        return;
      }
      _cancelRdv(x, Rendezvous.reasonUnknown);
      _fail(x, why);
      return;
    }
    unawaited(_send(x, SocketLink(sock), needHello: false));
  }

  // ---------------------------------------------------------------- hole punching

  static const _sigOffer = 1;
  static const _sigAnswer = 2;
  static const _sigPiece = 700;

  Future<void> _sendSignal(FileXfer x, int kind, String text) async {
    final data = zlib.encode(utf8.encode(text));
    final total = (data.length + _sigPiece - 1) ~/ _sigPiece;
    for (var i = 0; i < total; i++) {
      final piece = data.sublist(i * _sigPiece, min(data.length, (i + 1) * _sigPiece));
      final ok = await _rdv(
          x, Rendezvous.encodeSignal(x.cookie, capSendFile, [(tagSignal, [kind, i, total, ...piece])]));
      if (!ok) throw const SocketException('signal not delivered');
    }
  }

  /// A piece of the buddy's offer or answer arrived. Returns the whole text
  /// once every piece is in.
  String? _collectSignal(FileXfer x, List<int> v) {
    if (v.length < 3) return null;
    final kind = v[0], i = v[1], total = v[2];
    if (total == 0 || i >= total) return null;
    if (x._sigKind != kind) {
      x._sigKind = kind;
      x._sigParts.clear();
    }
    x._sigParts[i] = v.sublist(3);
    if (x._sigParts.length < total) return null;
    final all = [for (var k = 0; k < total; k++) ...?x._sigParts[k]];
    x._sigParts.clear();
    try {
      return utf8.decode(zlib.decode(all));
    } catch (_) {
      return null;
    }
  }

  /// The sender couldn't reach the buddy and the buddy couldn't reach us:
  /// try hole punching. We dial; the buddy answers.
  Future<void> _punchCall(FileXfer x, String whyDirectFailed) async {
    final p = puncher!;
    x._timer?.cancel();
    x._timer = Timer(punchTimeout, () {
      if (x.isPending) {
        _cancelRdv(x, Rendezvous.reasonUnknown);
        _fail(x, 'hole punching found no path; before that: $whyDirectFailed');
      }
    });
    try {
      final call = await p.call();
      if (!x.isPending) {
        call.cancel();
        return;
      }
      x._call = call;
      x._punchCancel = call.cancel;
      await _sendSignal(x, _sigOffer, call.offer);
    } catch (e) {
      if (x.isPending) {
        _cancelRdv(x, Rendezvous.reasonUnknown);
        _fail(x, 'hole punching could not start ($e); before that: $whyDirectFailed');
      }
    }
  }

  Future<void> _onSignal(FileXfer x, List<int> v) async {
    if (x.state != XferState.connecting) return;
    final text = _collectSignal(x, v);
    if (text == null) return;
    final p = puncher;
    if (x._sigKind == _sigOffer && !x.outgoing) {
      if (p == null) {
        _cancelRdv(x, Rendezvous.reasonUnknown);
        _fail(x, 'buddy wanted hole punching; not available here');
        return;
      }
      // We're the receiver: stop waiting for a direct connection and answer.
      x._timer?.cancel();
      x._timer = Timer(punchTimeout, () {
        if (x.isPending) {
          _cancelRdv(x, Rendezvous.reasonUnknown);
          _fail(x, 'hole punching found no path; we offered ${x._ours}');
        }
      });
      try {
        final a = await p.answer(text);
        if (!x.isPending) {
          a.cancel();
          return;
        }
        x._punchCancel = a.cancel;
        await _sendSignal(x, _sigAnswer, a.answer);
        final link = await a.link;
        if (!x.isPending || x._sock != null) {
          link?.destroy();
          return;
        }
        if (link == null) {
          _cancelRdv(x, Rendezvous.reasonUnknown);
          _fail(x, 'hole punching found no path; we offered ${x._ours}');
          return;
        }
        unawaited(_receive(x, link, sayHello: false));
      } catch (e) {
        if (x.isPending) {
          _cancelRdv(x, Rendezvous.reasonUnknown);
          _fail(x, 'hole punching failed: $e');
        }
      }
    } else if (x._sigKind == _sigAnswer && x.outgoing) {
      final call = x._call;
      if (call == null) return;
      try {
        final link = await call.connect(text);
        if (!x.isPending || x._sock != null) {
          link?.destroy();
          return;
        }
        if (link == null) {
          _cancelRdv(x, Rendezvous.reasonUnknown);
          _fail(x, 'hole punching found no path; we offered ${x._ours}');
          return;
        }
        unawaited(_send(x, link, needHello: false));
      } catch (e) {
        if (x.isPending) {
          _cancelRdv(x, Rendezvous.reasonUnknown);
          _fail(x, 'hole punching failed: $e');
        }
      }
    }
  }

  // ---------------------------------------------------------------- connections

  Future<int> _listen(FileXfer x, {required bool sender}) async {
    final all = await PeerPath.listen();
    x._listeners = all;
    void onSock(Socket sock) {
      if (!x.isPending || x._sock != null) {
        sock.destroy();
        return;
      }
      // The sender waits for the buddy's hello; the receiver checks the
      // cookie on the first file offer instead.
      if (sender) {
        unawaited(_send(x, SocketLink(sock), needHello: true));
      } else {
        unawaited(_receive(x, SocketLink(sock), sayHello: false));
      }
    }

    for (final ss in all) {
      ss.listen(onSock, onError: (_) {});
    }
    return all.first.port;
  }

  void _startWatchdog(FileXfer x) {
    x._watchdog?.cancel();
    x._watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (x.state == XferState.moving && DateTime.now().difference(x._lastMoved) > stallTimeout) {
        _fail(x, 'stalled');
      }
    });
  }

  bool _same(Uint8List a, Uint8List b) => hex(a) == hex(b);

  /// Our side sends. [needHello]: the buddy connected to us, so it must show
  /// the cookie first; until then a stray connection gets nothing.
  Future<void> _send(FileXfer x, PeerLink sock, {required bool needHello}) async {
    final rd = _Reader(sock.input);
    var claimed = false;
    try {
      if (needHello) {
        final h = await rd.header().timeout(const Duration(seconds: 10));
        if (h.type != helloType || !_same(h.cookie, x.cookie)) throw const FormatException('wrong hello');
      }
      // Several connections could race; only the first one counts.
      if (!x.isPending || x._sock != null) {
        sock.destroy();
        return;
      }
      x._sock = sock;
      x.via = sock.kind;
      claimed = true;
      _set(x, XferState.moving);
      _startWatchdog(x);
      final mod = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      for (var i = 0; i < x.files.length; i++) {
        final f = x.files[i];
        final prompt = OftHeader(
          type: OftHeader.prompt,
          cookie: x.cookie,
          totalFiles: x.files.length,
          filesLeft: x.files.length - i,
          totalSize: x.totalSize,
          size: f.size,
          modTime: mod,
          name: f.name,
        );
        sock.add(prompt.encode());
        await sock.flush();
        final a = await rd.header().timeout(stallTimeout);
        if (a.type != OftHeader.ack || !_same(a.cookie, x.cookie)) throw const FormatException('expected ack');
        if (f.size > 0) {
          await sock.addStream(File(f.path!).openRead().map((c) {
            _moved(x, c.length);
            return c;
          }));
          await sock.flush();
        }
        final d = await rd.header().timeout(stallTimeout);
        if (d.type != OftHeader.done || !_same(d.cookie, x.cookie)) throw const FormatException('expected done');
      }
      _set(x, XferState.done);
    } catch (e) {
      // A stray connection to our port doesn't spoil the transfer; only the
      // real one (or the one we made ourselves) does.
      if ((claimed || !needHello) && x.isActive && !x._stopping) _fail(x, 'sending: $e');
      sock.destroy();
    } finally {
      rd.cancel();
    }
  }

  /// Our side receives. [sayHello]: we connected to them, so we show the cookie.
  Future<void> _receive(FileXfer x, PeerLink sock, {required bool sayHello}) async {
    final rd = _Reader(sock.input);
    var claimed = false;
    String? part;
    try {
      if (sayHello) {
        sock.add(OftHeader(type: helloType, cookie: x.cookie).encode());
        await sock.flush();
      }
      var first = true;
      while (true) {
        final p = await rd.header().timeout(first ? const Duration(seconds: 20) : stallTimeout);
        if (p.type != OftHeader.prompt || !_same(p.cookie, x.cookie)) throw const FormatException('expected prompt');
        if (first) {
          if (!x.isPending || x._sock != null) {
            sock.destroy();
            return;
          }
          x._sock = sock;
          x.via = sock.kind;
          claimed = true;
          if (p.totalSize > x.totalSize) x.totalSize = p.totalSize;
          _set(x, XferState.moving);
          _startWatchdog(x);
          first = false;
        }
        final dir = await receiveDir();
        final name = safeFileName(p.name);
        final target = await _freeName(dir, name);
        part = '$target.part';
        x._partial = part;
        final xf = XferFile(name, p.size);
        x.files.add(xf);
        final raf = await File(part).open(mode: FileMode.write);
        try {
          sock.add(p.copyWith(type: OftHeader.ack).encode());
          await sock.flush();
          var left = p.size;
          final pending = BytesBuilder(copy: false);
          while (left > 0) {
            final c = await rd.chunk(left);
            if (c == null) throw const SocketException('closed');
            left -= c.length;
            pending.add(c);
            _moved(x, c.length);
            if (pending.length >= 1 << 20 || left == 0) await raf.writeFrom(pending.takeBytes());
          }
        } finally {
          await raf.close();
        }
        if (!x.isActive) return;
        // Keep the name picked at the start unless something took it meanwhile.
        final saved = await File(target).exists() ? await _freeName(dir, name) : target;
        await File(part).rename(saved);
        part = null;
        x._partial = null;
        xf.path = saved;
        sock.add(p.copyWith(type: OftHeader.done, received: p.size).encode());
        await sock.flush();
        _emit(x);
        if (p.filesLeft <= 1) break;
      }
      _set(x, XferState.done);
    } catch (e) {
      if ((claimed || sayHello) && x.isActive && !x._stopping) _fail(x, 'receiving: $e');
      sock.destroy();
      final left = part;
      if (left != null) File(left).delete().catchError((_) => File(left)).ignore();
    } finally {
      rd.cancel();
    }
  }

  /// "name.ext", or "name (2).ext" if that's taken.
  static Future<String> _freeName(String dir, String name) async {
    final sep = Platform.pathSeparator;
    await Directory(dir).create(recursive: true);
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var p = '$dir$sep$name';
    var i = 2;
    while (await File(p).exists() || await File('$p.part').exists()) {
      p = '$dir$sep$base ($i)$ext';
      i++;
    }
    return p;
  }

  void _cleanup(FileXfer x) {
    x._timer?.cancel();
    x._timer = null;
    for (final l in x._listeners) {
      l.close();
    }
    x._listeners = const [];
    final l = x._lease;
    x._lease = null;
    if (l != null) unawaited(l.close().catchError((_) {}));
  }
}

/// Reads exact amounts from a socket without copying file data around.
class _Reader {
  final StreamIterator<Uint8List> _it;
  Uint8List _buf = Uint8List(0);
  int _off = 0;

  _Reader(Stream<Uint8List> s) : _it = StreamIterator<Uint8List>(s);

  Future<bool> _fill() async {
    if (_off < _buf.length) return true;
    if (!await _it.moveNext()) return false;
    _buf = _it.current;
    _off = 0;
    return true;
  }

  Future<Uint8List> exact(int n) async {
    final out = BytesBuilder(copy: true);
    while (out.length < n) {
      if (!await _fill()) throw const SocketException('closed');
      final k = min(n - out.length, _buf.length - _off);
      out.add(Uint8List.sublistView(_buf, _off, _off + k));
      _off += k;
    }
    return out.takeBytes();
  }

  Future<OftHeader> header() async {
    final head = await exact(6);
    final len = OftHeader.lengthOf(head);
    final rest = await exact(len - 6);
    return OftHeader.parse(Uint8List.fromList([...head, ...rest]));
  }

  /// Up to [max] bytes of whatever has arrived, or null if the connection closed.
  Future<Uint8List?> chunk(int max) async {
    if (!await _fill()) return null;
    final k = min(max, _buf.length - _off);
    final c = Uint8List.sublistView(_buf, _off, _off + k);
    _off += k;
    return c;
  }

  void cancel() {
    _it.cancel().ignore();
  }
}
