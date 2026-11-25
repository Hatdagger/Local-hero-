import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'aim_html.dart';
import 'bytes.dart';
import 'chat_room.dart';
import 'flap.dart';
import 'models.dart';
import 'rendezvous.dart';

/// Things the server tells us without being asked.
sealed class OscarEvent {}

class BuddyListChanged extends OscarEvent {}

class BuddyArrived extends OscarEvent {
  final UserInfo info;
  BuddyArrived(this.info);
}

class BuddyDeparted extends OscarEvent {
  final String screenName;
  BuddyDeparted(this.screenName);
}

class MessageReceived extends OscarEvent {
  final IncomingMessage message;
  MessageReceived(this.message);
}

class TypingChanged extends OscarEvent {
  final String screenName;

  /// 0 = stopped, 1 = typed (paused), 2 = typing
  final int state;
  TypingChanged(this.screenName, this.state);
}

/// A Direct Connect handshake message from a buddy (propose/accept/cancel).
class RendezvousReceived extends OscarEvent {
  final String from;
  final Rendezvous rdv;
  RendezvousReceived(this.from, this.rdv);
}

/// A buddy invited us into a chat room.
class RoomInviteReceived extends OscarEvent {
  final RoomInvite invite;
  RoomInviteReceived(this.invite);
}

class SelfInfoChanged extends OscarEvent {
  final UserInfo info;
  SelfInfoChanged(this.info);
}

enum SendResult { delivered, recipientOffline, rateLimited, failed }

class ServerConfig {
  final String host;
  final int port;
  const ServerConfig(this.host, this.port);

  static ServerConfig parse(String input, {int defaultPort = 5190}) {
    var s = input.trim();
    s = s.replaceFirst(RegExp(r'^[a-zA-Z]+://'), '');
    if (s.startsWith('[')) {
      final end = s.indexOf(']');
      final h = s.substring(1, end);
      final rest = s.substring(end + 1);
      final p = rest.startsWith(':') ? int.tryParse(rest.substring(1)) : null;
      return ServerConfig(h, p ?? defaultPort);
    }
    final i = s.lastIndexOf(':');
    if (i > 0 && s.indexOf(':') == i) {
      return ServerConfig(s.substring(0, i), int.tryParse(s.substring(i + 1)) ?? defaultPort);
    }
    return ServerConfig(s, defaultPort);
  }

  @override
  String toString() => '$host:$port';
}

const _clientIdString = 'AOL Instant Messenger, version 5.1.3036/WIN32';
const _aimMd5Salt = 'AOL Instant Messenger (SM)';

/// AIM capability GUIDs we announce.
final _caps = [
  unhex('094613464c7f11d18222444553540000'), // buddy icon
  unhex('0946134e4c7f11d18222444553540000'), // UTF-8 / unicode messages
  unhex('748f2420628711d18222444553540000'), // chat
  capDirectIm, // Direct Connect (pictures in IMs)
  capSendFile, // Send File (files straight between devices)
];

/// One signed-on OSCAR session (auth + BOS + optional BART connection).
class OscarSession {
  final ServerConfig server;
  final String screenName;
  final String password;

  /// If the server redirects us to a loopback/unspecified address, connect to
  /// the address the user typed instead (common with self-hosted servers).
  final bool fixLoopbackRedirects;

  OscarSession(this.server, this.screenName, this.password,
      {this.fixLoopbackRedirects = true});

  FlapConnection? _bos;
  FlapConnection? _bart;
  Future<FlapConnection>? _bartConnecting;
  final _events = StreamController<OscarEvent>.broadcast();
  final _ended = Completer<OscarDisconnect>();
  final List<FeedbagItem> feedbag = [];
  final Map<String, UserInfo> online = {};
  String? formattedScreenName;
  bool _signingOff = false;

  Stream<OscarEvent> get events => _events.stream;

  /// Completes once when the session is over, with the reason.
  Future<OscarDisconnect> get ended => _ended.future;
  bool get isOnline => _bos != null && !_bos!.isClosed && !_ended.isCompleted;

  // ---------------------------------------------------------------- sign on

  Future<void> signOn({String? profileHtml, String? awayHtml}) async {
    final (bosAddr, cookie) = await _authenticate();
    final bos = await _connectService(bosAddr, cookie);
    _bos = bos;
    try {
      await _bosSetup(bos, profileHtml: profileHtml, awayHtml: awayHtml);
    } catch (_) {
      bos.debugKill();
      rethrow;
    }
  }

  Future<void> _bosSetup(FlapConnection bos, {String? profileHtml, String? awayHtml}) async {
    bos.frames.listen((f) {
      if (f.channel == 4) _handleSignOffFrame(f);
    });
    bos.snacs.listen(_dispatch);
    bos.done.then((reason) {
      _end(_signingOff
          ? const OscarDisconnect(DisconnectKind.userSignOff, 'Signed off')
          : OscarDisconnect(DisconnectKind.network, 'Connection lost ($reason)'));
    });

    await _negotiate(bos, const [
      (0x0001, 4),
      (0x0002, 1),
      (0x0003, 1),
      (0x0004, 1),
      (0x0009, 1),
      (0x0013, 4),
      (0x0010, 1),
    ]);

    bos.sendSnac(0x0001, 0x000e, const []); // self info

    // Buddy list
    bos.sendSnac(0x0013, 0x0002, const []);
    await _loadFeedbag(bos);
    bos.sendSnac(0x0013, 0x0007, const []); // activate

    // Locate: profile, away, capabilities
    bos.sendSnac(0x0002, 0x0002, const []);
    bos.sendSnac(0x0002, 0x0004, _locateInfo(profileHtml: profileHtml ?? '', awayHtml: awayHtml));

    bos.sendSnac(0x0003, 0x0002, const []); // buddy rights
    bos.sendSnac(0x0004, 0x0004, const []); // ICBM params query
    final icbm = ByteWriter()
      ..u16(0) // channel 0 = all
      ..u32(0x0000000b) // channel msgs, missed calls, typing notifications
      ..u16(8000)
      ..u16(999)
      ..u16(999)
      ..u32(0);
    bos.sendSnac(0x0004, 0x0002, icbm.toBytes());
    bos.sendSnac(0x0009, 0x0002, const []); // PD rights

    final ready = ByteWriter();
    for (final f in const [
      (0x0001, 4),
      (0x0002, 1),
      (0x0003, 1),
      (0x0004, 1),
      (0x0009, 1),
      (0x0013, 4),
      (0x0010, 1),
    ]) {
      ready
        ..u16(f.$1)
        ..u16(f.$2)
        ..u16(0x0110)
        ..u16(0x08e5);
    }
    bos.sendSnac(0x0001, 0x0002, ready.toBytes());
    bos.startKeepAlive();
  }

