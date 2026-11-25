import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/app_state.dart';
import '../oscar/bytes.dart';
import 'aim_windows.dart';
import 'browser.dart';
import 'claude_window.dart';
import 'desktop_icons.dart';
import 'network.dart';
import 'explorer.dart';
import 'media_player.dart';
import 'mini_player.dart';
import 'notepad.dart';
import 'penis_music.dart';
import 'session.dart';
import 'solitaire.dart';
import 'updater.dart';
import 'platform.dart';
import 'wallpaper.dart';
import 'toasts.dart';
import 'window_manager.dart';
import 'xp_theme.dart';

export 'toasts.dart';

/// Ties the pieces together: opens the desktop's windows, keeps the AIM
/// windows in step with the connection, and runs Run-box commands.
class Desk {
  Desk(this.wm, this.app, this.apps) {
    app.addListener(_onApp);
    wm.addListener(_onWm);
    wm.onDockChanged = _saveDock;
    _loadRunHistory();
    _loadDock();
    unawaited(desktop.load());
    _buddySub = app.buddyNotes.listen(_onBuddyNote);
  }

  final toasts = Toasts();
  final desktop = DesktopModel();
  // ignore: unused_field
  StreamSubscription<BuddyNote>? _buddySub;

  void _onBuddyNote(BuddyNote n) {
    if (!n.signedOn) return;
    toasts.show(DeskToast(
      title: n.screenName,
      text: '${n.screenName} has signed on.',
      icon: Icons.chat_bubble,
      onTap: () => openIm(n.screenName),
    ));
  }

  // ------------------------------------------------------------ Buddy List dock

  DockSide _buddyDock = DockSide.none;

  Future<void> _loadDock() async {
    final p = await SharedPreferences.getInstance();
    _buddyDock = DockSide.values.firstWhere((d) => d.name == p.getString('buddyDock'), orElse: () => DockSide.none);
    if (wm.isOpen(kBuddyListId)) wm.dockTo(kBuddyListId, _buddyDock);
  }

  Future<void> _saveDock(DeskWindow w) async {
    if (w.id != kBuddyListId) return;
    _buddyDock = w.dock;
    final p = await SharedPreferences.getInstance();
    await p.setString('buddyDock', w.dock.name);
  }

  void _openBuddyList() {
    final fresh = !wm.isOpen(kBuddyListId);
    wm.open(buddyListWindow(app.myScreenName));
    if (fresh && _buddyDock != DockSide.none) wm.dockTo(kBuddyListId, _buddyDock);
  }

  final WindowManager wm;
  final AppState app;
  final AppList apps;

  // ------------------------------------------------------------ restarts

  /// Windows reopen where they were after a restart (see session.dart).
  late final session = DeskSession(wm, reopen: reopenWindow, reopenOf: _reopenOf);

  static const _simpleReopen = {
    kMediaPlayerId: 'player',
    kMiniPlayerId: 'mini',
    'solitaire': 'solitaire',
    kClaudeId: 'claude',
    kNetworkId: 'network',
    kBluetoothId: 'bluetooth',
    'display': 'display',
    'downloads': 'downloads',
  };

  String? _reopenOf(DeskWindow w) => w.reopen ?? _simpleReopen[w.id];

  /// Opens a window from a reopen string saved before a restart.
  DeskWindow? reopenWindow(String spec) {
    final bar = spec.indexOf('|');
    final kind = bar < 0 ? spec : spec.substring(0, bar);
    final arg = bar < 0 ? '' : spec.substring(bar + 1);
    bool exists(String p) => FileSystemEntity.typeSync(p) != FileSystemEntityType.notFound;
    switch (kind) {
      case 'explorer':
        final special = arg.startsWith('::');
        return wm.open(explorerWindow(path: arg.isEmpty || (!special && !exists(arg)) ? null : arg));
      case 'browser':
        return wm.open(browserWindow(url: arg.isEmpty ? null : arg));
      case 'notepad':
        return arg.isNotEmpty && exists(arg) ? wm.open(notepadFileWindow(arg)) : null;
      case 'picture':
        return arg.isNotEmpty && exists(arg) ? wm.open(pictureWindow(arg)) : null;
      case 'player':
        return wm.open(mediaPlayerWindow());
      case 'mini':
        return wm.open(miniPlayerWindow());
      case 'solitaire':
        return wm.open(solitaireWindow());
      case 'claude':
        return wm.open(claudeWindow());
      case 'network':
        return wm.open(networkWindow());
      case 'bluetooth':
        return wm.open(bluetoothWindow());
      case 'display':
        return wm.open(displayPropertiesWindow());
      case 'downloads':
        return wm.open(downloadsWindow());
    }
    return null;
  }

  // ------------------------------------------------------------ openers

  void openAim() {
    if (_online) {
      _openBuddyList();
    } else {
      wm.open(signOnWindow());
    }
  }

