import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'aim_html.dart';
import 'bytes.dart';
import 'chat_room.dart';
import 'direct_connect.dart';
import 'file_transfer.dart';
import 'flap.dart' show ConnectionClosed;
import 'models.dart';
import 'peer_path.dart';
import 'session.dart';

enum LinkState {
  offline, // never signed on / signed off
  connecting,
  online,
  reconnecting, // lost the link, waiting to retry
  stopped, // gave up (bad password, signed on elsewhere)
}

enum OutboxStatus { queued, sending, waitingForBuddy, sent, failed, cancelled }

class OutgoingMessage {
  final String id;
  final String to;
  final String text;
  final DateTime created;
  OutboxStatus status;
  String? note;
  DateTime? nextTry;

  OutgoingMessage(this.id, this.to, this.text, this.created, this.status);

  bool get isPending =>
      status == OutboxStatus.queued || status == OutboxStatus.sending || status == OutboxStatus.waitingForBuddy;
}

sealed class ClientEvent {}

class SessionEvent extends ClientEvent {
  final OscarEvent event;
  SessionEvent(this.event);
}

class LinkStateChanged extends ClientEvent {
  final LinkState state;
  final String? message;
  LinkStateChanged(this.state, this.message);
}

class OutboxChanged extends ClientEvent {
  final OutgoingMessage message;
  OutboxChanged(this.message);
}

/// Something happened on Direct Connect (see [AimClient.direct]).
class DirectConnectEvent extends ClientEvent {
  final DirectEvent event;
  DirectConnectEvent(this.event);
}

/// A file transfer changed (see [AimClient.files]).
class FileTransferEvent extends ClientEvent {
  final XferChanged event;
  FileTransferEvent(this.event);
}

/// A chat room we're in (or want to be in: it rejoins after a dropped link).
class ClientRoom {
  RoomInfo info;
  RoomConnection? conn;
  Future<void>? _joining;
  int _failures = 0;
  Timer? _retry;
  ClientRoom(this.info);

  String get key => info.key;
  String get name => info.name;
  bool get isOpen => conn?.isOpen ?? false;
  bool get isJoining => _joining != null || _retry != null;

  /// Screen names in the room, sorted.
  List<String> get members {
    final m = conn?.members.values.map((u) => u.screenName).toList() ?? <String>[];
    m.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return m;
  }
}

/// Something happened in a room (or it opened, closed or was left).
class RoomUpdate extends ClientEvent {
  final ClientRoom room;

  /// null: the room just opened, or [left] is true.
  final RoomEvent? event;
  final bool left;
  RoomUpdate(this.room, this.event, {this.left = false});
}

/// Keeps one screen name signed on: reconnects when the link drops, holds
/// outgoing messages until they can be delivered, and answers with the away
/// message while away. Pure Dart so it runs in tests without Flutter.
class AimClient {
  ServerConfig server;
  String screenName;
  String password;
  String profileHtml;
  String? _awayHtml;
  bool fixLoopbackRedirects;

  /// Direct Connect (pictures straight between devices).
  late final DirectConnect direct;

  /// Send File (files straight between devices).
  late final FileTransfers files;

  /// Delays between reconnect attempts.
  List<Duration> backoff;