  Future<(ServerConfig, Uint8List)> _authenticate() async {
    final auth = await FlapConnection.connect(server.host, server.port);
    try {
      // Speak first (the AIM Server app routes connections by their first
      // byte, so this skips its short wait), then take the server's greeting.
      final greeting = auth.expectFrame(1, timeout: const Duration(seconds: 10));
      auth.send(1, (ByteWriter()..u32(1)).toBytes());
      try {
        await greeting;
      } on OscarTimeout {
        // some servers never greet
      }

      final chal = ByteWriter()
        ..tlvString(0x0001, screenName)
        ..tlv(0x004b, const [])
        ..tlv(0x005a, const []);
      final keyF = auth.expect(const [(0x0017, 0x0007), (0x0017, 0x0003), (0x0017, 0x0001)]);
      auth.sendSnac(0x0017, 0x0006, chal.toBytes());
      final keyReply = await keyF;
      if (keyReply.subtype != 0x0007) {
        throw _loginError(keyReply);
      }
      final kr = keyReply.reader;
      final key = kr.bytes(kr.u16());

      final pwMd5 = md5.convert(utf8.encode(password)).bytes;
      final hash = md5.convert([...key, ...pwMd5, ...ascii.encode(_aimMd5Salt)]).bytes;

      final login = ByteWriter()
        ..tlvString(0x0001, screenName)
        ..tlvString(0x0003, _clientIdString)
        ..tlv(0x0025, hash)
        ..tlv(0x004c, const [])
        ..tlvU16(0x0016, 0x0109)
        ..tlvU16(0x0017, 5)
        ..tlvU16(0x0018, 1)
        ..tlvU16(0x0019, 0)
        ..tlvU16(0x001a, 3036)
        ..tlvU32(0x0014, 0x000000d2)
        ..tlvString(0x000f, 'en')
        ..tlvString(0x000e, 'us')
        ..tlvU8(0x004a, 1);
      final replyF = auth.expect(const [(0x0017, 0x0003), (0x0017, 0x0001)]);
      auth.sendSnac(0x0017, 0x0002, login.toBytes());
      final reply = await replyF;
      if (reply.subtype != 0x0003) throw _loginError(reply);
      final t = reply.reader.tlvs();
      final err = t[0x0008];
      if (err != null) throw _authErrorCode(err.asU16);
      final addr = t[0x0005]?.asString;
      final cookie = t[0x0006]?.value;
      if (addr == null || cookie == null) {
        throw const OscarDisconnect(DisconnectKind.serverError, 'Server did not send a BOS address');
      }
      formattedScreenName = t[0x0001]?.asString ?? screenName;
      return (_redirectTarget(addr), Uint8List.fromList(cookie));
    } finally {
      await auth.close();
    }
  }

  ServerConfig _redirectTarget(String addr) {
    final r = ServerConfig.parse(addr, defaultPort: server.port);
    if (!fixLoopbackRedirects) return r;
    bool loop(String h) =>
        h == 'localhost' || h.startsWith('127.') || h == '0.0.0.0' || h == '::1' || h == '::';
    if (loop(r.host) && !loop(server.host)) return ServerConfig(server.host, r.port);
    return r;
  }

  OscarDisconnect _loginError(Snac s) {
    if (s.subtype == 0x0001) {
      final code = s.data.length >= 2 ? (s.data[0] << 8) | s.data[1] : 0;
      return OscarDisconnect(DisconnectKind.serverError, 'Sign-on error 0x${code.toRadixString(16)}');
    }
    final t = s.reader.tlvs();
    final code = t[0x0008]?.asU16 ?? 0;
    return _authErrorCode(code);
  }

  OscarDisconnect _authErrorCode(int code) {
    switch (code) {
      case 0x0001:
      case 0x0004:
      case 0x0005:
        return const OscarDisconnect(DisconnectKind.badPassword, 'Incorrect screen name or password.');
      case 0x0011:
        return const OscarDisconnect(DisconnectKind.badPassword, 'This account is suspended.');
      case 0x0018:
      case 0x001d: // Open OSCAR Server: too many sign-ons from this address
        return const OscarDisconnect(
            DisconnectKind.rateLimited, 'Connecting too frequently. Waiting before trying again.');
      case 0x001c:
        return const OscarDisconnect(DisconnectKind.serverError, 'Server says this client version is too old.');
      default:
        return OscarDisconnect(DisconnectKind.serverError, 'Sign-on failed (error 0x${code.toRadixString(16)}).');
    }
  }

