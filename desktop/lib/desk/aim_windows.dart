import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app/app_state.dart';
import '../app/history.dart';
import '../oscar/bytes.dart';
import '../oscar/client.dart';
import 'desk.dart';
import 'window_manager.dart';
import 'xp_theme.dart';
import 'xp_window.dart';

const kSignOnId = 'aim:signon';
const kBuddyListId = 'aim:buddylist';
String imId(String key) => 'aim:im:$key';

// ======================================================================
// Sign On

DeskWindow signOnWindow() => DeskWindow(
      id: kSignOnId,
      title: 'Sign On',
      icon: Icons.chat_bubble,
      size: const Size(290, 470),
      resizable: false,
      canMaximize: false,
      content: (c, w) => const _SignOn(),
    );

/// Our own banner art for the AIM windows (a chat bubble, not AOL's logo).
class AimBanner extends StatelessWidget {
  const AimBanner({super.key, this.height = 110});
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFE36B), Color(0xFFF5B800)],
        ),
        border: Border(bottom: BorderSide(color: Color(0xFFB98900))),
      ),
      child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.chat_bubble, size: 46, color: Color(0xFF1E3E9B)),
        SizedBox(width: 10),
        Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Instant', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF1E3E9B), height: 1)),
          Text('Messenger', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF1E3E9B), height: 1)),
        ]),
      ]),
    );
  }
}

class _SignOn extends StatefulWidget {
  const _SignOn();

  @override
  State<_SignOn> createState() => _SignOnState();
}

class _SignOnState extends State<_SignOn> {
  final _sn = TextEditingController();
  final _pw = TextEditingController();
  final _server = TextEditingController();
  bool _save = true;
  bool _auto = false;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _server.text = app.settings.server;
    final accts = app.settings.accounts;
    if (accts.isNotEmpty) _pick(accts.first.screenName);
  }

  Future<void> _pick(String sn) async {
    final app = context.read<AppState>();
    final acct = app.settings.accounts.where((a) => normalizeSn(a.screenName) == normalizeSn(sn)).firstOrNull;
    _sn.text = sn;
    if (acct != null) {
      _save = acct.savePassword;
      _auto = acct.autoLogin;
      final pw = acct.savePassword ? await app.settings.passwordFor(sn) : null;
      if (!mounted) return;
      _pw.text = pw ?? '';
    }
    setState(() {});
  }

  void _signOn() {
    final app = context.read<AppState>();
    if (_sn.text.trim().isEmpty || _pw.text.isEmpty || _server.text.trim().isEmpty) return;
    app.settings.setupDone = true;
    app.signOn(
      server: _server.text.trim(),
      screenName: _sn.text.trim(),
      password: _pw.text,
      savePassword: _save,
      autoLogin: _auto,
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final connecting = app.link == LinkState.connecting || app.link == LinkState.reconnecting;
    final accts = app.settings.accounts;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const AimBanner(),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Expanded(child: Text('Screen Name', style: Xp.textBold)),
              if (accts.length > 1)
                PopupMenuButton<String>(
                  tooltip: 'Saved screen names',
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.arrow_drop_down, size: 20),
                  onSelected: _pick,
                  itemBuilder: (_) => [
                    for (final a in accts) PopupMenuItem(value: a.screenName, child: Text(a.screenName, style: Xp.text)),
                  ],
                ),
            ]),
            const SizedBox(height: 3),
            XpField(controller: _sn, autofocus: true, textInputAction: TextInputAction.next),
            const SizedBox(height: 10),
            const Text('Password', style: Xp.textBold),
            const SizedBox(height: 3),
            XpField(controller: _pw, obscure: true, onSubmitted: (_) => _signOn()),
            const SizedBox(height: 10),
            const Text('Server', style: Xp.textBold),
            const SizedBox(height: 3),
            XpField(controller: _server, hint: 'host:5190', onSubmitted: (_) => _signOn()),
            const SizedBox(height: 10),
            XpCheck(label: 'Save password', value: _save, onChanged: (v) => setState(() => _save = v)),
            XpCheck(label: 'Auto-login', value: _auto, onChanged: (v) => setState(() => _auto = v)),
            const SizedBox(height: 10),
            if (app.signOnError != null && app.link == LinkState.stopped)
              Text(app.signOnError!, style: Xp.text.copyWith(color: const Color(0xFFAA0000))),
            if (connecting)
              Text(app.linkMessage == null ? 'Connecting...' : 'Retrying: ${app.linkMessage}', style: Xp.text),
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              if (connecting)
                XpButton(label: 'Cancel', onPressed: () => app.signOff())
              else
                XpButton(label: 'Sign On', isDefault: true, onPressed: _signOn),
            ]),
          ]),
        ),
      ),
    ]);
  }
}

