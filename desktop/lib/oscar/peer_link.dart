import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// A two-way byte pipe straight to the buddy's device: a TCP connection, or
/// a hole-punched connection (see [HolePuncher]).
abstract class PeerLink {
  /// Bytes from the buddy, in order. Ends when the link closes.
  Stream<Uint8List> get input;

  /// Queues bytes to send, in order.
  void add(List<int> data);

  /// Waits until everything queued has been handed over.
  Future<void> flush();

  /// Sends a whole stream, waiting when the other side can't keep up.
  Future<void> addStream(Stream<List<int>> data);

  /// Closes nicely once everything queued is sent.
  Future<void> close();

  /// Drops the link at once.
  void destroy();

  /// "TCP" or "punched", for troubleshooting.
  String get kind;
}

class SocketLink implements PeerLink {
  final Socket socket;
  SocketLink(this.socket) {
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
  }

  @override
  Stream<Uint8List> get input => socket;
  @override
  void add(List<int> data) => socket.add(data);
  @override
  Future<void> flush() => socket.flush();
  @override
  Future<void> addStream(Stream<List<int>> data) => socket.addStream(data);
  @override
  Future<void> close() async {
    try {
      await socket.close();
    } catch (_) {}
    socket.destroy();
  }

  @override
  void destroy() => socket.destroy();
  @override
  String get kind => 'TCP';
}

/// Hole punching: both devices dial each other at the same moment, so each
/// firewall sees an outgoing call and lets the reply in. Used when neither
/// device can reach the other directly (phones on mobile data, most homes).
///
/// The two sides swap a short text "description" through the AIM server
/// (the offer, then the answer). The files themselves still go device to
/// device; nothing relays them.
abstract class HolePuncher {
  /// Starts as the side that dials. Returns the offer to send to the buddy.
  Future<PunchCall> call();

  /// Answers the buddy's offer. Returns the answer to send back.
  Future<PunchAnswer> answer(String offer);
}

class PunchCall {
  final String offer;

  /// Give it the buddy's answer; completes with the link, or null if no path
  /// was found.
  final Future<PeerLink?> Function(String answer) connect;
  final void Function() cancel;
  PunchCall(this.offer, this.connect, this.cancel);
}

class PunchAnswer {
  final String answer;

  /// Completes with the link, or null if no path was found.
  final Future<PeerLink?> link;
  final void Function() cancel;
  PunchAnswer(this.answer, this.link, this.cancel);
}