  Future<FlapConnection> _connectService(ServerConfig addr, Uint8List cookie) async {
    FlapConnection conn;
    try {
      conn = await FlapConnection.connect(addr.host, addr.port);
    } catch (_) {
      if (addr.host == server.host) rethrow;
      conn = await FlapConnection.connect(server.host, addr.port);
    }
    final greeting = conn.expectFrame(1, timeout: const Duration(seconds: 10));
    final hello = ByteWriter()
      ..u32(1)
      ..tlv(0x0006, cookie);
    conn.send(1, hello.toBytes());
    try {
      await greeting;
    } on OscarTimeout {
      // continue anyway
    }
    return conn;
  }

  /// Host-online -> versions -> rate limits handshake.
  Future<void> _negotiate(FlapConnection c, List<(int, int)> families) async {
    await c.expect(const [(0x0001, 0x0003)]);
    final v = ByteWriter();
    for (final f in families) {
      v
        ..u16(f.$1)
        ..u16(f.$2);
    }
    final verF = c.expect(const [(0x0001, 0x0018)]);
    c.sendSnac(0x0001, 0x0017, v.toBytes());
    await verF;
    final rateF = c.expect(const [(0x0001, 0x0007)]);
    c.sendSnac(0x0001, 0x0006, const []);
    final rates = await rateF;
    final rr = rates.reader;
    final n = rr.remaining >= 2 ? rr.u16() : 0;
    final ack = ByteWriter();
    for (var i = 1; i <= n; i++) {
      ack.u16(i);
    }
    c.sendSnac(0x0001, 0x0008, ack.toBytes());
  }

  Future<void> _loadFeedbag(FlapConnection bos) async {
    feedbag.clear();
    final first = bos.expect(const [(0x0013, 0x0006), (0x0013, 0x000f)]);
    bos.sendSnac(0x0013, 0x0004, const []);
    var s = await first;
    while (true) {
      if (s.subtype == 0x000f) break; // list unchanged / empty
      final r = s.reader;
      r.u8(); // version
      final count = r.u16();
      for (var i = 0; i < count; i++) {
        feedbag.add(FeedbagItem.read(r));
      }
      if (!s.moreFollows) break;
      s = await bos.expect(const [(0x0013, 0x0006)]);
    }
    _emit(BuddyListChanged());
  }

  Uint8List _locateInfo({required String profileHtml, String? awayHtml}) {
    final w = ByteWriter()
      ..tlvString(0x0001, 'text/aolrtf; charset="us-ascii"')
      ..tlvString(0x0002, profileHtml)
      ..tlvString(0x0003, 'text/aolrtf; charset="us-ascii"')
      ..tlvString(0x0004, awayHtml ?? '')
      ..tlv(0x0005, _caps.expand((c) => c).toList());
    return w.toBytes();
  }

  // ---------------------------------------------------------------- events

  void _dispatch(Snac s) {
    try {
      switch ((s.family, s.subtype)) {
        case (0x0003, 0x000b):
          final r = s.reader;
          while (r.remaining > 0) {
            final info = UserInfo.read(r);
            online[normalizeSn(info.screenName)] = info;
            _emit(BuddyArrived(info));
          }
        case (0x0003, 0x000c):
          final r = s.reader;
          while (r.remaining > 0) {
            final info = UserInfo.read(r);
            online.remove(normalizeSn(info.screenName));
            _emit(BuddyDeparted(info.screenName));
          }
        case (0x0004, 0x0007):
          _onIncomingIcbm(s);
        case (0x0004, 0x0014):
          final r = s.reader;
          r.bytes(8);
          r.u16();
          final sn = r.str8();
          final st = r.u16();
          _emit(TypingChanged(sn, st));
        case (0x0001, 0x000f):
          final info = UserInfo.read(s.reader);
          formattedScreenName = info.screenName;
          _emit(SelfInfoChanged(info));
        case (0x0013, 0x0008):
        case (0x0013, 0x0009):
        case (0x0013, 0x000a):
          _applyRemoteFeedbagChange(s);
        default:
          break;
      }
    } catch (_) {
      // Ignore one malformed packet rather than dropping the session.
    }
  }

  void _onIncomingIcbm(Snac s) {
    final r = s.reader;
    r.bytes(8); // cookie
    final channel = r.u16();
    final info = UserInfo.read(r);
    if (channel == 2) {
      final data = r.tlvs()[0x0005];
      if (data == null || data.value.length < 26) return;
      final rdv = Rendezvous.parse(data.value);
      if (rdv.isDirectIm || rdv.isSendFile) {
        _emit(RendezvousReceived(info.screenName, rdv));
      } else {
        final inv = RoomInvite.fromRendezvous(info.screenName, rdv);
        if (inv != null) _emit(RoomInviteReceived(inv));
      }
      return;
    }
    if (channel != 1) return;
    final tlvs = r.tlvs();
    final msgData = tlvs[0x0002];
    if (msgData == null) return;
    final mr = msgData.reader;
    final parts = <String>[];
    while (mr.remaining >= 4) {
      final id = mr.u8();
      mr.u8();
      final len = mr.u16();
      final frag = mr.bytes(min(len, mr.remaining));
      if (id == 0x01 && frag.length >= 4) {
        final fr = ByteReader(frag);
        final cs = fr.u16();
        fr.u16();
        parts.add(decodeImText(cs, fr.rest()));
      }
    }
    final html = parts.join();
    _emit(MessageReceived(IncomingMessage(
      info.screenName,
      html,
      messageText(html),
      tlvs.has(0x0004),
      DateTime.now(),
    )));
  }

  void _applyRemoteFeedbagChange(Snac s) {
    final r = s.reader;
    final items = <FeedbagItem>[];
    while (r.remaining > 0) {
      items.add(FeedbagItem.read(r));
    }
    for (final it in items) {
      feedbag.removeWhere((e) => e.groupId == it.groupId && e.itemId == it.itemId && e.classId == it.classId);
      if (s.subtype != 0x000a) feedbag.add(it);
    }
    _emit(BuddyListChanged());
  }

