import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'bytes.dart';
import 'odc.dart';
import 'rendezvous.dart';
import 'session.dart';
import 'upnp.dart';

enum DirectState {
  inviting, // we asked; waiting for them to accept and connect
  invited, // they asked; waiting for us to accept or decline
  connecting, // trying to reach each other
  connected,
  declined, // they said no
  failed, // couldn't connect ("Direct Connect failed.")
  closed, // was connected, or the invite was withdrawn
}

/// Direct Connect with one buddy.
class DirectLink {
  final String peer;
  final Uint8List cookie;
  final bool outgoing;
  DirectState state;
  Rendezvous? proposal;
  OdcConnection? conn;
  DateTime since = DateTime.now();

  ServerSocket? _listener;
  Upnp? _upnp;
  int? _mappedPort;
  Timer? _timer;

  DirectLink(this.peer, this.cookie, this.state, {required this.outgoing, this.proposal});

  bool get isOpen => state == DirectState.connected && !(conn?.isClosed ?? true);
  bool get isPending =>
      state == DirectState.inviting || state == DirectState.invited || state == DirectState.connecting;

  /// The buddy's address on an open connection (they see yours too).
  String? get remoteIp => conn?.remoteHost;
}

sealed class DirectEvent {}

class DirectStateChanged extends DirectEvent {
  final DirectLink link;

  /// The state when this happened (the link may have moved on since).
  final DirectState state;
  DirectStateChanged(this.link) : state = link.state;
}

class DirectMessageIn extends DirectEvent {
  final String from;
  final DirectMessage message;
  DirectMessageIn(this.from, this.message);
}

class DirectTypingIn extends DirectEvent {
  final String from;
  final int state;
  DirectTypingIn(this.from, this.state);
}

/// A picture is arriving: [got] of [total] bytes.
class DirectProgress extends DirectEvent {
  final String from;
  final int got;
  final int total;
  DirectProgress(this.from, this.got, this.total);
}

/// AIM Direct Connect (Direct IM): pictures and messages straight between two
/// devices. The server only carries the tiny "let's connect" handshake; it
/// never sees, stores or relays the pictures.
///
/// Ways to connect, tried in order, all device to device:
/// 1. the buddy connects to us (same Wi-Fi, or our router opened a port with
///    UPnP, or the address the server saw);
/// 2. if they can't, they listen and we connect to them instead ("reverse");
/// 3. otherwise: "Direct Connect failed."
class DirectConnect {
  final OscarSession? Function() session;
  final String Function() myName;

  /// Looks up our public address (the AIM Server app can tell us). Optional.
  final Future<String?> Function()? publicIp;

  bool useUpnp;

  /// When false, invites are declined without asking.
  bool allowIncoming = true;

  Duration inviteTimeout;
  Duration reverseTimeout;

  /// Tests: pretend this device can't be reached (advertise a closed port).
  bool debugUnreachable = false;

  DirectConnect({
    required this.session,
    required this.myName,
    this.publicIp,
    this.useUpnp = true,
    this.inviteTimeout = const Duration(minutes: 2),
    this.reverseTimeout = const Duration(seconds: 40),
  });

  final Map<String, DirectLink> links = {};
  final _events = StreamController<DirectEvent>.broadcast();
  Stream<DirectEvent> get events => _events.stream;

  DirectLink? linkFor(String sn) => links[normalizeSn(sn)];
  bool isOpen(String sn) => linkFor(sn)?.isOpen ?? false;

  void _emit(DirectEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  void _set(DirectLink l, DirectState s) {
    l.state = s;
    l.since = DateTime.now();
    if (s != DirectState.inviting && s != DirectState.invited && s != DirectState.connecting) _cleanup(l);
    _emit(DirectStateChanged(l));
  }

  static Uint8List _newCookie() {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(8, (_) => r.nextInt(256)));
  }

  // ---------------------------------------------------------------- actions

