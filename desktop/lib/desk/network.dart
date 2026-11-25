import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'window_manager.dart';
import 'xp_theme.dart';

// ======================================================================
// State (see DeskNet.kt)

class WifiNetwork {
  final String ssid;
  final int bars; // 0..4
  final String security; // open, wpa2, wpa3, wep, owe, enterprise
  final String band;
  final bool current;
  const WifiNetwork(this.ssid, this.bars, this.security, this.band, this.current);

  bool get secure => security != 'open' && security != 'owe';

  String get securityLabel => switch (security) {
        'open' => 'Unsecured wireless network',
        'owe' => 'Enhanced open network',
        'wep' => 'Security-enabled wireless network (WEP)',
        'wpa3' => 'Security-enabled wireless network (WPA3)',
        'enterprise' => 'Security-enabled wireless network (802.1X)',
        _ => 'Security-enabled wireless network (WPA2)',
      };
}

class BtDevice {
  final String name;
  final String address;
  final String kind;
  final bool paired;
  final bool pairing;
  final bool connected;
  const BtDevice(this.name, this.address, this.kind, this.paired, this.pairing, this.connected);

  IconData get icon => switch (kind) {
        'audio' => Icons.headphones,
        'phone' => Icons.smartphone,
        'computer' => Icons.computer,
        'keyboard' => Icons.keyboard,
        'mouse' => Icons.mouse,
        'gamepad' => Icons.sports_esports,
        'watch' => Icons.watch,
        _ => Icons.bluetooth,
      };

  String get status => connected
      ? 'Connected'
      : pairing
          ? 'Pairing...'
          : paired
              ? 'Paired'
              : 'Not paired';
}

/// Wi-Fi and Bluetooth state, refreshed whenever Android says something
/// changed.
class NetState extends ChangeNotifier {
  NetState._() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'changed') unawaited(refresh());
      return null;
    });
    unawaited(refresh());
  }
  static final instance = NetState._();

  static const _ch = MethodChannel('desk/net');

  // Wi-Fi
  bool wifiAvailable = false;
  bool wifiOn = false;
  bool wifiConnected = false;
  String ssid = '';
  int bars = 0;
  int mbps = 0;
  bool locationAllowed = false;
  bool locationOn = true;
  List<WifiNetwork> networks = const [];

  // Bluetooth
  bool btAvailable = false;
  bool btOn = false;
  bool btAllowed = false;
  bool btSearching = false;
  String btName = '';
  List<BtDevice> devices = const [];

  Future<void> refresh() async {
    try {
      final w = Map<String, dynamic>.from(await _ch.invokeMethod<Map>('wifiStatus') ?? const {});
      wifiAvailable = w['available'] as bool? ?? false;
      wifiOn = w['enabled'] as bool? ?? false;
      wifiConnected = w['connected'] as bool? ?? false;
      ssid = w['ssid'] as String? ?? '';
      bars = w['bars'] as int? ?? 0;
      mbps = w['mbps'] as int? ?? 0;
      locationAllowed = w['permission'] as bool? ?? false;
      locationOn = w['locationOn'] as bool? ?? true;
      networks = [
        for (final e in (w['networks'] as List? ?? const []))
          () {
            final m = Map<String, dynamic>.from(e as Map);
            return WifiNetwork(m['ssid'] as String? ?? '', m['bars'] as int? ?? 0, m['security'] as String? ?? 'open',
                m['band'] as String? ?? '', m['current'] as bool? ?? false);
          }(),
      ];
    } catch (_) {}
    try {
      final b = Map<String, dynamic>.from(await _ch.invokeMethod<Map>('btStatus') ?? const {});
      btAvailable = b['available'] as bool? ?? false;
      btOn = b['enabled'] as bool? ?? false;
      btAllowed = b['permission'] as bool? ?? false;
      btSearching = b['discovering'] as bool? ?? false;
      btName = b['name'] as String? ?? '';
      devices = [
        for (final e in (b['devices'] as List? ?? const []))
          () {
            final m = Map<String, dynamic>.from(e as Map);
            return BtDevice(m['name'] as String? ?? '', m['address'] as String? ?? '', m['kind'] as String? ?? 'other',
                m['paired'] as bool? ?? false, m['pairing'] as bool? ?? false, m['connected'] as bool? ?? false);
          }(),
      ];
    } catch (_) {}
    notifyListeners();
  }

  Future<T?> _call<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _ch.invokeMethod<T>(method, args);
    } catch (_) {
      return null;
    }
  }

  Future<void> scan() async {
    await _call<bool>('wifiScan');
    await refresh();
  }

  /// True if switched here; false if Android's panel opened instead.
  Future<bool> setWifi(bool on) async => await _call<bool>('wifiSetEnabled', {'on': on}) ?? false;

  /// "added" (Android asks to confirm) or "panel" (Android's Wi-Fi panel opened).
  Future<String> connect(WifiNetwork n, String password) async =>
      await _call<String>('wifiConnect', {'ssid': n.ssid, 'password': password, 'security': n.security}) ?? 'panel';

  Future<void> wifiPanel() => _call('wifiPanel');
  Future<void> askPermissions() => _call('askPermissions');
  Future<void> locationSettings() => _call('locationSettings');

  Future<bool> setBluetooth(bool on) async => await _call<bool>('btSetEnabled', {'on': on}) ?? false;
  Future<void> search(bool on) async {
    await _call<bool>('btDiscover', {'on': on});
    await refresh();
  }

  Future<bool> pair(BtDevice d) async => await _call<bool>('btPair', {'address': d.address}) ?? false;
  Future<bool> unpair(BtDevice d) async => await _call<bool>('btUnpair', {'address': d.address}) ?? false;
  Future<void> btSettings() => _call('btSettings');
}