  AimClient({
    required this.server,
    required this.screenName,
    required this.password,
    this.profileHtml = '',
    this.fixLoopbackRedirects = true,
    bool useUpnp = true,
    Future<String?> Function()? publicIp,
    Future<String> Function()? receiveDir,
    Future<List<String>> Function()? deviceAddresses,
    this.backoff = const [
      Duration(seconds: 1),
      Duration(seconds: 3),
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 20),
      Duration(seconds: 30),
    ],
  }) {
    direct = DirectConnect(
      session: () => _session,
      myName: () => _session?.formattedScreenName ?? screenName,
      publicIp: publicIp,
      useUpnp: useUpnp,
    );
    direct.events.listen((e) => _emit(DirectConnectEvent(e)));
    files = FileTransfers(
      sendRdv: (to, cookie, data) async {
        final s = _session;
        if (s == null || !s.isOnline) return SendResult.failed;
        return s.sendRendezvous(to, cookie, data);
      },
      receiveDir: receiveDir ?? () async => Directory.systemTemp.path,
      path: PeerPath(
          useUpnp: useUpnp,
          publicIp: publicIp,
          sessionLocalIp: () => _session?.localIp,
          deviceAddresses: deviceAddresses),
    );
    files.events.listen((e) => _emit(FileTransferEvent(e)));
  }

  OscarSession? _session;
  LinkState _state = LinkState.offline;
  String? lastMessage;
  bool _wantOnline = false;
  int _attempt = 0;
  Timer? _retryTimer;
  Completer<void>? _wake;
  Timer? _pumpTimer;
  bool _pumping = false;
  final _events = StreamController<ClientEvent>.broadcast();
  final List<OutgoingMessage> outbox = [];
  final Map<String, DateTime> _lastAutoReply = {};

  /// Rooms we're in, by [RoomInfo.key].
  final Map<String, ClientRoom> rooms = {};
  int _idSeq = 0;

  Stream<ClientEvent> get events => _events.stream;
  LinkState get state => _state;
  OscarSession? get session => _session;
  bool get isOnline => _state == LinkState.online && (_session?.isOnline ?? false);
  String? get awayHtml => _awayHtml;
  bool get isAway => (_awayHtml ?? '').isNotEmpty;

  void _emit(ClientEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  void _setState(LinkState s, [String? msg]) {
    _state = s;
    lastMessage = msg;
    _emit(LinkStateChanged(s, msg));
  }

  // ------------------------------------------------------------- lifecycle

  /// Signs on and keeps the connection alive until [signOff].
  void start() {
    if (_wantOnline) return;
    _wantOnline = true;
    _attempt = 0;
    unawaited(_runLoop());
  }

  /// Skip the remaining backoff delay and try now (app resumed, network back).
  void retryNow() {
    if (!_wantOnline) return;
    _attempt = 0;
    _retryTimer?.cancel();
    final w = _wake;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _runLoop() async {
    while (_wantOnline) {
      _setState(_attempt == 0 ? LinkState.connecting : LinkState.reconnecting, lastMessage);
      final s = OscarSession(server, screenName, password, fixLoopbackRedirects: fixLoopbackRedirects);
      _session = s;
      final sub = s.events.listen(_onSessionEvent);
      OscarDisconnect result;
      try {
        await s.signOn(profileHtml: profileHtml, awayHtml: _awayHtml).timeout(const Duration(seconds: 45));
        _attempt = 0;
        _setState(LinkState.online, null);
        _schedulePump(Duration.zero);
        _rejoinRooms();
        result = await s.ended;
      } on OscarDisconnect catch (d) {
        result = d;
      } on TimeoutException {
        s.debugDropConnection();
        result = const OscarDisconnect(DisconnectKind.network, 'Sign-on timed out');
      } catch (e) {
        s.debugDropConnection();
        result = OscarDisconnect(DisconnectKind.network, _friendly(e));
      }
      await sub.cancel();
      for (final m in outbox) {
        if (m.status == OutboxStatus.sending) m.status = OutboxStatus.queued;
      }
      if (!_wantOnline || result.kind == DisconnectKind.userSignOff) break;
      if (result.kind == DisconnectKind.badPassword || result.kind == DisconnectKind.signedOnElsewhere) {
        _wantOnline = false;
        _setState(LinkState.stopped, result.message);
        return;
      }
      final idx = min(_attempt, backoff.length - 1);
      var delay = backoff[idx];
      if (result.kind == DisconnectKind.rateLimited && delay < const Duration(seconds: 60)) {
        delay = const Duration(seconds: 60);
      }
      _attempt++;
      _setState(LinkState.reconnecting, result.message);
      final wake = Completer<void>();
      _wake = wake;
      _retryTimer = Timer(delay, () {
        if (!wake.isCompleted) wake.complete();
      });
      await wake.future;
    }
    if (_state != LinkState.stopped) _setState(LinkState.offline, null);
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') || s.contains('Connection refused') || s.contains('Failed host lookup')) {
      return 'Can\'t reach the server';
    }
    return s;
  }

  /// Signs off on purpose. Disconnects are not sign-offs: the outbox survives a
  /// disconnect, but sign-off cancels anything still pending.
  Future<void> signOff() async {
    _wantOnline = false;
    _retryTimer?.cancel();
    final w = _wake;
    if (w != null && !w.isCompleted) w.complete();
    await direct.closeAll();
    await files.closeAll();
    for (final r in rooms.values) {
      r._retry?.cancel();
    }
    final left = rooms.values.toList();
    rooms.clear();
    await _session?.signOff();
    for (final r in left) {
      _emit(RoomUpdate(r, null, left: true));
    }
    for (final m in outbox.where((m) => m.isPending).toList()) {
      m.status = OutboxStatus.cancelled;
      _emit(OutboxChanged(m));
    }
    outbox.clear();
    _setState(LinkState.offline, null);
  }

  // ------------------------------------------------------------- events

  void _onSessionEvent(OscarEvent e) {
    _emit(SessionEvent(e));
    switch (e) {
      case BuddyArrived(:final info):
        final key = normalizeSn(info.screenName);
        var any = false;
        for (final m in outbox) {
          if (m.status == OutboxStatus.waitingForBuddy && normalizeSn(m.to) == key) {
            m.status = OutboxStatus.queued;
            m.note = null;
            _emit(OutboxChanged(m));
            any = true;
          }
        }
        if (any) _schedulePump(Duration.zero);
      case MessageReceived(:final message):
        if (isAway && !message.autoResponse) _maybeAutoReply(message.from);
      case RendezvousReceived(:final from, :final rdv):
        if (rdv.isSendFile) {
          files.onRendezvous(from, rdv);
        } else {
          direct.onRendezvous(from, rdv);
        }
      default:
        break;
    }
  }

  void _maybeAutoReply(String to) {
    final key = normalizeSn(to);
    final last = _lastAutoReply[key];
    final now = DateTime.now();
    if (last != null && now.difference(last) < const Duration(minutes: 5)) return;
    _lastAutoReply[key] = now;
    final s = _session;
    if (s == null || !s.isOnline) return;
    // The away message is stored as AIM HTML; sendIm wants plain text (it adds
    // the HTML itself), otherwise the tags arrive as visible text.
    final text = htmlToText(_awayHtml ?? '');
    if (text.isEmpty) return;
    s.sendIm(to, text, autoResponse: true).ignore();
  }

  // ------------------------------------------------------------- away / profile

  /// [text] null or empty means "I'm back".
  void setAway(String? text) {
    _awayHtml = (text == null || text.isEmpty) ? null : text;
    if (_awayHtml == null) _lastAutoReply.clear();
    _pushLocate();
  }

  void setProfile(String html) {
    profileHtml = html;
    _pushLocate();
  }

  void _pushLocate() {
    final s = _session;
    if (s != null && s.isOnline) {
      try {
        s.setLocateInfo(profileHtml: profileHtml, awayHtml: _awayHtml);
      } catch (_) {}
    }
  }

  // ------------------------------------------------------------- outbox

  OutgoingMessage send(String to, String text) {
    final m = OutgoingMessage(
        '${DateTime.now().microsecondsSinceEpoch}-${_idSeq++}', to, text, DateTime.now(), OutboxStatus.queued);
    outbox.add(m);
    _emit(OutboxChanged(m));
    _schedulePump(Duration.zero);
    return m;
  }

  bool cancel(String id) {
    final m = outbox.where((m) => m.id == id).firstOrNull;
    if (m == null || !m.isPending || m.status == OutboxStatus.sending) return false;
    m.status = OutboxStatus.cancelled;
    outbox.remove(m);
    _emit(OutboxChanged(m));
    return true;
  }

  /// Resend a failed message.
  void retry(String id) {
    final m = outbox.where((m) => m.id == id).firstOrNull;
    if (m == null || m.status != OutboxStatus.failed) return;
    m.status = OutboxStatus.queued;
    m.note = null;
    _emit(OutboxChanged(m));
    _schedulePump(Duration.zero);
  }

  void _schedulePump(Duration d) {
    _pumpTimer?.cancel();
    _pumpTimer = Timer(d, _pump);
  }

  bool _buddyKnownOffline(OscarSession s, String sn) {
    final key = normalizeSn(sn);
    final onList = s.feedbag.any((i) => i.classId == FeedbagItem.classBuddy && normalizeSn(i.name) == key);
    return onList && !s.online.containsKey(key);
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        final s = _session;
        if (s == null || !s.isOnline || _state != LinkState.online) return;
        final now = DateTime.now();
        // Messages to people we can't see on the buddy list get retried slowly.
        for (final m in outbox) {
          if (m.status == OutboxStatus.waitingForBuddy && m.nextTry != null && now.isAfter(m.nextTry!)) {
            m.status = OutboxStatus.queued;
          }
        }
        final next = outbox
            .where((m) => m.status == OutboxStatus.queued && (m.nextTry == null || now.isAfter(m.nextTry!)))
            .firstOrNull;
        if (next == null) {
          final waits = outbox.where((m) => m.nextTry != null && m.isPending).map((m) => m.nextTry!);
          if (waits.isNotEmpty) {
            final soonest = waits.reduce((a, b) => a.isBefore(b) ? a : b);
            _schedulePump(soonest.difference(now) + const Duration(milliseconds: 50));
          }
          return;
        }
        if (_buddyKnownOffline(s, next.to)) {
          next.status = OutboxStatus.waitingForBuddy;
          next.note = 'Will send when ${next.to} signs on';
          next.nextTry = null;
          _emit(OutboxChanged(next));
          continue;
        }
        next.status = OutboxStatus.sending;
        _emit(OutboxChanged(next));
        final r = await s.sendIm(next.to, next.text);
        if (next.status == OutboxStatus.cancelled) continue;
        switch (r) {
          case SendResult.delivered:
            next.status = OutboxStatus.sent;
            next.note = null;
            outbox.remove(next);
          case SendResult.recipientOffline:
            next.status = OutboxStatus.waitingForBuddy;
            next.note = 'Will send when ${next.to} signs on';
            next.nextTry = DateTime.now().add(const Duration(minutes: 2));
          case SendResult.rateLimited:
            next.status = OutboxStatus.queued;
            next.note = 'Slowing down (server rate limit)';
            next.nextTry = DateTime.now().add(const Duration(seconds: 5));
          case SendResult.failed:
            if (s.isOnline) {
              next.status = OutboxStatus.failed;
              next.note = 'Not delivered';
            } else {
              next.status = OutboxStatus.queued; // link dropped; resend after reconnect
            }
        }
        _emit(OutboxChanged(next));
      }
    } finally {
      _pumping = false;
    }
  }

  // ------------------------------------------------------------- chat rooms

  /// Goes into the room called [name] (making it if needed). Returns its key.
  Future<ClientRoom> joinRoom(String name) async {
    final s = _session;
    if (s == null || !isOnline) throw Exception('Not signed on');
    final clean = cleanRoomName(name);
    if (clean.isEmpty) throw Exception('Type a room name (letters and numbers).');
    final already = rooms.values.where((r) => r.name.toLowerCase() == clean.toLowerCase()).firstOrNull;
    if (already != null && already.isOpen) return already;
    final info = await s.findOrCreateRoom(clean);
    return _enter(info);
  }

  /// Goes into the room a buddy invited us to.
  Future<ClientRoom> acceptRoomInvite(RoomInvite inv) {
    if (!isOnline) throw Exception('Not signed on');
    return _enter(inv.room);
  }

  Future<void> declineRoomInvite(RoomInvite inv) async {
    final s = _session;
    if (s == null || !s.isOnline) return;
    try {
      await s.declineRoomInvite(inv);
    } catch (_) {}
  }

  Future<ClientRoom> _enter(RoomInfo info) async {
    final r = rooms.putIfAbsent(info.key, () => ClientRoom(info));
    r._failures = 0;
    r._retry?.cancel();
    r._retry = null;
    await _connectRoom(r);
    return r;
  }

  Future<void> _connectRoom(ClientRoom r) {
    if (r.isOpen) return Future.value();
    return r._joining ??= () async {
      try {
        final s = _session;
        if (s == null || !s.isOnline) throw ConnectionClosed('not signed on');
        final c = await s.joinRoom(r.info, (e) => _onRoomEvent(r, e));
        if (!rooms.containsKey(r.key)) {
          await c.leave(); // left while we were joining
          return;
        }
        r.conn = c;
        r.info = c.info;
        r._failures = 0;
        _emit(RoomUpdate(r, null));
      } finally {
        r._joining = null;
      }
    }();
  }

  void _onRoomEvent(ClientRoom r, RoomEvent e) {
    if (e is RoomInfoChanged) r.info = r.conn?.info ?? r.info;
    if (e is RoomClosed && rooms[r.key] == r) {
      r.conn = null;
      _scheduleRoomRetry(r);
    }
    if (rooms.containsKey(r.key)) _emit(RoomUpdate(r, e));
  }

  /// A room dropped on its own (main link still up): try again shortly.
  /// If the whole session dropped, [_rejoinRooms] runs after reconnecting.
  void _scheduleRoomRetry(ClientRoom r) {
    if (!_wantOnline || r._retry != null) return;
    final delay = backoff[min(r._failures, backoff.length - 1)];
    r._failures++;
    r._retry = Timer(delay, () {
      r._retry = null;
      if (rooms[r.key] != r || !isOnline || r.isOpen) return;
      _connectRoom(r).catchError((Object _) {
        if (rooms[r.key] == r && r._failures < 6) _scheduleRoomRetry(r);
        _emit(RoomUpdate(r, RoomClosed('rejoin failed')));
      });
    });
  }

  void _rejoinRooms() {
    for (final r in rooms.values.toList()) {
      r._retry?.cancel();
      r._retry = null;
      r._failures = 0;
      if (!r.isOpen) {
        _connectRoom(r).catchError((Object _) => _scheduleRoomRetry(r));
      }
    }
  }

  Future<void> leaveRoom(String key) async {
    final r = rooms.remove(key);
    if (r == null) return;
    r._retry?.cancel();
    final c = r.conn;
    r.conn = null;
    _emit(RoomUpdate(r, null, left: true));
    await c?.leave();
  }

  /// Says [text] in the room. False when the room isn't connected right now.
  bool sendToRoom(String key, String text) {
    final c = rooms[key]?.conn;
    if (c == null || !c.isOpen) return false;
    try {
      c.send(text);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Invites buddies into a room. Returns the ones it couldn't reach.
  Future<List<String>> inviteToRoom(String key, List<String> who, String message) async {
    final s = _session;
    final r = rooms[key];
    if (s == null || !s.isOnline || r == null) throw Exception('Not signed on');
    final failed = <String>[];
    for (final sn in who) {
      try {
        final res = await s.sendRoomInvite(sn, r.info, message);
        if (res != SendResult.delivered) failed.add(sn);
      } catch (_) {
        failed.add(sn);
      }
    }
    return failed;
  }

  /// Simulate a dropped network (tests).
  void debugDropConnection() => _session?.debugDropConnection();

  Future<void> dispose() async {
    await signOff();
    await direct.dispose();
    await files.dispose();
    await _events.close();
  }
}