  /// Asks [sn] to Direct Connect.
  Future<void> invite(String sn) async {
    final key = normalizeSn(sn);
    final old = links[key];
    if (old != null && (old.isOpen || old.isPending)) {
      if (old.state == DirectState.invited) await accept(sn);
      return;
    }
    final link = DirectLink(sn, _newCookie(), DirectState.inviting, outgoing: true);
    links[key] = link;
    _emit(DirectStateChanged(link));
    try {
      final port = await _listen(link);
      final (ip, extra) = await _myAddresses(link, port);
      if (link.state != DirectState.inviting) return;
      final r = await _sendRdv(sn, link.cookie,
          Rendezvous.encodePropose(link.cookie, ip: ip, port: debugUnreachable ? 1 : port, extra: extra));
      if (r != SendResult.delivered) {
        _set(link, DirectState.failed);
        return;
      }
      link._timer = Timer(inviteTimeout, () {
        if (link.state == DirectState.inviting) {
          _sendRdv(sn, link.cookie, Rendezvous.encodeCancel(link.cookie, Rendezvous.reasonTimeout)).ignore();
          _set(link, DirectState.failed);
        }
      });
    } catch (_) {
      if (link.isPending) _set(link, DirectState.failed);
    }
  }

  /// Accepts [sn]'s invite: connect to them, or let them connect to us.
  Future<void> accept(String sn) async {
    final link = linkFor(sn);
    final p = link?.proposal;
    if (link == null || p == null || link.state != DirectState.invited) return;
    _set(link, DirectState.connecting);
    final sock = await _connectAny(p.addresses, p.port ?? 0);
    if (link.state != DirectState.connecting) {
      sock?.destroy();
      return;
    }
    if (sock != null) {
      final conn = OdcConnection(sock, link.cookie, myName());
      try {
        await conn.sendCookie();
        _sendRdv(link.peer, link.cookie, Rendezvous.encodeAccept(link.cookie)).ignore();
        _connected(link, conn, null);
        return;
      } catch (_) {
        await conn.close();
      }
    }
    // Couldn't reach them: listen and ask them to connect to us instead.
    try {
      final port = await _listen(link);
      final (ip, extra) = await _myAddresses(link, port);
      if (link.state != DirectState.connecting) return;
      final r = await _sendRdv(link.peer, link.cookie,
          Rendezvous.encodePropose(link.cookie, ip: ip, port: debugUnreachable ? 1 : port, seq: 2, extra: extra));
      if (r != SendResult.delivered) {
        _set(link, DirectState.failed);
        return;
      }
      link._timer?.cancel();
      link._timer = Timer(reverseTimeout, () {
        if (link.state == DirectState.connecting) {
          _sendRdv(link.peer, link.cookie, Rendezvous.encodeCancel(link.cookie, Rendezvous.reasonTimeout)).ignore();
          _set(link, DirectState.failed);
        }
      });
    } catch (_) {
      if (link.isPending) _set(link, DirectState.failed);
    }
  }

  Future<void> decline(String sn) async {
    final link = linkFor(sn);
    if (link == null || link.state != DirectState.invited) return;
    _sendRdv(link.peer, link.cookie, Rendezvous.encodeCancel(link.cookie)).ignore();
    _set(link, DirectState.closed);
  }

  /// Withdraws an invite or closes an open connection.
  Future<void> close(String sn) async {
    final link = linkFor(sn);
    if (link == null) return;
    if (link.isPending) {
      _sendRdv(link.peer, link.cookie, Rendezvous.encodeCancel(link.cookie)).ignore();
      _set(link, DirectState.closed);
    } else if (link.conn != null) {
      await link.conn!.close();
    }
  }

  /// Sends over the open connection. Throws if it isn't open.
  Future<void> send(String sn, String text, {List<OdcImage> images = const []}) async {
    final link = linkFor(sn);
    final c = link?.conn;
    if (link == null || c == null || !link.isOpen) throw const SocketException('Direct Connect is not open');
    await c.sendMessage(text, images: images);
  }

  void sendTyping(String sn, int state) {
    final link = linkFor(sn);
    if (link != null && link.isOpen) link.conn!.sendTyping(state);
  }

  Future<void> closeAll() async {
    for (final l in links.values.toList()) {
      if (l.isPending) {
        _cleanup(l);
        l.state = DirectState.closed;
      }
      await l.conn?.close();
    }
  }