  void openIm(String screenName) {
    final conv = app.conversationFor(screenName);
    if (conv.displayName == conv.key) conv.displayName = screenName;
    _seen[conv.key] = conv.lines.length;
    wm.open(_imWindowFor(conv.displayName));
  }

  DeskWindow _imWindowFor(String screenName) {
    final w = imWindow(screenName);
    final key = normalizeSn(screenName);
    return DeskWindow(
      id: w.id,
      title: w.title,
      icon: w.icon,
      content: w.content,
      size: w.rect.size,
      minSize: w.minSize,
      onClose: () {
        _seen.remove(key);
        app.closeConversation(key);
      },
    );
  }

  void openAwayEditor() => wm.open(awayEditorWindow());
  void openAddBuddy() => wm.open(addBuddyWindow());
  void openSendIm() => wm.open(sendImWindow());
  void openDisplay() => wm.open(displayPropertiesWindow());
  void openNotepad() => wm.open(notepadWindow());
  void openSolitaire() => wm.open(solitaireWindow());
  void openClaude() => wm.open(claudeWindow());
  void openUpdate() => wm.open(updateWindow());
  void openRun() => wm.open(runWindow(), at: Offset(12, wm.desk.height - 200));
  void openExplorer([String? path]) => wm.open(explorerWindow(path: path));
  void openBrowser([String? url]) => wm.open(browserWindow(url: url));
  void openDownloads() => wm.open(downloadsWindow());
  void openNetwork() => wm.open(networkWindow());
  void openBluetooth() => wm.open(bluetoothWindow());
  void openRecycleBin() => openExplorer(kRecyclePath);
  Future<void> openMyDocuments() async {
    await Places.init();
    openExplorer(Places.documents);
  }

  /// The Media Player (0 = Now Playing, 1 = Music Library, 2 = Videos).
  void openMediaPlayer({int tab = 0}) => wm.open(mediaPlayerWindow(tab: tab));

  /// Plays a music or video file from the desktop in the Media Player.
  Future<void> playFile(String path, {required bool video}) async {
    await DeskPlayer.instance.playFile(path, video: video);
    if (video || !wm.isOpen(kMiniPlayerId)) openMediaPlayer();
  }

  /// The always-on-top player remote, in the bottom-right corner.
  void openPenisMusic() => wm.open(penisMusicWindow());

  void openMiniPlayer() =>
      wm.open(miniPlayerWindow(), at: Offset(wm.desk.width - 372, wm.desk.height - 170));

  Future<void> openBrave([String? url]) => openBraveWindow(this, url: url);

