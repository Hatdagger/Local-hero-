import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../oscar/bytes.dart';

/// Server used when nothing has been entered yet. Change this to bake in a
/// default server for your friends.
const String kDefaultServer = '';

const String kDefaultAutoAway = 'I am away from my phone right now.';

enum SoundEvent { buddyIn, buddyOut, firstIm, imReceived, imSent }

const Map<SoundEvent, String> kDefaultSounds = {
  SoundEvent.buddyIn: 'dooropen.wav',
  SoundEvent.buddyOut: 'doorslam.wav',
  SoundEvent.firstIm: 'ring.wav',
  SoundEvent.imReceived: 'imrcv.wav',
  SoundEvent.imSent: 'imsend.wav',
};

String soundEventLabel(SoundEvent e) => switch (e) {
      SoundEvent.buddyIn => 'Buddy signs on',
      SoundEvent.buddyOut => 'Buddy signs off',
      SoundEvent.firstIm => 'First message in a new conversation',
      SoundEvent.imReceived => 'Message received',
      SoundEvent.imSent => 'Message sent',
    };

enum ControllerMode { auto, on, off }

class SavedAccount {
  final String screenName;
  bool savePassword;
  bool autoLogin;
  SavedAccount(this.screenName, {this.savePassword = true, this.autoLogin = false});

  Map<String, dynamic> toJson() => {'sn': screenName, 'save': savePassword, 'auto': autoLogin};
  static SavedAccount fromJson(Map<String, dynamic> j) =>
      SavedAccount(j['sn'] as String, savePassword: j['save'] as bool? ?? true, autoLogin: j['auto'] as bool? ?? false);
}

