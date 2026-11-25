import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'session.dart';

/// Client for the AIM Server app's account API (see docs/SERVER_SPEC.md).
/// Spoken over TLS on the same port as AIM. The server's certificate is
/// self-signed, so it's pinned: by the fingerprint in the invite link, or on
/// first use.
class SignupApi {
  final ServerConfig server;
  final String? pinnedFingerprint;

  SignupApi(this.server, {this.pinnedFingerprint});

  /// Fingerprint of the certificate seen on the last call. When nothing was
  /// pinned, the caller saves this (trust on first use).
  String? lastFingerprint;

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    client.badCertificateCallback = (cert, host, port) {
      final seen = sha256.convert(cert.der).toString();
      lastFingerprint = seen;
      final pin = pinnedFingerprint?.toLowerCase().replaceAll(':', '');
      if (pin != null && pin.isNotEmpty) return seen == pin;
      return true;
    };
    try {
      final uri = Uri(scheme: 'https', host: server.host, port: server.port, path: path);
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final resp = await req.close();
      final text = await resp.transform(utf8.decoder).join();
      Map<String, dynamic> json;
      try {
        json = jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {
        json = {'error': text.isEmpty ? 'HTTP ${resp.statusCode}' : text};
      }
      if (resp.statusCode >= 400) {
        throw SignupError(json['error']?.toString() ?? 'HTTP ${resp.statusCode}', code: json['code']?.toString());
      }
      return json;
    } on HandshakeException {
      throw const SignupError('This server\'s security certificate doesn\'t match the invite.');
    } on SocketException {
      throw const SignupError('Can\'t reach the server.');
    } finally {
      client.close(force: true);
    }
  }

  /// Creates an account with an invite code.
  Future<void> signUp({
    required String inviteCode,
    required String screenName,
    required String password,
    required String deviceId,
  }) async {
    await _post('/api/v1/signup', {
      'invite_code': inviteCode,
      'screen_name': screenName,
      'password': password,
      'device_id': deviceId,
    });
  }

  /// Asks the server for a share link inviting someone new.
  Future<CreatedInvite> createInvite({
    required String screenName,
    required String password,
    required String deviceId,
    bool household = false,
  }) async {
    final j = await _post('/api/v1/invites', {
      'screen_name': screenName,
      'password': password,
      'device_id': deviceId,
      'kind': household ? 'household' : 'single',
    });
    return CreatedInvite(
      j['code'] as String,
      j['link'] as String,
      (j['uses_left'] as num?)?.toInt() ?? 1,
      DateTime.tryParse(j['expires_at']?.toString() ?? ''),
    );
  }

  /// This device's public address as the AIM Server app sees it (used so a
  /// buddy elsewhere can Direct Connect). null on servers without the app.
  Future<String?> myIp() async {
    try {
      final j = await _post('/api/v1/myip', const {}).timeout(const Duration(seconds: 4));
      final ip = j['ip']?.toString();
      final a = ip == null ? null : InternetAddress.tryParse(ip);
      return a != null && a.type == InternetAddressType.IPv4 && !a.isLoopback ? ip : null;
    } catch (_) {
      return null;
    }
  }
}

class CreatedInvite {
  final String code;
  final String link;
  final int usesLeft;
  final DateTime? expires;
  const CreatedInvite(this.code, this.link, this.usesLeft, this.expires);
}

class SignupError implements Exception {
  final String message;
  final String? code;
  const SignupError(this.message, {this.code});
  @override
  String toString() => message;
}