  Future<void> dispose() async {
    await closeAll();
    await _events.close();
  }

  // ---------------------------------------------------------------- handshake from the server

  void onRendezvous(String from, Rendezvous r) {
    final key = normalizeSn(from);
    final link = links[key];
    final mine = (link != null && hex(link.cookie) == hex(r.cookie)) ? link : null;
    switch (r.type) {
      case Rendezvous.propose:
        if (mine != null) {
          if (r.seq >= 2 && mine.outgoing && mine.state == DirectState.inviting) {
            unawaited(_reverseConnect(mine, r));
          }
          return;
        }
        if (link != null && link.isOpen) return;
        if (!allowIncoming) {
          _sendRdv(from, r.cookie, Rendezvous.encodeCancel(r.cookie)).ignore();
          return;
        }
        final crossed = link != null && link.outgoing && link.state == DirectState.inviting;
        if (link != null && link.isPending) _cleanup(link);
        final n = DirectLink(from, Uint8List.fromList(r.cookie), DirectState.invited, outgoing: false, proposal: r);
        links[key] = n;
        n._timer = Timer(inviteTimeout, () {
          if (n.state == DirectState.invited) _set(n, DirectState.closed);
        });
        _emit(DirectStateChanged(n));
        // Both pressed Direct Connect at once: just take theirs.
        if (crossed) unawaited(accept(from));
      case Rendezvous.cancel:
        if (mine == null || !mine.isPending) return;
        _set(mine, mine.outgoing && mine.state == DirectState.inviting && r.cancelReason == Rendezvous.reasonDeclined
            ? DirectState.declined
            : (mine.state == DirectState.invited ? DirectState.closed : DirectState.failed));
      default:
        break; // accept: the connection itself tells us
    }
  }

  Future<void> _reverseConnect(DirectLink link, Rendezvous r) async {
    _set(link, DirectState.connecting);
    final sock = await _connectAny(r.addresses, r.port ?? 0);
    if (link.state != DirectState.connecting) {
      sock?.destroy();
      return;
    }
    if (sock == null) {
      _sendRdv(link.peer, link.cookie, Rendezvous.encodeCancel(link.cookie, Rendezvous.reasonUnknown)).ignore();
      _set(link, DirectState.failed);
      return;
    }
    final conn = OdcConnection(sock, link.cookie, myName());
    try {
      await conn.sendCookie();
      _sendRdv(link.peer, link.cookie, Rendezvous.encodeAccept(link.cookie)).ignore();
      _connected(link, conn, null);
    } catch (_) {
      await conn.close();
      _set(link, DirectState.failed);
    }
  }

  // ---------------------------------------------------------------- connections

  Future<SendResult> _sendRdv(String to, Uint8List cookie, Uint8List data) async {
    final s = session();
    if (s == null || !s.isOnline) return SendResult.failed;
    try {
      return await s.sendRendezvous(to, cookie, data);
    } catch (_) {
      return SendResult.failed;
    }
  }

  /// Opens a listening port for [link]; the first connection that shows the
  /// right cookie wins.
  Future<int> _listen(DirectLink link) async {
    final ss = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    link._listener = ss;
    ss.listen((sock) async {
      if (!link.isPending || link.conn != null) {
        sock.destroy();
        return;
      }
      final conn = OdcConnection(sock, link.cookie, myName());
      try {
        final first = await conn.firstFrame(const Duration(seconds: 10));
        if (hex(first.cookie) != hex(link.cookie) || !link.isPending || link.conn != null) {
          await conn.close();
          return;
        }
        _connected(link, conn, first);
      } catch (_) {
        await conn.close();
      }
    }, onError: (_) {});
    return ss.port;
  }

  void _connected(DirectLink link, OdcConnection conn, OdcFrame? first) {
    link.conn = conn;
    _set(link, DirectState.connected);
    conn.onProgress = (got, total) {
      if (total > 64 * 1024) _emit(DirectProgress(link.peer, got, total));
    };
    void handle(OdcFrame f) {
      if (f.isTyping) _emit(DirectTypingIn(link.peer, f.typingState));
      if (f.payload.isNotEmpty) {
        try {
          final m = decodeOdcMessage(f.payload, f.encoding,
              autoResponse: (f.flags & OdcFrame.flagAutoReply) != 0);
          _emit(DirectMessageIn(link.peer, m));
        } catch (_) {}
      }
    }

    if (first != null && !first.isCookie) handle(first);
    conn.frames.listen(handle);
    conn.done.then((_) {
      if (identical(link.conn, conn) && link.state == DirectState.connected) _set(link, DirectState.closed);
    });
  }

