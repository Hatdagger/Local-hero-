import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import 'platform_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An invite to a server, as carried by a share link.
///
/// Link forms understood:
///   http(s)://host[:port]/i/CODE[#fp=SHA256HEX&by=Inviter]
///   aim://invite?server=host:port&code=CODE&fp=SHA256HEX&by=Inviter
class Invite {
  final String server; // host:port of the AIM server
  final String code;
  final String? fingerprint; // SHA-256 of the server's TLS certificate (hex)
  final String? invitedBy;
  const Invite(this.server, this.code, {this.fingerprint, this.invitedBy});

  static Invite? parse(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    final m = RegExp(r'(aim://\S+|https?://\S+/i/[A-Za-z0-9-]+\S*)').firstMatch(s);
    if (m == null) return null;
    final uri = Uri.tryParse(m.group(1)!);
    if (uri == null) return null;
    if (uri.scheme == 'aim') {
      final server = uri.queryParameters['server'];
      final code = uri.queryParameters['code'];
      if (server == null || code == null) return null;
      return Invite(server, code, fingerprint: uri.queryParameters['fp'], invitedBy: uri.queryParameters['by']);
    }
    final segs = uri.pathSegments;
    final i = segs.indexOf('i');
    if (i < 0 || i + 1 >= segs.length) return null;
    final frag = Uri.splitQueryString(uri.fragment);
    final port = uri.hasPort ? uri.port : 5190;
    return Invite('${uri.host}:$port', segs[i + 1], fingerprint: frag['fp'], invitedBy: frag['by']);
  }

  Map<String, dynamic> toJson() => {'server': server, 'code': code, 'fp': fingerprint, 'by': invitedBy};
  static Invite? fromJson(Map<String, dynamic> j) => j['server'] is String && j['code'] is String
      ? Invite(j['server'] as String, j['code'] as String, fingerprint: j['fp'] as String?, invitedBy: j['by'] as String?)
      : null;
}

/// Finds invites from: links that opened the app (Android), an invite.json
/// shipped next to the program (Windows/Linux downloads), or the clipboard.
class InviteInbox {
  static const _ch = MethodChannel('aim/platform');
  final _incoming = StreamController<Invite>.broadcast();
  Stream<Invite> get incoming => _incoming.stream;

  InviteInbox() {
    if (Platform.isAndroid) {
      _ch.setMethodCallHandler((call) async {
        if (call.method == 'link') {
          final inv = Invite.parse(call.arguments as String?);
          if (inv != null) _incoming.add(inv);
        } else if (call.method == 'installFailed') {
          PlatformBridge.onInstallFailed?.call(call.arguments?.toString() ?? '');
        } else if (call.method == 'resumed') {
          PlatformBridge.onResumed?.call();
        }
        return null;
      });
    }
  }

  Future<Invite?> initial() async {
    if (Platform.isAndroid) {
      try {
        final inv = Invite.parse(await _ch.invokeMethod<String>('getInitialLink'));
        if (inv != null) return inv;
      } catch (_) {}
    } else {
      try {
        final dir = File(Platform.resolvedExecutable).parent;
        final f = File('${dir.path}${Platform.pathSeparator}invite.json');
        if (await f.exists()) {
          final prefs = await SharedPreferences.getInstance();
          final raw = await f.readAsString();
          if (prefs.getString('usedInviteFile') != raw) {
            final inv = Invite.fromJson(jsonDecode(raw) as Map<String, dynamic>);
            if (inv != null) {
              await prefs.setString('usedInviteFile', raw);
              return inv;
            }
          }
        }
      } catch (_) {}
    }
    return null;
  }

  /// Offered once per distinct link so we don't nag.
  Future<Invite?> fromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final inv = Invite.parse(data?.text);
      if (inv == null) return null;
      final prefs = await SharedPreferences.getInstance();
      final key = '${inv.server}/${inv.code}';
      if (prefs.getString('lastClipboardInvite') == key) return null;
      await prefs.setString('lastClipboardInvite', key);
      return inv;
    } catch (_) {
      return null;
    }
  }
}

/// Random per-install id sent with sign-ups so the server can spot abuse.
Future<String> deviceId() async {
  final prefs = await SharedPreferences.getInstance();
  var id = prefs.getString('deviceId');
  if (id == null) {
    final r = Random.secure();
    id = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    await prefs.setString('deviceId', id);
  }
  return id;
}