class AppSettings extends ChangeNotifier {
  late SharedPreferences _p;
  final FlutterSecureStorage _secure = const FlutterSecureStorage();
  bool _secureWorks = true;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    try {
      await _secure.read(key: '__probe');
    } catch (_) {
      // No keyring (e.g. Steam Deck game mode): fall back to app preferences.
      _secureWorks = false;
    }
  }

  // ------------------------------------------------------------ setup
  bool get setupDone => _p.getBool('setupDone') ?? false;
  set setupDone(bool v) => _set('setupDone', v);

  // ------------------------------------------------------------ server
  String get server => _p.getString('server') ?? kDefaultServer;
  set server(String v) => _set('server', v.trim());

  bool get fixLoopbackRedirects => _p.getBool('fixLoopback') ?? true;
  set fixLoopbackRedirects(bool v) => _set('fixLoopback', v);

  // ------------------------------------------------------------ accounts
  List<SavedAccount> get accounts {
    final raw = _p.getString('accounts');
    if (raw == null) return [];
    return (jsonDecode(raw) as List).map((e) => SavedAccount.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveAccounts(List<SavedAccount> list) async {
    await _p.setString('accounts', jsonEncode(list.map((a) => a.toJson()).toList()));
    notifyListeners();
  }

  String? get lastScreenName => _p.getString('lastSn');
  set lastScreenName(String? v) => v == null ? _p.remove('lastSn') : _set('lastSn', v);

  Future<void> rememberAccount(String sn, String password, {required bool savePassword, required bool autoLogin}) async {
    final list = accounts;
    list.removeWhere((a) => normalizeSn(a.screenName) == normalizeSn(sn));
    if (autoLogin) {
      for (final a in list) {
        a.autoLogin = false;
      }
    }
    list.insert(0, SavedAccount(sn, savePassword: savePassword, autoLogin: autoLogin));
    await saveAccounts(list);
    lastScreenName = sn;
    if (savePassword) {
      await _writeSecret('pw:${normalizeSn(sn)}', password);
    } else {
      await _deleteSecret('pw:${normalizeSn(sn)}');
    }
  }

  Future<void> forgetAccount(String sn) async {
    final list = accounts..removeWhere((a) => normalizeSn(a.screenName) == normalizeSn(sn));
    await saveAccounts(list);
    await _deleteSecret('pw:${normalizeSn(sn)}');
  }

  Future<String?> passwordFor(String sn) => _readSecret('pw:${normalizeSn(sn)}');

  SavedAccount? get autoLoginAccount => accounts.where((a) => a.autoLogin && a.savePassword).firstOrNull;

  Future<void> _writeSecret(String k, String v) async {
    if (_secureWorks) {
      try {
        await _secure.write(key: k, value: v);
        return;
      } catch (_) {
        _secureWorks = false;
      }
    }
    await _p.setString('secret:$k', base64Encode(utf8.encode(v)));
  }

  Future<String?> _readSecret(String k) async {
    if (_secureWorks) {
      try {
        final v = await _secure.read(key: k);
        if (v != null) return v;
      } catch (_) {
        _secureWorks = false;
      }
    }
    final s = _p.getString('secret:$k');
    return s == null ? null : utf8.decode(base64Decode(s));
  }

  Future<void> _deleteSecret(String k) async {
    try {
      if (_secureWorks) await _secure.delete(key: k);
    } catch (_) {}
    await _p.remove('secret:$k');
  }

  // ------------------------------------------------------------ away / profile
  bool get autoAway => _p.getBool('autoAway') ?? true;
  set autoAway(bool v) => _set('autoAway', v);

  String get autoAwayMessage => _p.getString('autoAwayMsg') ?? kDefaultAutoAway;
  set autoAwayMessage(String v) => _set('autoAwayMsg', v);

  List<String> get awayMessages =>
      _p.getStringList('awayMsgs') ??
      const ['I am away from my computer right now.', 'Out to lunch. Back soon!', 'Gaming. Leave a message!'];
  set awayMessages(List<String> v) => _setList('awayMsgs', v);

  String profileFor(String sn) => _p.getString('profile:${normalizeSn(sn)}') ?? '';
  void setProfileFor(String sn, String text) => _set('profile:${normalizeSn(sn)}', text);

  String? iconPathFor(String sn) => _p.getString('icon:${normalizeSn(sn)}');
  void setIconPathFor(String sn, String? path) =>
      path == null ? _remove('icon:${normalizeSn(sn)}') : _set('icon:${normalizeSn(sn)}', path);

  // ------------------------------------------------------------ sounds
  bool get soundsOn => _p.getBool('soundsOn') ?? true;
  set soundsOn(bool v) => _set('soundsOn', v);

  /// File name for an event, or '' for silent.
  String soundFor(SoundEvent e) => _p.getString('sound:${e.name}') ?? kDefaultSounds[e]!;
  void setSoundFor(SoundEvent e, String file) => _set('sound:${e.name}', file);

  // ------------------------------------------------------------ history
  bool get historyEnabled => _p.getBool('history') ?? false;
  set historyEnabled(bool v) => _set('history', v);

  // ------------------------------------------------------------ direct connect
  /// Let buddies ask to Direct Connect (pictures straight between devices).
  bool get allowDirectConnect => _p.getBool('directConnect') ?? true;
  set allowDirectConnect(bool v) => _set('directConnect', v);

  // ------------------------------------------------------------ input
  ControllerMode get controllerMode => ControllerMode.values.byName(_p.getString('controller') ?? 'auto');
  set controllerMode(ControllerMode v) => _set('controller', v.name);

  /// Pinned TLS fingerprint of a server's account API (trust on first use).
  String? certFor(String server) => _p.getString('cert:${server.toLowerCase()}');
  void setCertFor(String server, String fp) => _set('cert:${server.toLowerCase()}', fp);

  bool get t9Predictive => _p.getBool('t9Predictive') ?? true;
  set t9Predictive(bool v) => _set('t9Predictive', v);

  /// The keyboard's number pad types like a phone keypad (by position).
  bool get numpadT9 => _p.getBool('numpadT9') ?? true;
  set numpadT9(bool v) => _set('numpadT9', v);

  /// Buzz on each on-screen key press (phone vibration, controller rumble).
  bool get keyFeedback => _p.getBool('keyFeedback') ?? true;
  set keyFeedback(bool v) => _set('keyFeedback', v);

  /// Clicks, flips, slides and boot beeps from the on-screen phones/gadgets.
  bool get phoneSounds => _p.getBool('phoneSounds') ?? true;
  set phoneSounds(bool v) => _set('phoneSounds', v);

  /// Cartoon phone look: brick, ice, nightglow, clamshell, girlypop, gyaru,
  /// or a gadget: wideflip, dashboard, pocketmail, musicplayer, pocketbrick.
  /// Older builds stored candybar/flip/slider; those map to the new looks.
  String get phoneStyle {
    final v = _p.getString('phoneStyle') ?? 'brick';
    return const {'candybar': 'brick', 'flip': 'clamshell', 'slider': 'nightglow'}[v] ?? v;
  }

  set phoneStyle(String v) => _set('phoneStyle', v);

  /// 't9' = phone keypad, 'qwerty' = sideways slider with a full keyboard.
  String get keyboardKind => _p.getString('keyboardKind') ?? 't9';
  set keyboardKind(String v) => _set('keyboardKind', v);

  /// A chat's own keyboard (gadget/phone style and T9 or QWERTY), or null to
  /// use the defaults above. Stored as 'style|kind'.
  (String, String)? keyboardOverride(String sn) {
    final v = _p.getString('kbd:${normalizeSn(sn)}');
    if (v == null) return null;
    final i = v.indexOf('|');
    if (i < 0) return null;
    final style = v.substring(0, i);
    final kind = v.substring(i + 1);
    return (const {'candybar': 'brick', 'flip': 'clamshell', 'slider': 'nightglow'}[style] ?? style, kind == 'qwerty' ? 'qwerty' : 't9');
  }

  void setKeyboardFor(String sn, String? style, {String kind = 't9'}) =>
      style == null ? _remove('kbd:${normalizeSn(sn)}') : _set('kbd:${normalizeSn(sn)}', '$style|$kind');

  /// Style / keyboard kind for typing in [chat] (a screen name), or the defaults.
  String phoneStyleFor(String? chat) => (chat == null ? null : keyboardOverride(chat)?.$1) ?? phoneStyle;
  String keyboardKindFor(String? chat) => (chat == null ? null : keyboardOverride(chat)?.$2) ?? keyboardKind;

  /// Phone placement in landscape, per keyboard kind: centre as a fraction
  /// of the free space (0 = left/top, 1 = right/bottom) and width as a
  /// fraction of the screen width.
  double oskX(String kind) => _p.getDouble('oskX:$kind') ?? 1.0;
  double oskY(String kind) => _p.getDouble('oskY:$kind') ?? 0.5;
  double oskWidth(String kind) => _p.getDouble('oskW:$kind') ?? (kind == 'qwerty' ? 0.5 : 1 / 3);

  static const oskMinWidth = 0.18;
  static const oskMaxWidth = 0.9;

  void setOskPlacement(String kind, {double? x, double? y, double? width}) {
    if (x != null) _p.setDouble('oskX:$kind', x.clamp(0.0, 1.0));
    if (y != null) _p.setDouble('oskY:$kind', y.clamp(0.0, 1.0));
    if (width != null) _p.setDouble('oskW:$kind', width.clamp(oskMinWidth, oskMaxWidth));
    notifyListeners();
  }

  void resetOskPlacement() {
    for (final k in ['t9', 'qwerty']) {
      _p.remove('oskX:$k');
      _p.remove('oskY:$k');
      _p.remove('oskW:$k');
    }
    notifyListeners();
  }

  /// Phone fills the whole screen, hiding the chat (its little screen shows
  /// the conversation). Portrait uses the keypad phones, landscape the slider.
  bool get phoneFullPortrait => _p.getBool('phoneFullP') ?? false;
  set phoneFullPortrait(bool v) => _set('phoneFullP', v);
  bool get phoneFullLandscape => _p.getBool('phoneFullL') ?? false;
  set phoneFullLandscape(bool v) => _set('phoneFullL', v);

  /// Asked Android once to let AIM run in the background (battery exemption).
  bool get askedBackground => _p.getBool('askedBg') ?? false;
  set askedBackground(bool v) => _set('askedBg', v);

  // ------------------------------------------------------------ look
  /// Your message colours (ARGB), sent to buddies like AIM did. null = default.
  int? get myTextColor => _p.getInt('myFg');
  set myTextColor(int? v) => v == null ? _remove('myFg') : _set('myFg', v);
  int? get myBackColor => _p.getInt('myBg');
  set myBackColor(int? v) => v == null ? _remove('myBg') : _set('myBg', v);

  /// Show the colours other people picked for their messages.
  bool get showTheirColors => _p.getBool('theirColors') ?? true;
  set showTheirColors(bool v) => _set('theirColors', v);

  /// Chat wallpaper, only visible on this device. '' = none,
  /// 'builtin:<name>' or 'file:<path>'. Per buddy, falling back to the default.
  String get defaultWallpaper => _p.getString('wall:*') ?? '';
  set defaultWallpaper(String v) => _set('wall:*', v);
  String? wallpaperOverride(String sn) => _p.getString('wall:${normalizeSn(sn)}');
  String wallpaperFor(String sn) => wallpaperOverride(sn) ?? defaultWallpaper;
  void setWallpaperFor(String sn, String? v) =>
      v == null ? _remove('wall:${normalizeSn(sn)}') : _set('wall:${normalizeSn(sn)}', v);

  /// Minutes in the background before the automatic away message goes up.
  int get autoAwayMinutes => _p.getInt('autoAwayMin') ?? 10;
  set autoAwayMinutes(int v) => _set('autoAwayMin', v);

  // ------------------------------------------------------------ helpers
  void _set(String k, Object v) {
    if (v is bool) {
      _p.setBool(k, v);
    } else if (v is String) {
      _p.setString(k, v);
    } else if (v is int) {
      _p.setInt(k, v);
    } else if (v is double) {
      _p.setDouble(k, v);
    }
    notifyListeners();
  }

  void _setList(String k, List<String> v) {
    _p.setStringList(k, v);
    notifyListeners();
  }

  void _remove(String k) {
    _p.remove(k);
    notifyListeners();
  }
}
