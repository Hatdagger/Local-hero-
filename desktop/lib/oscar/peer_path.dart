import 'dart:async';
import 'dart:io';

import 'upnp.dart';

/// Finding a straight path between two devices, for file transfers.
///
/// Every way tried is device to device; nothing goes through the server:
/// - the same Wi-Fi / home network (fastest);
/// - IPv6, which most phone networks and many homes have with no router
///   blocking the way;
/// - the router's public address, opened with UPnP when the router allows;
/// - the public address the AIM Server app sees.
class PeerPath {
  final bool useUpnp;
  final Future<String?> Function()? publicIp;
  final String? Function()? sessionLocalIp;

  /// The device's own addresses as the system reports them (Android, where
  /// Dart's interface listing doesn't work). Optional.
  final Future<List<String>> Function()? deviceAddresses;

  PeerPath({this.useUpnp = true, this.publicIp, this.sessionLocalIp, this.deviceAddresses});

  /// Listens on IPv4, and on IPv6 with the same port where the device has it.
  /// Two plain sockets rather than one "dual-stack" one, which some phones
  /// don't handle.
  static Future<List<ServerSocket>> listen() async {
    final v4 = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final out = [v4];
    try {
      out.add(await ServerSocket.bind(InternetAddress.anyIPv6, v4.port, v6Only: true));
    } catch (_) {}
    return out;
  }

  static bool isPrivate(String ip) {
    final p = ip.split('.').map(int.tryParse).toList();
    if (p.length != 4 || p.any((x) => x == null)) return false;
    final a = p[0]!, b = p[1]!;
    return a == 10 || (a == 172 && b >= 16 && b < 32) || (a == 192 && b == 168) || (a == 100 && b >= 64 && b < 128);
  }

  /// A public ("global") IPv6 address: not link-local, not private, not loopback.
  static bool isGlobal6(InternetAddress a) {
    if (a.type != InternetAddressType.IPv6 || a.isLoopback || a.isLinkLocal) return false;
    final first = a.rawAddress[0];
    // 2000::/3 is the public range; fc00::/7 is private.
    return (first & 0xe0) == 0x20;
  }

  /// Addresses from [deviceAddresses] plus Dart's own listing: (IPv4 home
  /// network addresses, public IPv6 addresses).
  Future<(List<String>, List<String>)> _deviceAddrs() async {
    final v4 = <String>[], v6 = <String>[];
    final fromSystem = <String>[];
    try {
      fromSystem.addAll(await (deviceAddresses?.call() ?? Future.value(const <String>[])));
    } catch (_) {}
    try {
      final ifs = await NetworkInterface.list(includeLinkLocal: false);
      for (final i in ifs) {
        fromSystem.addAll(i.addresses.map((a) => a.address));
      }
    } catch (_) {}
    for (final s in fromSystem) {
      final a = InternetAddress.tryParse(s);
      if (a == null || a.isLoopback) continue;
      if (a.type == InternetAddressType.IPv4) {
        if (isPrivate(s) && !v4.contains(s)) v4.add(s);
      } else if (isGlobal6(a) && !v6.contains(a.address)) {
        v6.add(a.address);
      }
    }
    int rank(String ip) => ip.startsWith('192.168.') ? 0 : (ip.startsWith('10.') ? 1 : (ip.startsWith('172.') ? 2 : 3));
    // Keep the system's order (Wi-Fi first) within each rank.
    final ordered = [for (var r = 0; r < 4; r++) ...v4.where((ip) => rank(ip) == r)];
    return (ordered, v6.take(4).toList());
  }

  Future<String> lanIp() async {
    final s = sessionLocalIp?.call();
    if (s != null) {
      final a = InternetAddress.tryParse(s);
      if (a != null && a.type == InternetAddressType.IPv4 && !a.isLoopback && s != '0.0.0.0') return s;
    }
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
      final all = [for (final i in ifs) ...i.addresses.where((a) => !a.isLoopback).map((a) => a.address)];
      int rank(String ip) => ip.startsWith('192.168.') ? 0 : (ip.startsWith('10.') ? 1 : (isPrivate(ip) ? 2 : 3));
      all.sort((a, b) => rank(a).compareTo(rank(b)));
      if (all.isNotEmpty) return all.first;
    } catch (_) {}
    return '127.0.0.1';
  }

  static Future<List<String>> ipv6() async {
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv6);
      final out = <String>[];
      for (final i in ifs) {
        for (final a in i.addresses) {
          if (isGlobal6(a) && !out.contains(a.address)) out.add(a.address);
        }
      }
      // A phone can have many temporary addresses; a few is plenty.
      return out.take(4).toList();
    } catch (_) {
      return const [];
    }
  }

  String? _publicCache;
  DateTime? _publicAt;

  /// Our addresses: (home-network IPv4, extra public IPv4s, IPv6s, UPnP lease).
  /// Close the lease with [PortLease.close] once connected or given up.
  Future<(String, List<String>, List<String>, PortLease?)> addresses(int port) async {
    final (homeV4, sys6) = await _deviceAddrs();
    final lan = homeV4.isNotEmpty ? homeV4.first : await lanIp();
    final extra = <String>[...homeV4.skip(1)];
    PortLease? lease;

    Future<void> upnp() async {
      if (!useUpnp || !isPrivate(lan)) return;
      final u = await Upnp.find(lan);
      if (u == null) return;
      if (await u.open(port)) {
        lease = PortLease(u, port);
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
    return (lan, extra.toSet().where((e) => e != lan).toList(), sys6, lease);
  }

  /// Tries each address (IPv4 or IPv6) a little apart and keeps the first that
  /// answers. Order [addrs] best first.
  static Future<Socket?> connectAny(List<String> addrs, int port) async {
    if (addrs.isEmpty || port <= 0) return null;
    final result = Completer<Socket?>();
    var left = addrs.length;
    for (var i = 0; i < addrs.length; i++) {
      final a = addrs[i];
      unawaited(() async {
        try {
          await Future<void>.delayed(Duration(milliseconds: 400 * i));
          if (result.isCompleted) return;
          final local = isPrivate(a) || a.startsWith('127.') || a == '::1';
          final s = await Socket.connect(a, port, timeout: Duration(seconds: local ? 4 : 8));
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

  /// Best order to try a buddy's addresses: their home network first (only
  /// works on the same Wi-Fi, but then it's the fastest), then IPv6, then
  /// their public IPv4 addresses, loopback last.
  static List<String> order(List<String> v4, List<String> v6) {
    final lan = v4.where(isPrivate).toList();
    final pub = v4.where((a) => !isPrivate(a) && !a.startsWith('127.')).toList();
    final loop = v4.where((a) => a.startsWith('127.')).toList();
    return [...lan, ...v6, ...pub, ...loop];
  }
}

/// A port the router opened for us with UPnP.
class PortLease {
  final Upnp upnp;
  final int port;
  PortLease(this.upnp, this.port);
  Future<void> close() => upnp.close(port);
}