// ======================================================================
// Shared bits

IconData wifiIcon(int bars, {bool on = true, bool connected = true}) {
  if (!on) return Icons.wifi_off;
  if (!connected) return Icons.signal_wifi_statusbar_null;
  return switch (bars) {
    0 => Icons.signal_wifi_0_bar,
    1 => Icons.network_wifi_1_bar,
    2 => Icons.network_wifi_2_bar,
    3 => Icons.network_wifi_3_bar,
    _ => Icons.signal_wifi_4_bar,
  };
}

/// Five little rising bars, green when strong.
class SignalBars extends StatelessWidget {
  const SignalBars({super.key, required this.bars});
  final int bars;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
      for (var i = 0; i < 5; i++)
        Container(
          width: 4,
          height: 4.0 + i * 3,
          margin: const EdgeInsets.only(left: 1.5),
          decoration: BoxDecoration(
            color: i <= bars ? const Color(0xFF3DAA4E) : const Color(0xFFD4D0C8),
            border: Border.all(color: const Color(0xFF6E6E6E), width: 0.5),
          ),
        ),
    ]);
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.button, required this.onTap});
  final String text;
  final String button;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: const Color(0xFFFFFFE1), border: Border.all(color: const Color(0xFFACA899))),
      child: Row(children: [
        const Icon(Icons.info, size: 20, color: Xp.selection),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: Xp.text)),
        const SizedBox(width: 8),
        XpButton(label: button, onPressed: onTap),
      ]),
    );
  }
}

Widget _taskBox(String title, List<Widget> children) => Container(
      margin: const EdgeInsets.fromLTRB(10, 10, 10, 0),
      decoration: BoxDecoration(
        color: const Color(0xFFD6DFF7),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
        border: Border.all(color: Colors.white),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: const BoxDecoration(
            borderRadius: BorderRadius.vertical(top: Radius.circular(4)),
            gradient: LinearGradient(colors: [Colors.white, Color(0xFFC6D3F7)]),
          ),
          child: Text(title, style: Xp.textBold.copyWith(fontSize: 12, color: const Color(0xFF215DC6))),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      ]),
    );

Widget _taskLink(IconData icon, String label, VoidCallback? onTap) => GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Icon(icon, size: 16, color: onTap == null ? const Color(0xFFB0B0B0) : const Color(0xFF1E3E9B)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(label,
                style: Xp.text.copyWith(
                    fontSize: 12, color: onTap == null ? const Color(0xFFACA899) : const Color(0xFF0C32A4))),
          ),
        ]),
      ),
    );

Widget _taskPane(List<Widget> boxes) => Container(
      width: 190,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF7BA2E7), Color(0xFF6375D6)]),
      ),
      child: ListView(children: boxes),
    );

void _note(WindowManager wm, String title, String text) {
  wm.open(DeskWindow(
    id: 'netnote:${DateTime.now().microsecondsSinceEpoch}',
    title: title,
    icon: Icons.info,
    size: const Size(380, 160),
    resizable: false,
    canMaximize: false,
    canMinimize: false,
    content: (c, w) => Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.info, size: 32, color: Xp.selection),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: Xp.text)),
          ]),
        ),
        Center(child: XpButton(label: 'OK', isDefault: true, onPressed: () => wm.close(w.id))),
      ]),
    ),
  ));
}