  void _handleSignOffFrame(FlapFrame f) {
    final t = ByteReader(f.data).tlvs();
    final code = t[0x0009]?.asU16;
    if (code == 0x0001) {
      _end(const OscarDisconnect(DisconnectKind.signedOnElsewhere,
          'You were signed off because this screen name signed on somewhere else.'));
    } else if (!_signingOff) {
      _end(const OscarDisconnect(DisconnectKind.network, 'Server ended the session'));
    }
    _bos?.debugKill();
  }

  void _emit(OscarEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  void _end(OscarDisconnect d) {
    if (_ended.isCompleted) return;
    _ended.complete(d);
    _bart?.debugKill();
    _nav?.debugKill();
    for (final r in _rooms.toList()) {
      r.debugKill();
    }
    _rooms.clear();
    _events.close();
  }

  // ---------------------------------------------------------------- buddy list

  List<BuddyGroup> get groups {
    final root = feedbag.where((i) => i.classId == FeedbagItem.classGroup && i.groupId == 0).firstOrNull;
    final groupItems = feedbag.where((i) => i.classId == FeedbagItem.classGroup && i.groupId != 0).toList();
    final order = root?.order ?? const <int>[];
    groupItems.sort((a, b) {
      final ia = order.indexOf(a.groupId);
      final ib = order.indexOf(b.groupId);
      return (ia < 0 ? 9999 : ia).compareTo(ib < 0 ? 9999 : ib);
    });
    return groupItems.map((g) {
      final members = feedbag
          .where((i) => i.classId == FeedbagItem.classBuddy && i.groupId == g.groupId)
          .toList();
      final ord = g.order;
      members.sort((a, b) {
        final ia = ord.indexOf(a.itemId);
        final ib = ord.indexOf(b.itemId);
        return (ia < 0 ? 9999 : ia).compareTo(ib < 0 ? 9999 : ib);
      });
      return BuddyGroup(g.name, g.groupId, members.map((m) => m.name).toList());
    }).toList();
  }

  int _freeId(bool Function(int) used) {
    final rnd = Random();
    while (true) {
      final id = 1 + rnd.nextInt(0x7ffe);
      if (!used(id)) return id;
    }
  }

  Future<void> _feedbagEdit(void Function(FlapConnection bos) body, {bool awaitAck = true}) async {
    final bos = _requireBos();
    bos.sendSnac(0x0013, 0x0011, const []);
    final ackF = awaitAck ? bos.expect(const [(0x0013, 0x000e)]) : null;
    body(bos);
    bos.sendSnac(0x0013, 0x0012, const []);
    if (ackF != null) {
      final ack = await ackF;
      final r = ack.reader;
      while (r.remaining >= 2) {
        final code = r.u16();
        if (code != 0) throw Exception('Buddy list change rejected (code $code)');
      }
    }
    _emit(BuddyListChanged());
  }

  Uint8List _items(List<FeedbagItem> items) {
    final w = ByteWriter();
    for (final i in items) {
      i.write(w);
    }
    return w.toBytes();
  }

  Future<void> addBuddy(String sn, String groupName) async {
    var group = feedbag
        .where((i) => i.classId == FeedbagItem.classGroup && i.groupId != 0 && i.name.toLowerCase() == groupName.toLowerCase())
        .firstOrNull;
    if (group == null) {
      await addGroup(groupName);
      group = feedbag.firstWhere((i) => i.classId == FeedbagItem.classGroup && i.name == groupName);
    }
    final g = group;
    final iid = _freeId((id) => feedbag.any((i) => i.groupId == g.groupId && i.itemId == id));
    final buddy = FeedbagItem(sn, g.groupId, iid, FeedbagItem.classBuddy, []);
    await _feedbagEdit((bos) {
      bos.sendSnac(0x0013, 0x0008, _items([buddy]));
      g.order = [...g.order, iid];
      bos.sendSnac(0x0013, 0x0009, _items([g]));
    });
    feedbag.add(buddy);
    _emit(BuddyListChanged());
  }

  Future<void> addGroup(String name) async {
    final gid = _freeId((id) => feedbag.any((i) => i.classId == FeedbagItem.classGroup && i.groupId == id));
    final group = FeedbagItem(name, gid, 0, FeedbagItem.classGroup, [Tlv(0xc8, Uint8List(0))]);
    var root = feedbag.where((i) => i.classId == FeedbagItem.classGroup && i.groupId == 0).firstOrNull;
    final createRoot = root == null;
    root ??= FeedbagItem('', 0, 0, FeedbagItem.classGroup, []);
    final r = root;
    await _feedbagEdit((bos) {
      bos.sendSnac(0x0013, 0x0008, _items([group]));
      r.order = [...r.order, gid];
      bos.sendSnac(0x0013, createRoot ? 0x0008 : 0x0009, _items([r]));
    });
    feedbag.add(group);
    if (createRoot) feedbag.add(r);
  }

  Future<void> removeBuddy(String sn) async {
    final key = normalizeSn(sn);
    final items = feedbag.where((i) => i.classId == FeedbagItem.classBuddy && normalizeSn(i.name) == key).toList();
    if (items.isEmpty) return;
    await _feedbagEdit((bos) {
      bos.sendSnac(0x0013, 0x000a, _items(items));
      for (final it in items) {
        final g = feedbag.where((i) => i.classId == FeedbagItem.classGroup && i.groupId == it.groupId).firstOrNull;
        if (g != null) {
          g.order = g.order.where((id) => id != it.itemId).toList();
          bos.sendSnac(0x0013, 0x0009, _items([g]));
        }
      }
    });
    feedbag.removeWhere(items.contains);
    _emit(BuddyListChanged());
  }

  FeedbagItem? _groupItem(int gid) =>
      feedbag.where((i) => i.classId == FeedbagItem.classGroup && i.groupId == gid && gid != 0).firstOrNull;
  FeedbagItem? get _rootGroup =>
      feedbag.where((i) => i.classId == FeedbagItem.classGroup && i.groupId == 0).firstOrNull;

  /// Renames a group (its buddies stay in it).
  Future<void> renameGroup(int gid, String name) async {
    final g = _groupItem(gid);
    if (g == null) throw Exception('That group no longer exists');
    if (feedbag.any((i) => i.classId == FeedbagItem.classGroup && i.groupId != gid &&
        i.name.toLowerCase() == name.toLowerCase())) {
      throw Exception('You already have a group called $name');
    }
    final old = g.name;
    g.name = name;
    try {
      await _feedbagEdit((bos) => bos.sendSnac(0x0013, 0x0009, _items([g])));
    } catch (_) {
      g.name = old;
      rethrow;
    }
  }

  /// Deletes a group. Its buddies move to [moveTo] (a group id), or are
  /// removed with it when [moveTo] is null.
  Future<void> removeGroup(int gid, {int? moveTo}) async {
    final g = _groupItem(gid);
    if (g == null) return;
    final members = feedbag.where((i) => i.classId == FeedbagItem.classBuddy && i.groupId == gid).toList();
    if (moveTo != null) {
      for (final m in members) {
        await moveBuddy(m.name, moveTo);
      }
    }
    final left = feedbag.where((i) => i.classId == FeedbagItem.classBuddy && i.groupId == gid).toList();
    final root = _rootGroup;
    await _feedbagEdit((bos) {
      if (left.isNotEmpty) bos.sendSnac(0x0013, 0x000a, _items(left));
      bos.sendSnac(0x0013, 0x000a, _items([g]));
      if (root != null) {
        root.order = root.order.where((id) => id != gid).toList();
        bos.sendSnac(0x0013, 0x0009, _items([root]));
      }
    });
    feedbag.removeWhere((i) => left.contains(i) || identical(i, g));
    _emit(BuddyListChanged());
  }

  /// Moves a buddy into another group (keeps its nickname and other details).
  Future<void> moveBuddy(String sn, int toGid) async {
    final key = normalizeSn(sn);
    final item = feedbag.where((i) => i.classId == FeedbagItem.classBuddy && normalizeSn(i.name) == key).firstOrNull;
    final to = _groupItem(toGid);
    if (item == null || to == null || item.groupId == toGid) return;
    final from = _groupItem(item.groupId);
    final iid = _freeId((id) => feedbag.any((i) => i.groupId == toGid && i.itemId == id));
    final moved = FeedbagItem(item.name, toGid, iid, FeedbagItem.classBuddy, item.attrs);
    await _feedbagEdit((bos) {
      bos.sendSnac(0x0013, 0x000a, _items([item]));
      if (from != null) {
        from.order = from.order.where((id) => id != item.itemId).toList();
        bos.sendSnac(0x0013, 0x0009, _items([from]));
      }
      bos.sendSnac(0x0013, 0x0008, _items([moved]));
      to.order = [...to.order, iid];
      bos.sendSnac(0x0013, 0x0009, _items([to]));
    });
    feedbag
      ..remove(item)
      ..add(moved);
    _emit(BuddyListChanged());
  }

  /// Moves a group up (-1) or down (+1) in the list.
  Future<void> moveGroup(int gid, int delta) async {
    final root = _rootGroup;
    if (root == null) return;
    final order = groups.map((g) => g.groupId).toList();
    final i = order.indexOf(gid);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= order.length) return;
    order
      ..removeAt(i)
      ..insert(j, gid);
    root.order = order;
    await _feedbagEdit((bos) => bos.sendSnac(0x0013, 0x0009, _items([root])));
  }

