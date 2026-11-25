import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Asks the home router (UPnP Internet Gateway Device) to open a TCP port to
/// this device for a little while, so a buddy elsewhere can connect for
/// Direct Connect. Same steps as the AIM Server app's `server/upnp.go`.
class Upnp {
  final Uri control;
  final String serviceType;
  final String localIp;
  Upnp._(this.control, this.serviceType, this.localIp);

  static Upnp? _cached;
  static DateTime? _failedAt;

  /// Finds the router (cached; a failure is remembered for 10 minutes).
  static Future<Upnp?> find(String localIp) async {
    final c = _cached;
    if (c != null && c.localIp == localIp) return c;
    final f = _failedAt;
    if (f != null && DateTime.now().difference(f) < const Duration(minutes: 10)) return null;
    try {
      final u = await _discover(localIp).timeout(const Duration(seconds: 6));
      _cached = u;
      if (u == null) _failedAt = DateTime.now();
      return u;
    } catch (_) {
      _failedAt = DateTime.now();
      return null;
    }
  }

  static Future<Upnp?> _discover(String localIp) async {
    RawDatagramSocket sock;
    try {
      sock = await RawDatagramSocket.bind(InternetAddress(localIp), 0);
    } catch (_) {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    }
    final locations = <String>[];
    final dst = InternetAddress('239.255.255.250');
    const targets = [
      'urn:schemas-upnp-org:device:InternetGatewayDevice:1',
      'urn:schemas-upnp-org:device:InternetGatewayDevice:2',
      'urn:schemas-upnp-org:service:WANIPConnection:1',
      'urn:schemas-upnp-org:service:WANIPConnection:2',
      'urn:schemas-upnp-org:service:WANPPPConnection:1',
    ];
    void send() {
      for (final st in targets) {
        final msg = 'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nST: $st\r\n'
            'MAN: "ssdp:discover"\r\nMX: 2\r\n\r\n';
        try {
          sock.send(ascii.encode(msg), dst, 1900);
        } catch (_) {}
      }
    }

    final got = Completer<void>();
    var waiting = false;
    final sub = sock.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      final d = sock.receive();
      if (d == null) return;
      for (final line in latin1.decode(d.data).split('\r\n')) {
        final i = line.indexOf(':');
        if (i > 0 && line.substring(0, i).trim().toLowerCase() == 'location') {
          final loc = line.substring(i + 1).trim();
          if (!locations.contains(loc)) locations.add(loc);
          // Give other answers a moment, then stop listening.
          if (!waiting) {
            waiting = true;
            Timer(const Duration(milliseconds: 400), () {
              if (!got.isCompleted) got.complete();
            });
          }
        }
      }
    });
    send();
    final resend = Timer(const Duration(milliseconds: 1200), send);
    await Future.any([got.future, Future<void>.delayed(const Duration(milliseconds: 3000))]);
    resend.cancel();
    await sub.cancel();
    sock.close();
    for (final loc in locations) {
      try {
        final u = await _service(Uri.parse(loc), localIp);
        if (u != null) return u;
      } catch (_) {}
    }
    return null;
  }

  static Future<String> _get(Uri u) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await c.getUrl(u);
      final resp = await req.close().timeout(const Duration(seconds: 5));
      return await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 5));
    } finally {
      c.close(force: true);
    }
  }

  static Future<Upnp?> _service(Uri loc, String localIp) async {
    final xml = await _get(loc);
    var base = loc;
    final ub = RegExp(r'<URLBase>\s*([^<]+?)\s*</URLBase>', caseSensitive: false).firstMatch(xml);
    if (ub != null) base = Uri.tryParse(ub.group(1)!) ?? loc;
    String? type, control;
    for (final m in RegExp(r'<service>(.*?)</service>', dotAll: true, caseSensitive: false).allMatches(xml)) {
      final s = m.group(1)!;
      final st = RegExp(r'<serviceType>\s*([^<]+?)\s*</serviceType>', caseSensitive: false).firstMatch(s)?.group(1);
      final cu = RegExp(r'<controlURL>\s*([^<]+?)\s*</controlURL>', caseSensitive: false).firstMatch(s)?.group(1);
      if (st == null || cu == null) continue;
      final ip = st.contains('WANIPConnection');
      if (ip || (type == null && st.contains('WANPPPConnection'))) {
        if (type == null || ip) {
          type = st;
          control = cu;
        }
      }
    }
    if (type == null || control == null) return null;
    return Upnp._(base.resolve(control), type, localIp);
  }

  Future<String> _call(String action, List<(String, String)> args) async {
    final b = StringBuffer('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>')
      ..write('<u:$action xmlns:u="$serviceType">');
    for (final (k, v) in args) {
      b.write('<$k>${const HtmlEscape(HtmlEscapeMode.element).convert(v)}</$k>');
    }
    b.write('</u:$action></s:Body></s:Envelope>');
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await c.postUrl(control);
      req.headers.set('Content-Type', 'text/xml; charset="utf-8"');
      req.headers.set('SOAPAction', '"$serviceType#$action"');
      req.write(b.toString());
      final resp = await req.close().timeout(const Duration(seconds: 5));
      final body = await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) {
        final code = RegExp(r'<(?:\w+:)?errorCode>\s*(\d+)\s*</').firstMatch(body)?.group(1);
        throw UpnpError(int.tryParse(code ?? '') ?? resp.statusCode);
      }
      return body;
    } finally {
      c.close(force: true);
    }
  }

  /// The router's address on the internet side, if it says.
  Future<String?> externalIp() async {
    try {
      final body = await _call('GetExternalIPAddress', const []);
      return RegExp(r'<NewExternalIPAddress>\s*([0-9.]+)\s*<').firstMatch(body)?.group(1);
    } catch (_) {
      return null;
    }
  }

  /// Forwards TCP [port] on the router to this device. Returns false if the
  /// router said no.
  Future<bool> open(int port, {Duration lease = const Duration(minutes: 10)}) async {
    List<(String, String)> args(int l) => [
          ('NewRemoteHost', ''),
          ('NewExternalPort', '$port'),
          ('NewProtocol', 'TCP'),
          ('NewInternalPort', '$port'),
          ('NewInternalClient', localIp),
          ('NewEnabled', '1'),
          ('NewPortMappingDescription', 'AIM Direct Connect'),
          ('NewLeaseDuration', '$l'),
        ];
    try {
      await _call('AddPortMapping', args(lease.inSeconds));
      return true;
    } on UpnpError catch (e) {
      if (e.code != 725) return false;
      try {
        await _call('AddPortMapping', args(0));
        return true;
      } catch (_) {
        return false;
      }
    } catch (_) {
      return false;
    }
  }

  Future<void> close(int port) async {
    try {
      await _call('DeletePortMapping', [('NewRemoteHost', ''), ('NewExternalPort', '$port'), ('NewProtocol', 'TCP')]);
    } catch (_) {}
  }
}

class UpnpError implements Exception {
  final int code;
  UpnpError(this.code);
  @override
  String toString() => 'router error $code';
}