// ======================================================================
// Buddy List

DeskWindow buddyListWindow(String me) => DeskWindow(
      id: kBuddyListId,
      title: "$me's Buddy List",
      icon: Icons.people,
      size: const Size(250, 560),
      minSize: const Size(190, 300),
      content: (c, w) => _BuddyList(w: w),
    );

class _BuddyList extends StatefulWidget {
  const _BuddyList({required this.w});
  final DeskWindow w;

  @override
  State<_BuddyList> createState() => _BuddyListState();
}

class _BuddyListState extends State<_BuddyList> {
  String? _selected;
  final Set<String> _collapsed = {'__offline__'};

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final desk = context.read<Desk>();
    final groups = app.buddyGroups;
    final offline = <BuddyView>[];
    final rows = <Widget>[];

    Widget groupHeader(String id, String label, int on, int total) {
      final open = !_collapsed.contains(id);
      return GestureDetector(
        onTap: () => setState(() => open ? _collapsed.add(id) : _collapsed.remove(id)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(2, 4, 2, 2),
          child: Row(children: [
            Icon(open ? Icons.arrow_drop_down : Icons.arrow_right, size: 18),
            Text('$label ($on/$total)', style: Xp.textBold),
          ]),
        ),
      );
    }

    Widget buddyRow(BuddyView b) {
      final key = normalizeSn(b.screenName);
      final sel = _selected == key;
      var style = b.online ? Xp.text : Xp.textGrey;
      if (b.away) style = style.copyWith(color: const Color(0xFF808080), fontStyle: FontStyle.italic);
      if (sel) style = style.copyWith(color: Colors.white);
      final unread = app.conversations[key]?.unread ?? 0;
      return GestureDetector(
        onTap: () => setState(() => _selected = key),
        onDoubleTap: () => desk.openIm(b.screenName),
        onSecondaryTapUp: (d) => _buddyMenu(context, b, d.globalPosition),
        onLongPressStart: (d) => _buddyMenu(context, b, d.globalPosition),
        child: Container(
          color: sel ? Xp.selection : Colors.transparent,
          padding: const EdgeInsets.fromLTRB(22, 2, 4, 2),
          child: Row(children: [
            if (b.away) Icon(Icons.description, size: 13, color: sel ? Colors.white : const Color(0xFF9C7B1E)),
            if (b.away) const SizedBox(width: 3),
            Expanded(
              child: Text(
                b.screenName + (b.idleMinutes > 0 && b.online ? '  (${_idle(b.idleMinutes)})' : ''),
                style: style,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (unread > 0) Icon(Icons.mark_chat_unread, size: 14, color: sel ? Colors.white : Xp.flash),
          ]),
        ),
      );
    }

    for (final (name, buddies) in groups) {
      final on = buddies.where((b) => b.online).toList();
      offline.addAll(buddies.where((b) => !b.online));
      rows.add(groupHeader(name, name, on.length, buddies.length));
      if (!_collapsed.contains(name)) rows.addAll(on.map(buddyRow));
    }
    final total = groups.fold<int>(0, (a, g) => a + g.$2.length);
    rows.add(groupHeader('__offline__', 'Offline', offline.length, total));
    if (!_collapsed.contains('__offline__')) rows.addAll(offline.map(buddyRow));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Menu bar
      Container(
        color: Xp.face,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(children: [
          _MenuBarButton(label: 'My AIM', items: [
            if (!app.isAway) ('Away Message...', () => desk.openAwayEditor()),
            if (app.isAway) ("I'm Back", () => app.setAway(null)),
            ('Sign Off', () => app.signOff()),
          ]),
          _MenuBarButton(label: 'People', items: [
            ('Send Instant Message...', () => desk.openSendIm()),
            ('Add Buddy...', () => desk.openAddBuddy()),
          ]),
        ]),
      ),
      const AimBanner(height: 64),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          app.isAway ? '${app.myScreenName} (Away)' : app.myScreenName,
          style: Xp.textBold,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      if (app.link == LinkState.reconnecting)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text('Reconnecting...', style: Xp.text.copyWith(color: const Color(0xFFAA0000))),
        ),
      Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Xp.fieldBorder)),
          child: ListView(children: rows),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(6),
        child: Wrap(spacing: 4, runSpacing: 4, alignment: WrapAlignment.center, children: [
          XpButton(
              label: 'IM',
              minWidth: 50,
              onPressed: _selected == null ? null : () => desk.openIm(_nameFor(groups, _selected!))),
          XpButton(label: 'Add', minWidth: 50, onPressed: () => desk.openAddBuddy()),
          XpButton(
              label: app.isAway ? 'Back' : 'Away',
              minWidth: 50,
              onPressed: () => app.isAway ? app.setAway(null) : desk.openAwayEditor()),
        ]),
      ),
    ]);
  }

  String _nameFor(List<(String, List<BuddyView>)> groups, String key) {
    for (final g in groups) {
      for (final b in g.$2) {
        if (normalizeSn(b.screenName) == key) return b.screenName;
      }
    }
    return key;
  }

  static String _idle(int m) => m >= 60 ? '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}' : '$m';

  Future<void> _buddyMenu(BuildContext context, BuddyView b, Offset at) async {
    final app = context.read<AppState>();
    final desk = context.read<Desk>();
    setState(() => _selected = normalizeSn(b.screenName));
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
      items: const [
        PopupMenuItem(value: 'im', child: Text('Send Instant Message', style: Xp.text)),
        PopupMenuItem(value: 'remove', child: Text('Remove Buddy', style: Xp.text)),
      ],
    );
    if (v == 'im') desk.openIm(b.screenName);
    if (v == 'remove') unawaited(app.removeBuddy(b.screenName));
  }
}