  /// Moves a buddy up (-1) or down (+1) inside its group.
  Future<void> moveBuddyWithinGroup(String sn, int delta) async {
    final key = normalizeSn(sn);
    final item = feedbag.where((i) => i.classId == FeedbagItem.classBuddy && normalizeSn(i.name) == key).firstOrNull;
    if (item == null) return;
    final g = _groupItem(item.groupId);
    if (g == null) return;
    final members = feedbag.where((i) => i.classId == FeedbagItem.classBuddy && i.groupId == g.groupId).toList();
    final ord = g.order;
    members.sort((a, b) {
      final ia = ord.indexOf(a.itemId), ib = ord.indexOf(b.itemId);
      return (ia < 0 ? 9999 : ia).compareTo(ib < 0 ? 9999 : ib);
    });
    final ids = members.map((m) => m.itemId).toList();
    final i = ids.indexOf(item.itemId), j = i + delta;
    if (i < 0 || j < 0 || j >= ids.length) return;
    ids
      ..removeAt(i)
      ..insert(j, item.itemId);
    g.order = ids;
    await _feedbagEdit((bos) => bos.sendSnac(0x0013, 0x0009, _items([g])));
  }

  // ---------------------------------------------------------------- block / warn

  bool isBlocked(String sn) {
    final key = normalizeSn(sn);
    return feedbag.any((i) => i.classId == FeedbagItem.classDeny && normalizeSn(i.name) == key);
  }

  bool isBuddy(String sn) {
    final key = normalizeSn(sn);
    return feedbag.any((i) => i.classId == FeedbagItem.classBuddy && normalizeSn(i.name) == key);
  }

