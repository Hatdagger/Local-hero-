import 'dart:typed_data';

import 'bytes.dart';

/// Presence info for a user, parsed from an OSCAR "user info" block.
class UserInfo {
  final String screenName;
  final int warningLevel;
  final int userClass;
  final int? onlineSince;
  final int idleMinutes;
  final Uint8List? iconHash;
  final int iconFlags;
  final bool online;

  const UserInfo({
    required this.screenName,
    this.warningLevel = 0,
    this.userClass = 0,
    this.onlineSince,
    this.idleMinutes = 0,
    this.iconHash,
    this.iconFlags = 0,
    this.online = true,
  });

  bool get isAway => (userClass & 0x0020) != 0;

  static UserInfo read(ByteReader r) {
    final sn = r.str8();
    final warn = r.u16();
    final count = r.u16();
    final tlvs = r.tlvs(count);
    var cls = tlvs[0x01]?.asU16 ?? 0;
    final status = tlvs[0x06]?.asU32;
    if (status != null && (status & 0x0001) != 0) cls |= 0x0020;
    Uint8List? hash;
    var flags = 0;
    final bart = tlvs[0x1d];
    if (bart != null) {
      final br = bart.reader;
      try {
        while (br.remaining >= 4) {
          final type = br.u16();
          final f = br.u8();
          final len = br.u8();
          final data = br.bytes(len);
          if (type == 0x0001 && len > 0) {
            hash = Uint8List.fromList(data);
            flags = f;
          }
        }
      } catch (_) {}
    }
    return UserInfo(
      screenName: sn,
      warningLevel: warn,
      userClass: cls,
      onlineSince: tlvs[0x03]?.asU32,
      idleMinutes: tlvs[0x04]?.asU16 ?? 0,
      iconHash: hash,
      iconFlags: flags,
    );
  }
}

/// An entry in the server-side buddy list ("feedbag").
class FeedbagItem {
  String name;
  int groupId;
  int itemId;
  int classId;
  List<Tlv> attrs;

  FeedbagItem(this.name, this.groupId, this.itemId, this.classId, this.attrs);

  static const classBuddy = 0x0000;
  static const classGroup = 0x0001;
  static const classPermit = 0x0002;
  static const classDeny = 0x0003;
  static const classPdInfo = 0x0004;
  static const classBart = 0x0014;

  /// The ordered child ids (TLV 0xC8), for groups.
  List<int> get order {
    for (final t in attrs) {
      if (t.type == 0xc8) {
        final r = t.reader;
        final out = <int>[];
        while (r.remaining >= 2) {
          out.add(r.u16());
        }
        return out;
      }
    }
    return const [];
  }

  set order(List<int> ids) {
    final w = ByteWriter();
    for (final id in ids) {
      w.u16(id);
    }
    attrs = [
      ...attrs.where((t) => t.type != 0xc8),
      Tlv(0xc8, w.toBytes()),
    ];
  }

  String? get alias {
    for (final t in attrs) {
      if (t.type == 0x131) return t.asString;
    }
    return null;
  }

  static FeedbagItem read(ByteReader r) {
    final nameLen = r.u16();
    final name = String.fromCharCodes(r.bytes(nameLen));
    final gid = r.u16();
    final iid = r.u16();
    final cls = r.u16();
    final tlvLen = r.u16();
    final tlvs = ByteReader(r.bytes(tlvLen)).tlvs();
    return FeedbagItem(name, gid, iid, cls, List.of(tlvs.items));
  }

  void write(ByteWriter w) {
    w.str16(name);
    w.u16(groupId);
    w.u16(itemId);
    w.u16(classId);
    final tw = ByteWriter();
    for (final t in attrs) {
      tw.tlv(t.type, t.value);
    }
    final tb = tw.toBytes();
    w.u16(tb.length);
    w.bytes(tb);
  }
}

class BuddyGroup {
  final String name;
  final int groupId;
  final List<String> buddies;
  BuddyGroup(this.name, this.groupId, this.buddies);
}

class IncomingMessage {
  final String from;
  final String html;
  final String text;
  final bool autoResponse;
  final DateTime time;
  const IncomingMessage(this.from, this.html, this.text, this.autoResponse, this.time);
}

class ProfileInfo {
  final String screenName;
  final String? profileHtml;
  final String? awayHtml;
  final UserInfo? user;
  const ProfileInfo(this.screenName, {this.profileHtml, this.awayHtml, this.user});
}

/// Why a sign-on or session ended.
enum DisconnectKind {
  network, // link dropped: reconnect automatically
  badPassword, // credentials rejected: stop
  signedOnElsewhere, // another client took the session: stop
  rateLimited, // server asked us to slow down: retry later
  serverError, // other server-side error: retry
  userSignOff, // user pressed Sign Off
}

class OscarDisconnect implements Exception {
  final DisconnectKind kind;
  final String message;
  const OscarDisconnect(this.kind, this.message);
  @override
  String toString() => message;
}
