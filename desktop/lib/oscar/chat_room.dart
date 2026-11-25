import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'aim_html.dart';
import 'bytes.dart';
import 'flap.dart';
import 'models.dart';
import 'rendezvous.dart';

/// AIM capability for chat rooms ("Buddy Chat"). Invites use it.
final capChat = unhex('748f2420628711d18222444553540000');

/// The exchange for rooms people make themselves (AIM's Buddy Chat).
const privateExchange = 4;

/// Which room: the three values the server uses to find it, plus its name.
class RoomInfo {
  final int exchange;
  final String cookie;
  final int instance;
  final String name;
  const RoomInfo(this.exchange, this.cookie, this.instance, this.name);

  /// Stable id for this room on this device.
  String get key => cookie.toLowerCase();

  /// exchange, cookie, instance (how a room is named inside requests).
  void writeRef(ByteWriter w) => w
    ..u16(exchange)
    ..str8(cookie)
    ..u16(instance);

  Uint8List get ref {
    final w = ByteWriter();
    writeRef(w);
    return w.toBytes();
  }

  static RoomInfo readRef(ByteReader r) {
    final ex = r.u16();
    final cookie = r.str8();
    final inst = r.u16();
    return RoomInfo(ex, cookie, inst, nameFromCookie(cookie));
  }

  /// A full room description: the reference, a detail level and its TLVs.
  static RoomInfo readFull(ByteReader r) {
    final ex = r.u16();
    final cookie = r.str8();
    final inst = r.u16();
    var name = nameFromCookie(cookie);
    if (r.remaining >= 3) {
      r.u8(); // detail level
      final count = r.u16();
      final t = r.tlvs(count);
      final n = t[0x00d3]?.asString ?? t[0x006a]?.asString;
      if (n != null && n.isNotEmpty) name = n;
    }
    return RoomInfo(ex, cookie, inst, name);
  }

  /// Room cookies look like "4-0-Room Name"; the name is the last part.
  static String nameFromCookie(String cookie) {
    final parts = cookie.split('-');
    if (parts.length >= 3 && int.tryParse(parts[0]) != null && int.tryParse(parts[1]) != null) {
      return parts.sublist(2).join('-');
    }
    return cookie;
  }

  RoomInfo withName(String n) => RoomInfo(exchange, cookie, instance, n);
}

/// Room names travel as plain ASCII; keep what people type readable.
String cleanRoomName(String name) {
  final s = name.trim().replaceAll(RegExp(r'[^\x20-\x7e]'), '').replaceAll(RegExp(r'\s+'), ' ');
  return s.length > 64 ? s.substring(0, 64).trim() : s;
}

// ------------------------------------------------------------------ messages

class RoomMessage {
  final String from;
  final String html;
  final String text;
  final DateTime time;
  const RoomMessage(this.from, this.html, this.text, this.time);
}

int _charsetCode(String name) {
  final n = name.toLowerCase();
  if (n.contains('unicode') || n.contains('utf-16') || n.contains('ucs')) return 0x0002;
  if (n.contains('8859') || n.contains('latin')) return 0x0003;
  return 0x0000; // ascii / utf-8
}

/// The body of SNAC(0x0E,0x05): a message to everyone in the room.
Uint8List encodeRoomMessage(String html, {Random? random}) {
  final rnd = random ?? Random();
  final (cs, body) = encodeImText(html);
  final info = ByteWriter()
    ..tlv(0x0001, body)
    ..tlvString(0x0002, cs == 0x0002 ? 'unicode-2-0' : 'us-ascii')
    ..tlvString(0x0003, 'en');
  return (ByteWriter()
        ..bytes(List.generate(8, (_) => rnd.nextInt(256)))
        ..u16(3) // chat channel
        ..tlv(0x0001, const []) // to the whole room
        ..tlv(0x0005, info.toBytes()))
      .toBytes();
}

/// Reads SNAC(0x0E,0x06), a message someone said in the room.
RoomMessage? parseRoomMessage(Uint8List data) {
  final r = ByteReader(data);
  if (r.remaining < 10) return null;
  r.bytes(8);
  r.u16();
  final t = r.tlvs();
  final info = t[0x0005];
  if (info == null) return null;
  final sender = t[0x0003];
  final from = sender == null ? '' : UserInfo.read(sender.reader).screenName;
  final it = info.reader.tlvs();
  final text = it[0x0001];
  if (text == null) return null;
  final html = decodeImText(_charsetCode(it[0x0002]?.asString ?? ''), text.value);
  return RoomMessage(from, html, messageText(html), DateTime.now());
}

// ------------------------------------------------------------------ invites