// ======================================================================
// Wireless Networks

const kNetworkId = 'network';
const kBluetoothId = 'bluetooth';

DeskWindow networkWindow() => DeskWindow(
      id: kNetworkId,
      title: 'Wireless Network Connection',
      icon: Icons.wifi,
      size: const Size(640, 460),
      minSize: const Size(460, 300),
      content: (c, w) => _WifiWindow(w: w),
    );

class _WifiWindow extends StatefulWidget {
  const _WifiWindow({required this.w});
  final DeskWindow w;

  @override
  State<_WifiWindow> createState() => _WifiWindowState();
}

class _WifiWindowState extends State<_WifiWindow> {
  final net = NetState.instance;
  String? _selected;
  Timer? _rescan;

  @override
  void initState() {
    super.initState();
    unawaited(net.scan());
    _rescan = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(net.scan()));
  }

  @override
  void dispose() {
    _rescan?.cancel();
    super.dispose();
  }

  WindowManager get _wm => context.read<WindowManager>();

  Future<void> _toggle() async {
    final done = await net.setWifi(!net.wifiOn);
    if (!done && mounted) {
      _note(_wm, 'Wireless Network Connection',
          "Android only lets its own Wi-Fi panel switch Wi-Fi on or off. It's open now - flip the switch there.");
    }
  }

  Future<void> _connect(WifiNetwork n) async {
    if (n.current) return;
    if (n.secure && n.security != 'enterprise' && n.security != 'wep') {
      _wm.open(_passwordWindow(n));
      return;
    }
    await _join(_wm, n, '');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: net,
      builder: (c, _) {
        final sel = net.networks.where((n) => n.ssid == _selected).firstOrNull;
        final list = !net.wifiOn
            ? const Center(child: Text('Wi-Fi is turned off.', style: Xp.textGrey))
            : !net.locationAllowed || !net.locationOn
                ? const SizedBox()
                : net.networks.isEmpty
                    ? const Center(child: Text('Looking for wireless networks...', style: Xp.textGrey))
                    : ListView(children: [
                        for (final n in net.networks)
                          GestureDetector(
                            onTap: () => setState(() => _selected = n.ssid),
                            onDoubleTap: () => _connect(n),
                            child: Container(
                              margin: const EdgeInsets.fromLTRB(6, 4, 6, 0),
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: _selected == n.ssid ? const Color(0xFFC1D2EE) : Colors.white,
                                border: Border.all(
                                    color: _selected == n.ssid ? Xp.selection : const Color(0xFFE3E3E3)),
                              ),
                              child: Row(children: [
                                Icon(n.secure ? Icons.wifi_lock : Icons.wifi, size: 30, color: const Color(0xFF1E5BD0)),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(n.ssid, style: Xp.textBold, overflow: TextOverflow.ellipsis),
                                    Text(n.current ? 'Connected' : n.securityLabel,
                                        style: Xp.text.copyWith(
                                            fontSize: 12,
                                            color: n.current ? const Color(0xFF2E7D32) : const Color(0xFF555555))),
                                    Text(n.band, style: Xp.textGrey.copyWith(fontSize: 11)),
                                  ]),
                                ),
                                if (n.current) const Icon(Icons.star, size: 16, color: Color(0xFFE8B84A)),
                                const SizedBox(width: 8),
                                SignalBars(bars: n.bars),
                              ]),
                            ),
                          ),
                      ]);

        return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _taskPane([
            _taskBox('Network Tasks', [
              _taskLink(Icons.refresh, 'Refresh network list', net.wifiOn ? () => net.scan() : null),
              _taskLink(Icons.power_settings_new, net.wifiOn ? 'Turn off Wi-Fi' : 'Turn on Wi-Fi', _toggle),
              _taskLink(Icons.settings, "Open Android's Wi-Fi panel", net.wifiPanel),
            ]),
            _taskBox('Details', [
              Text(
                  net.wifiConnected
                      ? 'Connected to ${net.ssid.isEmpty ? 'a network' : net.ssid}\nSpeed: ${net.mbps} Mbps'
                      : (net.wifiOn ? 'Not connected' : 'Wi-Fi is off'),
                  style: Xp.text.copyWith(fontSize: 12)),
            ]),
          ]),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                color: Colors.white,
                child: const Text('Choose a wireless network',
                    style: TextStyle(fontSize: 18, color: Color(0xFF1E3E9B), fontWeight: FontWeight.bold)),
              ),
              if (net.wifiOn && !net.locationAllowed)
                _Banner(
                    text: 'Android only shows nearby networks to apps that may use Location.',
                    button: 'Allow',
                    onTap: net.askPermissions),
              if (net.wifiOn && net.locationAllowed && !net.locationOn)
                _Banner(
                    text: 'Turn on Location so Android can list nearby networks.',
                    button: 'Turn On',
                    onTap: net.locationSettings),
              Expanded(child: Container(color: Colors.white, child: list)),
              Container(
                padding: const EdgeInsets.all(8),
                child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  XpButton(
                      label: sel?.current == true ? 'Connected' : 'Connect',
                      isDefault: true,
                      onPressed: sel == null || sel.current ? null : () => _connect(sel)),
                ]),
              ),
            ]),
          ),
        ]);
      },
    );
  }
}