  /// Blocks [sn] like AIM does: a deny-list entry, plus privacy mode
  /// "block the users on my block list" so the server enforces it.
  Future<void> block(String sn) async {
    if (isBlocked(sn)) return;
    final iid = _freeId((id) => feedbag.any((i) => i.groupId == 0 && i.itemId == id));
    final deny = FeedbagItem(sn, 0, iid, FeedbagItem.classDeny, []);
    const denySome = 0x04;
    final modeTlv = Tlv(0x00ca, Uint8List.fromList([denySome]));
    var pd = feedbag.where((i) => i.classId == FeedbagItem.classPdInfo).firstOrNull;
    final newPd = pd == null;
    final currentMode = pd?.attrs.where((t) => t.type == 0x00ca).firstOrNull?.value;
    final needMode = currentMode == null || currentMode.isEmpty || currentMode[0] != denySome;
    if (pd == null) {
      final pid = _freeId((id) => id == iid || feedbag.any((i) => i.groupId == 0 && i.itemId == id));
      pd = FeedbagItem('', 0, pid, FeedbagItem.classPdInfo, [modeTlv]);
    } else if (needMode) {
      pd.attrs = [...pd.attrs.where((t) => t.type != 0x00ca), modeTlv];
    }
    final p = pd;
    await _feedbagEdit((bos) {
      bos.sendSnac(0x0013, 0x0008, _items([deny]));
      if (newPd) {
        bos.sendSnac(0x0013, 0x0008, _items([p]));
      } else if (needMode) {
        bos.sendSnac(0x0013, 0x0009, _items([p]));
      }
    });
    feedbag.add(deny);
    if (newPd) feedbag.add(p);
    _emit(BuddyListChanged());
  }

  Future<void> unblock(String sn) async {
    final key = normalizeSn(sn);
    final items = feedbag.where((i) => i.classId == FeedbagItem.classDeny && normalizeSn(i.name) == key).toList();
    if (items.isEmpty) return;
    await _feedbagEdit((bos) => bos.sendSnac(0x0013, 0x000a, _items(items)));
    feedbag.removeWhere(items.contains);
    _emit(BuddyListChanged());
  }

  /// Warns [sn] (raises their warning level). Returns their new level in
  /// percent. The server only allows it after they've messaged you.
  Future<int> warn(String sn, {bool anonymous = false}) async {
    final bos = _requireBos();
    final w = ByteWriter()
      ..u16(anonymous ? 1 : 0)
      ..u8(sn.length)
      ..bytes(ascii.encode(sn));
    final f = bos.expect(const [(0x0004, 0x0009), (0x0004, 0x0001)], timeout: const Duration(seconds: 15));
    bos.sendSnac(0x0004, 0x0008, w.toBytes());
    final reply = await f;
    final r = reply.reader;
    if (reply.subtype == 0x0001) {
      final code = r.remaining >= 2 ? r.u16() : 0;
      throw Exception(switch (code) {
        0x0004 => '$sn isn\'t signed on (or one of you blocked the other).',
        0x000d => 'You can only warn someone after they message you, and only a few times.',
        _ => 'The server refused the warning (code 0x${code.toRadixString(16)}).',
      });
    }
    r.u16(); // amount added
    return ((r.remaining >= 2 ? r.u16() : 0) / 10).round();
  }

  // ---------------------------------------------------------------- messaging

  FlapConnection _requireBos() {
    final b = _bos;
    if (b == null || b.isClosed) throw ConnectionClosed('not signed on');
    return b;
  }

  Future<SendResult> sendIm(String to, String text, {bool autoResponse = false}) async {
    final bos = _requireBos();
    final rnd = Random();
    final cookie = Uint8List.fromList(List.generate(8, (_) => rnd.nextInt(256)));
    final (cs, body) = encodeImText(textToAimHtml(text));
    final frags = ByteWriter()
      ..u8(0x05)
      ..u8(0x01)
      ..u16(1)
      ..u8(0x01)
      ..u8(0x01)
      ..u8(0x01)
      ..u16(body.length + 4)
      ..u16(cs)
      ..u16(0)
      ..bytes(body);
    final w = ByteWriter()
      ..bytes(cookie)
      ..u16(1)
      ..str8(to)
      ..tlv(0x0002, frags.toBytes());
    if (autoResponse) {
      w.tlv(0x0004, const []);
    } else {
      w.tlv(0x0003, const []); // request host ack
    }
    final reqId = bos.nextReqId();
    if (autoResponse) {
      bos.sendSnac(0x0004, 0x0006, w.toBytes(), reqId: reqId);
      return SendResult.delivered;
    }
    final replyF = bos.expect(const [(0x0004, 0x000c), (0x0004, 0x0001)],
        reqId: reqId, timeout: const Duration(seconds: 15));
    bos.sendSnac(0x0004, 0x0006, w.toBytes(), reqId: reqId);
    try {
      final reply = await replyF;
      if (reply.subtype == 0x000c) return SendResult.delivered;
      final code = reply.data.length >= 2 ? (reply.data[0] << 8) | reply.data[1] : 0;
      if (code == 0x0004) return SendResult.recipientOffline;
      if (code == 0x0002 || code == 0x0003) return SendResult.rateLimited;
      return SendResult.failed;
    } on OscarTimeout {
      // Server never acked; assume it went through if we're still connected.
      return isOnline ? SendResult.delivered : SendResult.failed;
    } on ConnectionClosed {
      return SendResult.failed;
    }
  }

  /// Sends a Direct Connect handshake message (ICBM channel 2). Only this
  /// small message goes through the server.
  Future<SendResult> sendRendezvous(String to, Uint8List cookie, Uint8List data) async {
    final bos = _requireBos();
    final w = ByteWriter()
      ..bytes(cookie)
      ..u16(2)
      ..str8(to)
      ..tlv(0x0005, data)
      ..tlv(0x0003, const []);
    final reqId = bos.nextReqId();
    final replyF = bos.expect(const [(0x0004, 0x000c), (0x0004, 0x0001)],
        reqId: reqId, timeout: const Duration(seconds: 15));
    bos.sendSnac(0x0004, 0x0006, w.toBytes(), reqId: reqId);
    try {
      final reply = await replyF;
      if (reply.subtype == 0x000c) return SendResult.delivered;
      final code = reply.data.length >= 2 ? (reply.data[0] << 8) | reply.data[1] : 0;
      if (code == 0x0004) return SendResult.recipientOffline;
      if (code == 0x0002 || code == 0x0003) return SendResult.rateLimited;
      return SendResult.failed;
    } on OscarTimeout {
      return isOnline ? SendResult.delivered : SendResult.failed;
    } on ConnectionClosed {
      return SendResult.failed;
    }
  }