  void message(String title, String text, {IconData icon = Icons.error}) {
    wm.open(DeskWindow(
      id: 'msg:${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      icon: icon,
      size: const Size(360, 150),
      resizable: false,
      canMaximize: false,
      canMinimize: false,
      content: (c, w) => Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, size: 32, color: icon == Icons.error ? const Color(0xFFD03A1B) : Xp.selection),
              const SizedBox(width: 12),
              Expanded(child: Text(text, style: Xp.text)),
            ]),
          ),
          Center(child: XpButton(label: 'OK', isDefault: true, onPressed: () => wm.close(w.id))),
        ]),
      ),
    ));
  }

  // ------------------------------------------------------------ AIM sync

  bool get _online => app.signedOn && app.everOnline;
  bool _wasOnline = false;
  final Map<String, int> _seen = {};
  String? _lastActive;

  void _onApp() {
    final online = _online;
    if (online && !_wasOnline) {
      _wasOnline = true;
      _seen.clear();
      for (final c in app.conversations.values) {
        _seen[c.key] = c.lines.length;
      }
      wm.close(kSignOnId);
      _openBuddyList();
    } else if (!app.signedOn && _wasOnline) {
      // Signed off (or signed on somewhere else): back to the Sign On window.
      _wasOnline = false;
      wm.closeWhere((w) => w.id.startsWith('aim:'));
      wm.open(signOnWindow());
      return;
    }
    if (!online) return;

    for (final c in app.conversations.values.toList()) {
      final n = c.lines.length;
      final before = _seen[c.key];
      _seen[c.key] = n;
      if (before != null && n <= before) continue;
      final newest = n == 0 ? null : c.lines.last;
      final fromThem = newest != null && !newest.mine && !newest.system;
      if (!fromThem) continue;
      final id = imId(c.key);
      if (wm.isOpen(id)) {
        if (wm.byId(id)!.minimized || wm.activeId != id) wm.flash(id);
      } else {
        // A new IM pops up behind what you're doing and flashes.
        wm.open(_imWindowFor(c.displayName), activate: wm.activeId == null);
      }
    }
  }

  void _onWm() {
    final a = wm.activeId;
    if (a == _lastActive) return;
    _lastActive = a;
    // Take the keyboard back from a web page when another window comes up.
    final web = a == kClaudeId || isBrowserWindow(a);
    if (!web) unawaited(DeskPlatform.focusDesktop());
    unawaited(DeskPlatform.setBrowserKeys(isBrowserWindow(a)));
    final key = (a != null && a.startsWith('aim:im:')) ? a.substring(7) : null;
    if (app.openChat != key) scheduleMicrotask(() => app.openConversation(key));
  }

  // ------------------------------------------------------------ Run

  List<String> runHistory = [];

  Future<void> _loadRunHistory() async {
    final p = await SharedPreferences.getInstance();
    runHistory = p.getStringList('runHistory') ?? [];
  }

  Future<void> _remember(String cmd) async {
    runHistory.remove(cmd);
    runHistory.insert(0, cmd);
    if (runHistory.length > 20) runHistory = runHistory.sublist(0, 20);
    final p = await SharedPreferences.getInstance();
    await p.setStringList('runHistory', runHistory);
  }

  static const _soon = {'cmd', 'control', 'mspaint', 'calc'};

  /// Runs what was typed in the Run box. False if nothing matched (the box
  /// then stays open and an error shows).
  Future<bool> run(String typed) async {
    final cmd = typed.trim();
    if (cmd.isEmpty) return false;
    final lower = cmd.toLowerCase();
    var ok = true;
    if (const {'aim', 'aol', 'buddy', 'buddylist', 'im'}.contains(lower)) {
      openAim();
    } else if (const {'desk.cpl', 'display', 'wallpaper', 'background'}.contains(lower)) {
      openDisplay();
    } else if (const {'notepad', 'notepad.exe', 'edit'}.contains(lower)) {
      openNotepad();
    } else if (const {'sol', 'sol.exe', 'solitaire', 'cards'}.contains(lower)) {
      openSolitaire();
    } else if (const {'claude', 'claude.ai'}.contains(lower)) {
      openClaude();
    } else if (const {'update', 'wupdate', 'updates'}.contains(lower)) {
      openUpdate();
    } else if (const {'explorer', 'explorer.exe', 'my computer', 'computer', 'files', 'winfile'}.contains(lower)) {
      openExplorer();
    } else if (const {'my documents', 'documents'}.contains(lower)) {
      await openMyDocuments();
    } else if (const {'recycle bin', 'recycle', 'trash'}.contains(lower)) {
      openRecycleBin();
    } else if (const {'iexplore', 'iexplore.exe', 'internet', 'browser', 'web'}.contains(lower)) {
      openBrowser();
    } else if (const {'ncpa.cpl', 'wifi', 'wi-fi', 'wireless', 'network', 'networks'}.contains(lower)) {
      openNetwork();
    } else if (const {'bluetooth', 'bthprops.cpl', 'bt'}.contains(lower)) {
      openBluetooth();
    } else if (lower == 'brave') {
      await openBrave();
    } else if (const {'downloads', 'my downloads'}.contains(lower)) {
      openDownloads();
    } else if (const {'wmplayer', 'wmplayer.exe', 'player', 'media player', 'music', 'videos', 'video', 'mixes', 'auto mixes'}.contains(lower)) {
      openMediaPlayer(tab: lower == 'videos' || lower == 'video' ? 2 : (lower.contains('mixes') ? 3 : 1));
    } else if (const {'penis music', 'penismusic', 'penis'}.contains(lower)) {
      openPenisMusic();
    } else if (const {'mini player', 'miniplayer', 'localhero', 'local hero'}.contains(lower)) {
      openMiniPlayer();
    } else if (cmd.startsWith('/')) {
      if (FileSystemEntity.isDirectorySync(cmd)) {
        openExplorer(cmd);
      } else if (FileSystemEntity.isFileSync(cmd)) {
        await openFileOnDesk(this, cmd);
      } else {
        ok = false;
        message('Run', "Cannot find '$cmd'. Make sure you typed the name correctly, and then try again.");
      }
    } else if (lower == 'logoff') {
      await logOff();
    } else if (const {'shutdown', 'exit', 'quit'}.contains(lower)) {
      confirmShutDown();
    } else if (_soon.contains(lower)) {
      message('Not built yet', "'$cmd' isn't part of the desktop yet. It's coming in a later version.",
          icon: Icons.info);
    } else if (_looksLikeUrl(cmd)) {
      final url = cmd.contains('://') ? cmd : 'https://$cmd';
      openBrowser(url);
    } else {
      await apps.load();
      final a = apps.find(cmd);
      if (a != null) {
        ok = await DeskPlatform.launch(a.package);
      } else {
        ok = false;
      }
      if (!ok) {
        message('Run', "Cannot find '$cmd'. Make sure you typed the name correctly, and then try again.");
      }
    }
    if (ok) await _remember(cmd);
    return ok;
  }

  static bool _looksLikeUrl(String s) {
    if (s.contains(' ')) return false;
    if (RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false).hasMatch(s)) return true;
    return RegExp(r'^[\w-]+(\.[\w-]+)+(:\d+)?(/.*)?$').hasMatch(s) && !s.startsWith('/');
  }

  // ------------------------------------------------------------ Log Off

  Future<void> logOff() async {
    if (await DeskPlatform.isDefaultHome()) {
      await DeskPlatform.homeSettings();
    } else {
      await SystemNavigator.pop();
    }
  }

  void confirmLogOff() {
    wm.closeStart();
    wm.open(DeskWindow(
      id: 'logoff',
      title: 'Log Off',
      icon: Icons.key,
      size: const Size(330, 170),
      resizable: false,
      canMaximize: false,
      canMinimize: false,
      content: (c, w) => Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Are you sure you want to log off?', style: Xp.textBold),
          const SizedBox(height: 6),
          const Text('Android will ask which home screen to switch to. AIM stays signed on.', style: Xp.text),
          const Spacer(),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            XpButton(
                label: 'Log Off',
                isDefault: true,
                onPressed: () {
                  wm.close(w.id);
                  unawaited(logOff());
                }),
            const SizedBox(width: 6),
            XpButton(label: 'Cancel', onPressed: () => wm.close(w.id)),
          ]),
        ]),
      ),
    ));
  }

  // ------------------------------------------------------------ Shut Down

  /// The "Turn off" box: Restart, Shut Down, Cancel.
  void confirmShutDown() {
    wm.closeStart();
    Future<void> off({required bool restart}) async {
      if (app.signedOn) await app.signOff();
      await DeskPlatform.shutdown(restart: restart);
    }

    wm.open(DeskWindow(
      id: 'shutdown',
      title: 'Turn Off Desktop',
      icon: Icons.power_settings_new,
      size: const Size(380, 190),
      resizable: false,
      canMaximize: false,
      canMinimize: false,
      content: (c, w) => Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('What do you want to do?', style: Xp.textBold),
          const SizedBox(height: 6),
          const Text(
              'Shut Down closes the desktop completely and signs off AIM. If the desktop is your home '
              'screen, Android will ask which home screen to use.',
              style: Xp.text),
          const Spacer(),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            XpButton(label: 'Restart', onPressed: () => unawaited(off(restart: true))),
            const SizedBox(width: 6),
            XpButton(label: 'Shut Down', isDefault: true, onPressed: () => unawaited(off(restart: false))),
            const SizedBox(width: 6),
            XpButton(label: 'Cancel', onPressed: () => wm.close(w.id)),
          ]),
        ]),
      ),
    ));
  }

  // ------------------------------------------------------------ Run window

  DeskWindow runWindow() => DeskWindow(
        id: 'run',
        title: 'Run',
        icon: Icons.play_arrow,
        size: const Size(380, 190),
        resizable: false,
        canMaximize: false,
        content: (c, w) => _RunBox(desk: this, w: w),
      );
}