class _MenuBarButton extends StatelessWidget {
  const _MenuBarButton({required this.label, required this.items});
  final String label;
  final List<(String, VoidCallback)> items;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: '',
      offset: const Offset(0, 22),
      padding: EdgeInsets.zero,
      onSelected: (i) => items[i].$2(),
      itemBuilder: (_) => [
        for (var i = 0; i < items.length; i++)
          PopupMenuItem(value: i, height: 30, child: Text(items[i].$1, style: Xp.text)),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(label, style: Xp.text),
      ),
    );
  }
}

// ======================================================================
// Instant Message window (one per buddy)

DeskWindow imWindow(String screenName) {
  final key = normalizeSn(screenName);
  return DeskWindow(
    id: imId(key),
    title: '$screenName - Instant Message',
    icon: Icons.chat,
    size: const Size(440, 380),
    minSize: const Size(260, 220),
    content: (c, w) => _ImWindow(key: ValueKey(key), convKey: key),
  );
}

class _ImWindow extends StatefulWidget {
  const _ImWindow({super.key, required this.convKey});
  final String convKey;

  @override
  State<_ImWindow> createState() => _ImWindowState();
}

class _ImWindowState extends State<_ImWindow> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _inputFocus = FocusNode();
  int _lastCount = -1;
  Timer? _typingTimer;
  bool _sentTyping = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    _input.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  String _name(AppState app) => app.conversations[widget.convKey]?.displayName ?? widget.convKey;

  void _send() {
    final app = context.read<AppState>();
    final text = _input.text.trim();
    if (text.isEmpty) return;
    app.send(_name(app), text);
    _input.clear();
    _typingTimer?.cancel();
    _sentTyping = false;
    _inputFocus.requestFocus();
  }

  void _onTyping(String s) {
    final app = context.read<AppState>();
    if (!_sentTyping && s.isNotEmpty) {
      app.typing(_name(app), 2);
      _sentTyping = true;
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 4), () {
      if (_sentTyping) app.typing(_name(app), s.isEmpty ? 0 : 1);
      _sentTyping = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final conv = app.conversations[widget.convKey];
    final lines = conv?.lines ?? const <ChatLine>[];
    final name = _name(app);
    if (lines.length != _lastCount) {
      _lastCount = lines.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
    final online = app.isBuddyOnline(name);
    final typing = conv?.typing ?? 0;

    return Padding(
      padding: const EdgeInsets.all(6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!online)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('$name is offline. Messages will be sent when $name signs on.',
                style: Xp.text.copyWith(color: const Color(0xFF808080), fontSize: 12)),
          ),
        Expanded(
          flex: 3,
          child: Container(
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Xp.fieldBorder)),
            child: SelectionArea(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(5),
                itemCount: lines.length,
                itemBuilder: (_, i) => _line(app, lines[i]),
              ),
            ),
          ),
        ),
        SizedBox(
          height: 18,
          child: typing > 0
              ? Text(typing == 2 ? '$name is typing...' : '$name has entered text.',
                  style: Xp.text.copyWith(fontSize: 11, color: const Color(0xFF606060)))
              : null,
        ),
        Focus(
          onKeyEvent: (node, e) {
            if (e is KeyDownEvent && isEnter(e.logicalKey) && !HardwareKeyboard.instance.isShiftPressed) {
              _send();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Container(
            height: 76,
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Xp.fieldBorder)),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: TextField(
              controller: _input,
              focusNode: _inputFocus,
              maxLines: null,
              expands: true,
              textInputAction: TextInputAction.send,
              onEditingComplete: _send,
              onChanged: _onTyping,
              style: Xp.text,
              decoration: const InputDecoration(border: InputBorder.none, isDense: true),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          XpButton(label: 'Send', isDefault: true, onPressed: _send),
        ]),
      ]),
    );
  }

  Widget _line(AppState app, ChatLine l) {
    if (l.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Text(l.text, style: Xp.text.copyWith(color: const Color(0xFF808080), fontStyle: FontStyle.italic)),
      );
    }
    final who = l.mine ? app.myScreenName : l.from;
    final nameColor = l.mine ? Xp.imMine : Xp.imTheirs;
    final pending = l.pendingId != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Text.rich(TextSpan(style: Xp.text, children: [
        TextSpan(
            text: l.auto ? '$who <AUTO-RESPONSE>: ' : '$who: ',
            style: TextStyle(color: nameColor, fontWeight: FontWeight.bold)),
        TextSpan(text: l.text, style: pending ? const TextStyle(color: Color(0xFF909090)) : null),
        if (pending) const TextSpan(text: '  (sending...)', style: TextStyle(color: Color(0xFF909090), fontSize: 11)),
      ])),
    );
  }
}