  /// This device's address on the connection to the server (its address on
  /// the home network, usually).
  String? get localIp => _bos?.localHost;

  void sendTyping(String to, int state) {
    final b = _bos;
    if (b == null || b.isClosed) return;
    final w = ByteWriter()
      ..bytes(Uint8List(8))
      ..u16(1)
      ..str8(to)
      ..u16(state);
    try {
      b.sendSnac(0x0004, 0x0014, w.toBytes());
    } catch (_) {}
  }

  // ---------------------------------------------------------------- profile / away

  /// [awayHtml] null or empty = back (not away).
  void setLocateInfo({required String profileHtml, String? awayHtml}) {
    _requireBos().sendSnac(0x0002, 0x0004, _locateInfo(profileHtml: profileHtml, awayHtml: awayHtml));
  }

  Future<ProfileInfo> getProfile(String sn) async {
    final bos = _requireBos();
    Future<Snac> query(int flags) {
      final id = bos.nextReqId();
      final f = bos.expect(const [(0x0002, 0x0006), (0x0002, 0x0001)], reqId: id);
      final w = ByteWriter()
        ..u32(flags)
        ..str8(sn);
      bos.sendSnac(0x0002, 0x0015, w.toBytes(), reqId: id);
      return f;
    }

    String? profile;
    String? away;
    UserInfo? user;
    for (final flags in const [0x00000001, 0x00000002]) {
      final s = await query(flags);
      if (s.subtype == 0x0001) {
        if (flags == 1) {
          throw Exception('$sn is not signed on or does not exist.');
        }
        continue;
      }
      final r = s.reader;
      user = UserInfo.read(r);
      final t = r.tlvs();
      String? dec(int mimeT, int textT) {
        final v = t[textT];
        if (v == null) return null;
        final mime = t[mimeT]?.asString ?? '';
        if (mime.contains('unicode')) return decodeImText(0x0002, v.value);
        return decodeImText(0x0000, v.value);
      }

      profile ??= dec(0x0001, 0x0002);
      away ??= dec(0x0003, 0x0004);
    }
    return ProfileInfo(sn, profileHtml: profile, awayHtml: away, user: user);
  }

  // ---------------------------------------------------------------- buddy icons

  /// Asks the main connection for another service (buddy icons, chat
  /// rooms...), connects to it and does the handshake. The caller listens
  /// for what it needs, then calls [_serviceReady].
  Future<FlapConnection> _openService(int family, List<(int, int)> families, {Uint8List? roomRef}) async {
    final bos = _requireBos();
    final id = bos.nextReqId();
    final f = bos.expect(const [(0x0001, 0x0005), (0x0001, 0x0001)], reqId: id);
    final w = ByteWriter()..u16(family);
    if (roomRef != null) w.tlv(0x0001, roomRef);
    bos.sendSnac(0x0001, 0x0004, w.toBytes(), reqId: id);
    final s = await f;
    if (s.subtype != 0x0005) throw ServiceUnavailable(family);
    final t = s.reader.tlvs();
    final addr = t[0x0005]?.asString;
    final cookie = t[0x0006]?.value;
    if (addr == null || cookie == null) throw ServiceUnavailable(family);
    final c = await _connectService(_redirectTarget(addr), Uint8List.fromList(cookie));
    try {
      await _negotiate(c, families);
    } catch (_) {
      c.debugKill();
      rethrow;
    }
    return c;
  }

  void _serviceReady(FlapConnection c, List<(int, int)> families) {
    final ready = ByteWriter();
    for (final f in families) {
      ready
        ..u16(f.$1)
        ..u16(f.$2)
        ..u16(0x0110)
        ..u16(0x08e5);
    }
    c.sendSnac(0x0001, 0x0002, ready.toBytes());
    c.startKeepAlive();
  }

  Future<FlapConnection> _bartConn() {
    final existing = _bart;
    if (existing != null && !existing.isClosed) return Future.value(existing);
    return _bartConnecting ??= () async {
      try {
        const fams = [(0x0001, 4), (0x0010, 1)];
        final FlapConnection c;
        try {
          c = await _openService(0x0010, fams);
        } on ServiceUnavailable {
          throw Exception('Buddy icon service unavailable');
        }
        _serviceReady(c, fams);
        _bart = c;
        return c;
      } finally {
        _bartConnecting = null;
      }
    }();
  }

  // ---------------------------------------------------------------- chat rooms

  FlapConnection? _nav;
  Future<FlapConnection>? _navConnecting;
  final Set<RoomConnection> _rooms = {};

  /// The chat navigation service: finds and makes rooms.
  Future<FlapConnection> _navConn() {
    final existing = _nav;
    if (existing != null && !existing.isClosed) return Future.value(existing);
    return _navConnecting ??= () async {
      try {
        const fams = [(0x0001, 4), (0x000d, 1)];
        final FlapConnection c;
        try {
          c = await _openService(0x000d, fams);
        } on ServiceUnavailable {
          throw Exception('This server doesn\'t have chat rooms.');
        }
        _serviceReady(c, fams);
        _nav = c;
        return c;
      } finally {
        _navConnecting = null;
      }
    }();
  }