class _RunBox extends StatefulWidget {
  const _RunBox({required this.desk, required this.w});
  final Desk desk;
  final DeskWindow w;

  @override
  State<_RunBox> createState() => _RunBoxState();
}

class _RunBoxState extends State<_RunBox> {
  late final TextEditingController _c =
      TextEditingController(text: widget.desk.runHistory.isEmpty ? '' : widget.desk.runHistory.first);

  @override
  void initState() {
    super.initState();
    _c.selection = TextSelection(baseOffset: 0, extentOffset: _c.text.length);
  }

  Future<void> _go() async {
    final ok = await widget.desk.run(_c.text);
    if (ok) widget.desk.wm.close(widget.w.id);
  }

  @override
  Widget build(BuildContext context) {
    final wm = widget.desk.wm;
    final history = widget.desk.runHistory;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.play_circle_fill, size: 32, color: Xp.selection),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Type the name of a program, folder, app or website, and it will be opened for you.',
              style: Xp.text,
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          const Mnemonic('Open:', 0),
          const SizedBox(width: 8),
          Expanded(child: XpField(controller: _c, autofocus: true, onSubmitted: (_) => _go())),
          PopupMenuButton<String>(
            tooltip: 'History',
            enabled: history.isNotEmpty,
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.arrow_drop_down),
            onSelected: (v) => setState(() => _c.text = v),
            itemBuilder: (_) => [for (final h in history) PopupMenuItem(value: h, child: Text(h, style: Xp.text))],
          ),
        ]),
        const Spacer(),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          XpButton(label: 'OK', isDefault: true, onPressed: _go),
          const SizedBox(width: 6),
          XpButton(label: 'Cancel', onPressed: () => wm.close(widget.w.id)),
        ]),
      ]),
    );
  }
}