/// "Join me in this room" from a buddy.
class RoomInvite {
  final String from;
  final RoomInfo room;
  final String message;
  final Uint8List cookie;
  final DateTime time;
  RoomInvite(this.from, this.room, this.message, this.cookie, this.time);

  static RoomInvite? fromRendezvous(String from, Rendezvous rdv) {
    if (hex(rdv.cap) != hex(capChat) || rdv.type != Rendezvous.propose) return null;
    final ref = rdv.tlvs[0x2711];
    if (ref == null || ref.value.length < 5) return null;
    final RoomInfo room;
    try {
      room = RoomInfo.readRef(ref.reader);
    } catch (_) {
      return null;
    }
    final msg = rdv.tlvs[0x000c];
    final cs = _charsetCode(rdv.tlvs[0x000d]?.asString ?? '');
    final text = msg == null ? '' : htmlToText(decodeImText(cs, msg.value));
    return RoomInvite(from, room, text, rdv.cookie, DateTime.now());
  }
}

/// The ICBM channel-2 payload inviting someone into [room].
Uint8List encodeRoomInvite(Uint8List cookie, RoomInfo room, String message) {
  final ascii = isAscii(message);
  return (ByteWriter()
        ..u16(Rendezvous.propose)
        ..bytes(cookie)
        ..bytes(capChat)
        ..tlvU16(0x000a, 1)
        ..tlv(0x000f, const [])
        ..tlvString(0x000c, message)
        ..tlvString(0x000d, ascii ? 'us-ascii' : 'utf-8')
        ..tlvString(0x000e, 'en')
        ..tlv(0x2711, room.ref))
      .toBytes();
}

/// "No thanks" to an invite.
Uint8List encodeRoomDecline(Uint8List cookie) => (ByteWriter()
      ..u16(Rendezvous.cancel)
      ..bytes(cookie)
      ..bytes(capChat)
      ..tlvU16(0x000b, Rendezvous.reasonDeclined))
    .toBytes();

// ------------------------------------------------------------------ connection

sealed class RoomEvent {}

/// People came in or went out. [initial] is the list we got when joining.
class RoomMembersChanged extends RoomEvent {
  final List<String> joined;
  final List<String> left;
  final bool initial;
  RoomMembersChanged(this.joined, this.left, {this.initial = false});
}

class RoomMessageReceived extends RoomEvent {
  final RoomMessage message;
  RoomMessageReceived(this.message);
}

class RoomInfoChanged extends RoomEvent {}

class RoomClosed extends RoomEvent {
  final String reason;
  RoomClosed(this.reason);
}

/// One open room: its own connection to the server's chat service.
class RoomConnection {
  RoomInfo info;
  final FlapConnection _c;
  final void Function(RoomEvent) _onEvent;

  /// Who is in the room, by normalised screen name.
  final Map<String, UserInfo> members = {};
  bool _gotList = false;

  RoomConnection(this.info, this._c, this._onEvent) {
    _c.snacs.listen(_on);
    _c.done.then((reason) => _onEvent(RoomClosed(reason)));
  }

  bool get isOpen => !_c.isClosed;

  void _on(Snac s) {
    if (s.family != 0x000e) return;
    try {
      switch (s.subtype) {
        case 0x0002:
          final n = RoomInfo.readFull(s.reader);
          if (n.name != info.name) {
            info = info.withName(n.name);
            _onEvent(RoomInfoChanged());
          }
        case 0x0003:
          final r = s.reader;
          final joined = <String>[];
          while (r.remaining > 0) {
            final u = UserInfo.read(r);
            members[normalizeSn(u.screenName)] = u;
            joined.add(u.screenName);
          }
          final initial = !_gotList;
          _gotList = true;
          _onEvent(RoomMembersChanged(joined, const [], initial: initial));
        case 0x0004:
          final r = s.reader;
          final left = <String>[];
          while (r.remaining > 0) {
            final u = UserInfo.read(r);
            members.remove(normalizeSn(u.screenName));
            left.add(u.screenName);
          }
          _onEvent(RoomMembersChanged(const [], left));
        case 0x0006:
          final m = parseRoomMessage(s.data);
          if (m != null) _onEvent(RoomMessageReceived(m));
      }
    } catch (_) {
      // One bad packet shouldn't take the room down.
    }
  }

  /// Says [text] to the room (plain text; AIM HTML is added here).
  void send(String text) {
    if (_c.isClosed) throw ConnectionClosed('not in the room');
    _c.sendSnac(0x000e, 0x0005, encodeRoomMessage(textToAimHtml(text)));
  }

  Future<void> leave() => _c.close();

  void debugKill() => _c.debugKill();
}