Future<void> _join(WindowManager wm, WifiNetwork n, String password) async {
  final r = await NetState.instance.connect(n, password);
  if (r == 'added') {
    _note(wm, 'Wireless Network Connection',
        "Android will ask you to save '${n.ssid}'. Choose Save and the tablet will join it.");
  } else {
    _note(wm, 'Wireless Network Connection',
        "This network has to be joined from Android's Wi-Fi panel, which is open now. Pick '${n.ssid}' there.");
  }
}

DeskWindow _passwordWindow(WifiNetwork n) => DeskWindow(
      id: 'wifipw:${n.ssid}',
      title: 'Wireless Network Connection',
      icon: Icons.wifi_lock,
      size: const Size(420, 250),
      resizable: false,
      canMaximize: false,
      canMinimize: false,
      content: (c, w) => _PasswordBox(w: w, n: n),
    );

class _PasswordBox extends StatefulWidget {
  const _PasswordBox({required this.w, required this.n});
  final DeskWindow w;
  final WifiNetwork n;

  @override
  State<_PasswordBox> createState() => _PasswordBoxState();
}

class _PasswordBoxState extends State<_PasswordBox> {
  final _a = TextEditingController();
  final _b = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  void _go() {
    if (_a.text.length < 8) {
      setState(() => _error = 'The network key must be at least 8 characters.');
      return;
    }
    if (_a.text != _b.text) {
      setState(() => _error = "The two keys don't match. Type them again.");
      return;
    }
    final wm = _findWm(context);
    wm.close(widget.w.id);
    unawaited(_join(wm, widget.n, _a.text));
  }

  @override
  Widget build(BuildContext context) {
    final wm = _findWm(context);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(
            "The network '${widget.n.ssid}' requires a network key (also called a password). "
            'Type the key, and then click Connect.',
            style: Xp.text),
        const SizedBox(height: 10),
        Row(children: [
          const SizedBox(width: 110, child: Text('Network key:', style: Xp.text)),
          Expanded(child: XpField(controller: _a, obscure: true, autofocus: true, onSubmitted: (_) => _go())),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          const SizedBox(width: 110, child: Text('Confirm key:', style: Xp.text)),
          Expanded(child: XpField(controller: _b, obscure: true, onSubmitted: (_) => _go())),
        ]),
        const SizedBox(height: 6),
        if (_error != null) Text(_error!, style: Xp.text.copyWith(color: const Color(0xFFAA0000))),
        const Spacer(),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          XpButton(label: 'Connect', isDefault: true, onPressed: _go),
          const SizedBox(width: 6),
          XpButton(label: 'Cancel', onPressed: () => wm.close(widget.w.id)),
        ]),
      ]),
    );
  }
}

// ======================================================================
// Bluetooth Devices

DeskWindow bluetoothWindow() => DeskWindow(
      id: kBluetoothId,
      title: 'Bluetooth Devices',
      icon: Icons.bluetooth,
      size: const Size(600, 430),
      minSize: const Size(420, 280),
      content: (c, w) => const _BtWindow(),
    );

class _BtWindow extends StatefulWidget {
  const _BtWindow();

  @override
  State<_BtWindow> createState() => _BtWindowState();
}

class _BtWindowState extends State<_BtWindow> {
  final net = NetState.instance;
  String? _selected;

  @override
  void initState() {
    super.initState();
    unawaited(net.refresh());
  }

  @override
  void dispose() {
    if (net.btSearching) unawaited(net.search(false));
    super.dispose();
  }

