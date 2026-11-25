import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../oscar/peer_link.dart';

/// Hole punching with WebRTC: both devices learn their outside addresses from
/// public STUN servers ("what address do you see me at?"), swap them through
/// the AIM server, then dial each other at once over UDP. The files go
/// straight between the devices on an encrypted channel.
///
/// There's deliberately no TURN server: nothing ever relays the files. If no
/// direct path exists, it just doesn't connect.
class WebRtcPuncher implements HolePuncher {
  static const _config = <String, dynamic>{
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun.cloudflare.com:3478'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  /// How long to wait for the device's addresses before sending the offer.
  static const _gatherWait = Duration(seconds: 6);

  /// How long to try dialing once both sides know each other's addresses.
  static const _connectWait = Duration(seconds: 25);

  Future<(RTCPeerConnection, RTCDataChannel)> _open() async {
    final pc = await createPeerConnection(_config);
    // Both sides make the same channel up front ("negotiated"), so neither
    // has to wait for the other to announce it.
    final dc = await pc.createDataChannel(
        'files',
        RTCDataChannelInit()
          ..negotiated = true
          ..id = 0
          ..ordered = true
          ..binaryType = 'binary');
    return (pc, dc);
  }

  /// Waits until the device has found its addresses (or a few seconds), so
  /// the description we send already lists them all.
  static Future<String> _gathered(RTCPeerConnection pc) async {
    final done = Completer<void>();
    pc.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete && !done.isCompleted) done.complete();
    };
    if (pc.iceGatheringState == RTCIceGatheringState.RTCIceGatheringStateComplete && !done.isCompleted) {
      done.complete();
    }
    await done.future.timeout(_gatherWait, onTimeout: () {});
    final d = await pc.getLocalDescription();
    if (d?.sdp == null) throw StateError('no local description');
    return d!.sdp!;
  }

  static Future<PeerLink?> _whenOpen(RTCPeerConnection pc, RTCDataChannel dc) async {
    final link = _DataChannelLink(pc, dc);
    if (dc.state == RTCDataChannelState.RTCDataChannelOpen) return link;
    final open = Completer<bool>();
    final sub = dc.stateChangeStream.listen((s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen && !open.isCompleted) open.complete(true);
      if (s == RTCDataChannelState.RTCDataChannelClosed && !open.isCompleted) open.complete(false);
    });
    link.ended.future.then((_) {
      if (!open.isCompleted) open.complete(false);
    });
    final ok = await open.future.timeout(_connectWait, onTimeout: () => false);
    await sub.cancel();
    if (!ok) {
      link.destroy();
      return null;
    }
    return link;
  }

  static void _close(RTCPeerConnection pc, RTCDataChannel dc) {
    dc.close().catchError((_) {});
    pc.close().catchError((_) {});
  }

  @override
  Future<PunchCall> call() async {
    final (pc, dc) = await _open();
    try {
      await pc.setLocalDescription(await pc.createOffer({}));
      final offer = await _gathered(pc);
      return PunchCall(offer, (answer) async {
        await pc.setRemoteDescription(RTCSessionDescription(answer, 'answer'));
        return _whenOpen(pc, dc);
      }, () => _close(pc, dc));
    } catch (_) {
      _close(pc, dc);
      rethrow;
    }
  }

  @override
  Future<PunchAnswer> answer(String offer) async {
    final (pc, dc) = await _open();
    try {
      await pc.setRemoteDescription(RTCSessionDescription(offer, 'offer'));
      await pc.setLocalDescription(await pc.createAnswer({}));
      final answer = await _gathered(pc);
      return PunchAnswer(answer, _whenOpen(pc, dc), () => _close(pc, dc));
    } catch (_) {
      _close(pc, dc);
      rethrow;
    }
  }
}

/// A WebRTC data channel as a byte pipe.
class _DataChannelLink implements PeerLink {
  final RTCPeerConnection pc;
  final RTCDataChannel dc;
  final _in = StreamController<Uint8List>();
  StreamSubscription<RTCDataChannelMessage>? _msgs;
  StreamSubscription<RTCDataChannelState>? _states;
  Future<void> _queue = Future.value();
  Object? _error;
  bool _closed = false;

  /// Completes when the connection ends (or fails to start).
  final ended = Completer<void>();

  /// Messages are cut to this size (well under every implementation's limit).
  static const _piece = 64 * 1024;

  /// Stop sending while this much is waiting to go out; carry on below [_low].
  static const _high = 8 * 1024 * 1024;
  static const _low = 2 * 1024 * 1024;

  _DataChannelLink(this.pc, this.dc) {
    // Listen right away: messages can arrive as soon as the channel opens.
    _msgs = dc.messageStream.listen((m) {
      if (m.isBinary && !_in.isClosed) _in.add(m.binary);
    });
    _states = dc.stateChangeStream.listen((s) {
      if (s == RTCDataChannelState.RTCDataChannelClosed) _finish();
    });
    pc.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _finish();
      }
    };
  }

  void _finish() {
    if (!_in.isClosed) _in.close();
    if (!ended.isCompleted) ended.complete();
  }

  @override
  Stream<Uint8List> get input => _in.stream;

  @override
  String get kind => 'punched';

  Future<void> _sendNow(List<int> data) async {
    if (_closed) throw StateError('closed');
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    for (var off = 0; off < bytes.length; off += _piece) {
      final end = off + _piece < bytes.length ? off + _piece : bytes.length;
      await dc.send(RTCDataChannelMessage.fromBinary(Uint8List.sublistView(bytes, off, end)));
    }
  }

  Future<void> _waitForRoom() async {
    var buffered = await dc.getBufferedAmount();
    while (buffered > _high && !_closed) {
      await Future<void>.delayed(const Duration(milliseconds: 15));
      buffered = await dc.getBufferedAmount();
      if (buffered <= _low) break;
    }
  }

  @override
  void add(List<int> data) {
    _queue = _queue.then((_) => _sendNow(data)).catchError((Object e) {
      _error ??= e;
    });
  }

  @override
  Future<void> flush() async {
    await _queue;
    final e = _error;
    if (e != null) throw e;
  }

  @override
  Future<void> addStream(Stream<List<int>> data) async {
    await flush();
    var sinceCheck = 0;
    await for (final c in data) {
      await _sendNow(c);
      sinceCheck += c.length;
      if (sinceCheck >= 1024 * 1024) {
        sinceCheck = 0;
        await _waitForRoom();
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    try {
      await flush();
      // Let what's queued reach the other side before hanging up.
      final until = DateTime.now().add(const Duration(seconds: 10));
      while (await dc.getBufferedAmount() > 0 && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    } catch (_) {}
    destroy();
  }

  @override
  void destroy() {
    if (_closed) return;
    _closed = true;
    _msgs?.cancel();
    _states?.cancel();
    dc.close().catchError((_) {});
    pc.close().catchError((_) {});
    _finish();
  }
}