  /// Finds the Buddy Chat room called [name], making it if nobody has.
  Future<RoomInfo> findOrCreateRoom(String name, {int exchange = privateExchange}) async {
    final c = await _navConn();
    final id = c.nextReqId();
    final f = c.expect(const [(0x000d, 0x0009), (0x000d, 0x0001)], reqId: id);
    final w = ByteWriter()
      ..u16(exchange)
      ..str8('create')
      ..u16(0xffff)
      ..u8(1)
      ..u16(3)
      ..tlvString(0x00d3, name)
      ..tlvString(0x00d6, 'us-ascii')
      ..tlvString(0x00d7, 'en');
    c.sendSnac(0x000d, 0x0008, w.toBytes(), reqId: id);
    final s = await f;
    final info = s.subtype == 0x0009 ? s.reader.tlvs()[0x0004] : null;
    if (info == null) throw Exception('The server couldn\'t open the room "$name".');
    return RoomInfo.readFull(info.reader);
  }

  /// Goes into [room]. Everything that happens there goes to [onEvent],
  /// starting with who is already inside.
  Future<RoomConnection> joinRoom(RoomInfo room, void Function(RoomEvent) onEvent) async {
    const fams = [(0x0001, 4), (0x000e, 1)];
    final FlapConnection c;
    try {
      c = await _openService(0x000e, fams, roomRef: room.ref);
    } on ServiceUnavailable {
      throw Exception('That room is gone or the server won\'t let you in.');
    }
    if (_ended.isCompleted) {
      c.debugKill();
      throw ConnectionClosed('signed off');
    }
    late final RoomConnection rc;
    rc = RoomConnection(room, c, (e) {
      if (e is RoomClosed) _rooms.remove(rc);
      onEvent(e);
    });
    _rooms.add(rc);
    _serviceReady(c, fams);
    return rc;
  }

  /// Invites [to] into [room] (only this small note goes through the server).
  Future<SendResult> sendRoomInvite(String to, RoomInfo room, String message) {
    final rnd = Random();
    final cookie = Uint8List.fromList(List.generate(8, (_) => rnd.nextInt(256)));
    return sendRendezvous(to, cookie, encodeRoomInvite(cookie, room, message));
  }

  Future<SendResult> declineRoomInvite(RoomInvite inv) =>
      sendRendezvous(inv.from, inv.cookie, encodeRoomDecline(inv.cookie));

  /// Uploads our buddy icon and records it in the buddy list.
  Future<void> setBuddyIcon(Uint8List icon) async {
    final hash = Uint8List.fromList(md5.convert(icon).bytes);
    final attr = Tlv(0x00d5, Uint8List.fromList([0x01, hash.length, ...hash]));
    final existing = feedbag.where((i) => i.classId == FeedbagItem.classBart && i.name == '1').firstOrNull;
    if (existing != null) {
      existing.attrs = [attr];
      await _feedbagEdit((bos) => bos.sendSnac(0x0013, 0x0009, _items([existing])));
    } else {
      final iid = _freeId((id) => feedbag.any((i) => i.groupId == 0 && i.itemId == id));
      final item = FeedbagItem('1', 0, iid, FeedbagItem.classBart, [attr]);
      await _feedbagEdit((bos) => bos.sendSnac(0x0013, 0x0008, _items([item])));
      feedbag.add(item);
    }
    final c = await _bartConn();
    final f = c.expect(const [(0x0010, 0x0003), (0x0010, 0x0001)], timeout: const Duration(seconds: 30));
    final w = ByteWriter()
      ..u16(0x0001)
      ..u16(icon.length)
      ..bytes(icon);
    c.sendSnac(0x0010, 0x0002, w.toBytes());
    final reply = await f;
    if (reply.subtype == 0x0001) throw Exception('Server rejected the buddy icon');
  }

  Future<Uint8List?> fetchBuddyIcon(String sn, Uint8List hash, {int flags = 0x01}) async {
    final c = await _bartConn();
    final f = c.expect(const [(0x0010, 0x0005), (0x0010, 0x0001)], timeout: const Duration(seconds: 30));
    final w = ByteWriter()
      ..str8(sn)
      ..u8(1)
      ..u16(0x0001)
      ..u8(flags)
      ..u8(hash.length)
      ..bytes(hash);
    c.sendSnac(0x0010, 0x0004, w.toBytes());
    final s = await f;
    if (s.subtype != 0x0005) return null;
    final r = s.reader;
    r.str8();
    r.u16();
    r.u8();
    r.bytes(r.u8());
    if (r.remaining < 2) return null;
    // Some servers put a status byte before the length.
    final save = r.pos;
    var len = r.u16();
    if (len != r.remaining) {
      r.pos = save;
      r.u8();
      if (r.remaining < 2) return null;
      len = r.u16();
    }
    if (len == 0 || len > r.remaining) return null;
    return Uint8List.fromList(r.bytes(len));
  }

  // ---------------------------------------------------------------- sign off

  Future<void> signOff() async {
    _signingOff = true;
    for (final r in _rooms.toList()) {
      await r.leave();
    }
    await _nav?.close();
    await _bart?.close();
    await _bos?.close();
    _end(const OscarDisconnect(DisconnectKind.userSignOff, 'Signed off'));
  }

  /// Drops the network link without signing off (tests / simulated loss).
  void debugDropConnection() {
    for (final r in _rooms.toList()) {
      r.debugKill();
    }
    _nav?.debugKill();
    _bart?.debugKill();
    _bos?.debugKill();
  }
}

/// The server said no to a service request (or doesn't have the service).
class ServiceUnavailable implements Exception {
  final int family;
  const ServiceUnavailable(this.family);
  @override
  String toString() => 'Service 0x${family.toRadixString(16)} unavailable';
}