  Future<void> _toggle() async {
    if (!net.btAllowed) {
      await net.askPermissions();
      return;
    }
    final done = await net.setBluetooth(!net.btOn);
    if (!done && net.btOn && mounted) {
      _note(_findWm(context), 'Bluetooth Devices',
          "Android only lets its own Bluetooth screen switch Bluetooth off. It's open now.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: net,
      builder: (c, _) {
        final sel = net.devices.where((d) => d.address == _selected).firstOrNull;
        final paired = net.devices.where((d) => d.paired).toList();
        final nearby = net.devices.where((d) => !d.paired).toList();

        Widget row(BtDevice d) => GestureDetector(
              onTap: () => setState(() => _selected = d.address),
              onDoubleTap: () => d.paired ? net.btSettings() : net.pair(d),
              child: Container(
                color: _selected == d.address ? Xp.selection : null,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                child: Row(children: [
                  Icon(d.icon, size: 26, color: _selected == d.address ? Colors.white : const Color(0xFF1E5BD0)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(d.name,
                          style: Xp.textBold.copyWith(color: _selected == d.address ? Colors.white : null),
                          overflow: TextOverflow.ellipsis),
                      Text(d.status,
                          style: Xp.text.copyWith(
                              fontSize: 12,
                              color: _selected == d.address
                                  ? Colors.white
                                  : d.connected
                                      ? const Color(0xFF2E7D32)
                                      : const Color(0xFF555555))),
                    ]),
                  ),
                ]),
              ),
            );

        Widget header(String t) => Container(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 3),
              child: Text(t, style: Xp.textBold.copyWith(color: const Color(0xFF1E3E9B))),
            );

        final Widget body;
        if (!net.btAvailable) {
          body = const Center(child: Text('This device has no Bluetooth.', style: Xp.textGrey));
        } else if (!net.btAllowed) {
          body = const SizedBox();
        } else if (!net.btOn) {
          body = const Center(child: Text('Bluetooth is turned off.', style: Xp.textGrey));
        } else {
          body = ListView(children: [
            header('Paired devices'),
            if (paired.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('None yet.', style: Xp.textGrey)),
            ...paired.map(row),
            header(net.btSearching ? 'Nearby devices (searching...)' : 'Nearby devices'),
            if (nearby.isEmpty)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(net.btSearching ? 'Looking...' : 'Click "Add" to look for devices.', style: Xp.textGrey),
              ),
            ...nearby.map(row),
          ]);
        }

        return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _taskPane([
            _taskBox('Bluetooth Tasks', [
              _taskLink(Icons.power_settings_new, net.btOn ? 'Turn off Bluetooth' : 'Turn on Bluetooth',
                  net.btAvailable ? _toggle : null),
              _taskLink(Icons.add_circle_outline, net.btSearching ? 'Stop searching' : 'Add a device',
                  net.btOn && net.btAllowed ? () => net.search(!net.btSearching) : null),
              _taskLink(Icons.settings, "Open Android's Bluetooth settings", net.btSettings),
            ]),
            _taskBox('Details', [
              Text(
                  net.btOn
                      ? 'This tablet shows up as\n${net.btName.isEmpty ? '(unknown)' : net.btName}'
                      : 'Bluetooth is off',
                  style: Xp.text.copyWith(fontSize: 12)),
            ]),
          ]),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (net.btAvailable && !net.btAllowed)
                _Banner(
                    text: 'Allow the desktop to find and connect to nearby devices.',
                    button: 'Allow',
                    onTap: net.askPermissions),
              Expanded(child: Container(color: Colors.white, child: body)),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Wrap(alignment: WrapAlignment.end, spacing: 6, children: [
                  XpButton(
                      label: net.btSearching ? 'Stop' : 'Add...',
                      onPressed: net.btOn && net.btAllowed ? () => net.search(!net.btSearching) : null),
                  XpButton(
                      label: 'Pair',
                      isDefault: true,
                      onPressed: sel == null || sel.paired || sel.pairing ? null : () => net.pair(sel)),
                  XpButton(label: 'Remove', onPressed: sel == null || !sel.paired ? null : () => net.unpair(sel)),
                  XpButton(
                      label: 'Connect...',
                      onPressed: sel == null || !sel.paired ? null : () => net.btSettings()),
                ]),
              ),
            ]),
          ),
        ]);
      },
    );
  }
}

WindowManager _findWm(BuildContext context) => context.read<WindowManager>();