// ======================================================================
// Small AIM dialogs

DeskWindow awayEditorWindow() => DeskWindow(
      id: 'aim:away',
      title: 'Away Message',
      icon: Icons.description,
      size: const Size(320, 260),
      resizable: false,
      canMaximize: false,
      content: (c, w) => const _AwayEditor(),
    );

class _AwayEditor extends StatefulWidget {
  const _AwayEditor();

  @override
  State<_AwayEditor> createState() => _AwayEditorState();
}

class _AwayEditorState extends State<_AwayEditor> {
  final _text = TextEditingController(text: "I'm away from my computer right now.");

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final wm = context.read<WindowManager>();
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Away message:', style: Xp.textBold),
        const SizedBox(height: 4),
        Expanded(child: XpField(controller: _text, autofocus: true, maxLines: null, minLines: 5)),
        const SizedBox(height: 10),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          XpButton(
              label: "I'm Away",
              isDefault: true,
              onPressed: () {
                app.setAway(_text.text.trim().isEmpty ? "I'm away." : _text.text.trim());
                wm.close('aim:away');
              }),
          const SizedBox(width: 6),
          XpButton(label: 'Cancel', onPressed: () => wm.close('aim:away')),
        ]),
      ]),
    );
  }
}

DeskWindow addBuddyWindow() => DeskWindow(
      id: 'aim:addbuddy',
      title: 'Add Buddy',
      icon: Icons.person_add,
      size: const Size(300, 200),
      resizable: false,
      canMaximize: false,
      content: (c, w) => const _AddBuddy(),
    );