  /// Tries each address, a little apart, and keeps the first that answers.
  Future<Socket?> _connectAny(List<String> addrs, int port) async {
    if (addrs.isEmpty || port <= 0) return null;
    final result = Completer<Socket?>();
    var left = addrs.length;
    for (var i = 0; i < addrs.length; i++) {
      final a = addrs[i];
      unawaited(() async {
        try {
          await Future<void>.delayed(Duration(milliseconds: 600 * i));
          if (result.isCompleted) return;
          final s = await Socket.connect(a, port,
              timeout: Duration(seconds: _isPrivate(a) || a.startsWith('127.') ? 4 : 7));
          if (result.isCompleted) {
            s.destroy();
          } else {
            result.complete(s);
          }
        } catch (_) {
          // try the next one
        } finally {
          left--;
          if (left == 0 && !result.isCompleted) result.complete(null);
        }
      }());
    }
    return result.future;
  }

  static bool _isPrivate(String ip) {
    final p = ip.split('.').map(int.tryParse).toList();
    if (p.length != 4 || p.any((x) => x == null)) return false;
    final a = p[0]!, b = p[1]!;
    return a == 10 || (a == 172 && b >= 16 && b < 32) || (a == 192 && b == 168) || (a == 100 && b >= 64 && b < 128);
  }

  Future<String> _lanIp() async {
    final s = session()?.localIp;
    if (s != null) {
      final a = InternetAddress.tryParse(s);
      if (a != null && a.type == InternetAddressType.IPv4 && !a.isLoopback && s != '0.0.0.0') return s;
    }
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
      final all = [for (final i in ifs) ...i.addresses.where((a) => !a.isLoopback).map((a) => a.address)];
      int rank(String ip) => ip.startsWith('192.168.') ? 0 : (ip.startsWith('10.') ? 1 : (_isPrivate(ip) ? 2 : 3));
      all.sort((a, b) => rank(a).compareTo(rank(b)));
      if (all.isNotEmpty) return all.first;
    } catch (_) {}
    return '127.0.0.1';
  }

  String? _publicCache;
  DateTime? _publicAt;

  /// Our address on the home network, plus any public ones we can learn: from
  /// the router (UPnP, which also opens [port] for a few minutes) and from the
  /// AIM Server app.
  Future<(String, List<String>)> _myAddresses(DirectLink link, int port) async {
    final lan = await _lanIp();
    final extra = <String>[];
    Future<void> upnp() async {
      if (!useUpnp || !_isPrivate(lan)) return;
      final u = await Upnp.find(lan);
      if (u == null || !link.isPending) return;
      if (await u.open(port)) {
        link._upnp = u;
        link._mappedPort = port;
        if (!link.isPending) _cleanup(link);
        final ext = await u.externalIp();
        if (ext != null) extra.add(ext);
      }
    }

    Future<void> pub() async {
      final f = publicIp;
      if (f == null) return;
      final at = _publicAt;
      if (at == null || DateTime.now().difference(at) > const Duration(minutes: 10)) {
        _publicCache = await f();
        _publicAt = DateTime.now();
      }
      final p = _publicCache;
      if (p != null) extra.add(p);
    }

    await Future.wait([upnp(), pub()]).timeout(const Duration(seconds: 7), onTimeout: () => const []);
    return (lan, extra.toSet().where((e) => e != lan).toList());
  }

  void _cleanup(DirectLink l) {
    l._timer?.cancel();
    l._timer = null;
    l._listener?.close();
    l._listener = null;
    final u = l._upnp, p = l._mappedPort;
    if (u != null && p != null) unawaited(u.close(p));
    l._upnp = null;
    l._mappedPort = null;
  }
}