class _AddBuddy extends StatefulWidget {
  const _AddBuddy();

  @override
  State<_AddBuddy> createState() => _AddBuddyState();
}

class _AddBuddyState extends State<_AddBuddy> {
  final _sn = TextEditingController();
  String? _group;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final wm = context.read<WindowManager>();
    final groups = app.buddyGroups.map((g) => g.$1).toList();
    if (groups.isEmpty) groups.add('Buddies');
    final group = (_group != null && groups.contains(_group)) ? _group! : groups.first;
    void add() {
      final sn = _sn.text.trim();
      if (sn.isEmpty) return;
      unawaited(app.addBuddy(sn, group));
      wm.close('aim:addbuddy');
    }

    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Screen name:', style: Xp.textBold),
        const SizedBox(height: 4),
        XpField(controller: _sn, autofocus: true, onSubmitted: (_) => add()),
        const SizedBox(height: 8),
        Row(children: [
          const Text('Group: ', style: Xp.text),
          DropdownButton<String>(
            value: group,
            isDense: true,
            style: Xp.text,
            items: [for (final g in groups) DropdownMenuItem(value: g, child: Text(g))],
            onChanged: (v) => setState(() => _group = v),
          ),
        ]),
        const Spacer(),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          XpButton(label: 'Add', isDefault: true, onPressed: add),
          const SizedBox(width: 6),
          XpButton(label: 'Cancel', onPressed: () => wm.close('aim:addbuddy')),
        ]),
      ]),
    );
  }
}

DeskWindow sendImWindow() => DeskWindow(
      id: 'aim:sendim',
      title: 'Send Instant Message',
      icon: Icons.chat,
      size: const Size(300, 160),
      resizable: false,
      canMaximize: false,
      content: (c, w) => const _SendIm(),
    );

class _SendIm extends StatefulWidget {
  const _SendIm();

  @override
  State<_SendIm> createState() => _SendImState();
}

class _SendImState extends State<_SendIm> {
  final _to = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final wm = context.read<WindowManager>();
    final desk = context.read<Desk>();
    void go() {
      final sn = _to.text.trim();
      if (sn.isEmpty) return;
      wm.close('aim:sendim');
      desk.openIm(sn);
    }

    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('To:', style: Xp.textBold),
        const SizedBox(height: 4),
        XpField(controller: _to, autofocus: true, onSubmitted: (_) => go()),
        const Spacer(),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          XpButton(label: 'Send', isDefault: true, onPressed: go),
          const SizedBox(width: 6),
          XpButton(label: 'Cancel', onPressed: () => wm.close('aim:sendim')),
        ]),
      ]),
    );
  }
}
