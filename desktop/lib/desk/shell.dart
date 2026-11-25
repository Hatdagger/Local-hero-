import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app/app_state.dart';
import '../oscar/client.dart';
import 'desk.dart';
import 'desktop_icons.dart';
import 'keys.dart';
import 'media_player.dart' show FullScreenVideo;
import 'network.dart';
import 'platform.dart';
import 'updater.dart';
import 'wallpaper.dart';
import 'window_manager.dart';
import 'xp_theme.dart';
import 'xp_window.dart';

const double kTaskbarHeight = 34;

/// The whole screen: wallpaper, icons, windows, taskbar and popups.
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  late final DeskKeys _keys;

  @override
  void initState() {
    super.initState();
    _keys = DeskKeys(context.read<Desk>());
    HardwareKeyboard.instance.addHandler(_keys.handle);
    DeskPlatform.listenForShortcuts(_keys.external);
    // Once the desktop has its size: reopen last time's windows.
    final desk = context.read<Desk>();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(desk.session.restore()));
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_keys.handle);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wm = context.watch<WindowManager>();
    final wp = context.watch<WallpaperSettings>();
    final desk = context.read<Desk>();

    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(builder: (context, box) {
        wm.desk = Size(box.maxWidth, box.maxHeight - kTaskbarHeight);
        final area = wm.workArea;
        return Stack(children: [
          // Background + icons (tap clears, right-click/long-press = menu)
          Positioned.fill(
            child: DesktopIcons(
              area: area,
              onBackgroundTap: wm.closeStart,
              background: WallpaperView(kind: wp.kind, imagePath: wp.imagePath, position: wp.position, color: wp.color),
            ),
          ),
          // Windows, bottom to top
          Positioned(
            left: 0,
            top: 0,
            width: box.maxWidth,
            height: box.maxHeight - kTaskbarHeight,
            child: Stack(clipBehavior: Clip.none, children: [
              for (final w in wm.zOrder)
                if (!w.minimized) XpWindowFrame(key: ValueKey(w.id), w: w, wm: wm),
            ]),
          ),
          // Alt+Space window menu
          if (wm.menuFor != null && wm.byId(wm.menuFor!) != null) ..._windowMenu(wm),
          // Start menu
          if (wm.startOpen) ...[
            Positioned.fill(child: GestureDetector(onTap: wm.closeStart)),
            const Positioned(left: 0, bottom: kTaskbarHeight, child: StartMenu()),
          ],
          // Alt+Tab
          if (wm.switcherIndex != null) Center(child: _Switcher(wm: wm)),
          // Keyboard move/size hint
          if (wm.kbMode != KbMode.none)
            Positioned(
              left: 0,
              right: 0,
              bottom: kTaskbarHeight + 8,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  color: const Color(0xFFFFFFE1),
                  child: Text(
                    wm.kbMode == KbMode.move
                        ? 'Moving: arrow keys, Enter to finish, Esc to cancel'
                        : 'Sizing: arrow keys, Enter to finish, Esc to cancel',
                    style: Xp.text,
                  ),
                ),
              ),
            ),
          // Pop-ups above the clock ("Bob has signed on.")
          Positioned(right: 8, bottom: kTaskbarHeight + 8, child: ToastStack(toasts: desk.toasts)),
          // Taskbar
          const Positioned(left: 0, right: 0, bottom: 0, height: kTaskbarHeight, child: Taskbar()),
          // Full-screen video, over everything
          const Positioned.fill(child: FullScreenVideo()),
        ]);
      }),
    );
  }

  List<Widget> _windowMenu(WindowManager wm) {
    final w = wm.byId(wm.menuFor!)!;
    final r = wm.shownRect(w);
    final entries = wm.menuEntries(w);
    return [
      Positioned.fill(child: GestureDetector(onTap: wm.closeMenu, onSecondaryTap: wm.closeMenu)),
      Positioned(
        left: (r.left + 4).clamp(0.0, wm.desk.width - 200).toDouble(),
        top: (r.top + kTitleHeight).clamp(0.0, wm.desk.height - 200).toDouble(),
        child: XpMenuPanel(width: 200, children: [
          for (var i = 0; i < entries.length; i++) ...[
            if (entries[i].separatorBefore) const XpMenuSeparator(),
            XpMenuItem(
              label: entries[i].label,
              mnemonic: entries[i].mnemonic,
              shortcut: entries[i].shortcut,
              bold: entries[i].bold,
              highlighted: wm.menuIndex == i,
              icon: switch (entries[i].action) {
                MenuAction.minimize => Icons.minimize,
                MenuAction.maximize => Icons.crop_square,
                MenuAction.restore => Icons.filter_none,
                MenuAction.close => Icons.close,
                _ => null,
              },
              onTap: entries[i].enabled ? () => wm.runMenu(entries[i].action) : null,
            ),
          ],
        ]),
      ),
    ];
  }
}

// ======================================================================
// Alt+Tab

class _Switcher extends StatelessWidget {
  const _Switcher({required this.wm});
  final WindowManager wm;

  @override
  Widget build(BuildContext context) {
    final list = wm.switchList;
    final sel = wm.switcherIndex ?? 0;
    final title = sel < list.length ? list[sel].title : '';
    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFE8EEF9),
        border: Border.all(color: const Color(0xFF3B6CD4), width: 2),
        borderRadius: BorderRadius.circular(4),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 8, offset: Offset(2, 3))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (var i = 0; i < list.length; i++)
            GestureDetector(
              onTap: () {
                wm.switcherIndex = i;
                wm.commitSwitch();
              },
              child: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  border: Border.all(color: i == sel ? Xp.selection : Colors.transparent, width: 2),
                  color: i == sel ? const Color(0xFFC1D2EE) : null,
                ),
                child: Icon(list[i].icon, size: 30, color: const Color(0xFF1E3E9B)),
              ),
            ),
        ]),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Xp.fieldBorder)),
          child: Text(title, style: Xp.text, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ]),
    );
  }
}

// ======================================================================
// Taskbar

class Taskbar extends StatelessWidget {
  const Taskbar({super.key});

  @override
  Widget build(BuildContext context) {
    final wm = context.watch<WindowManager>();
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF5A9BFF), Xp.taskTop, Xp.taskBottom, Color(0xFF1941A5)],
          stops: [0, 0.1, 0.85, 1],
        ),
      ),
      child: Row(children: [
        _StartButton(open: wm.startOpen, onTap: wm.toggleStart),
        const SizedBox(width: 8),
        Expanded(
          child: LayoutBuilder(builder: (c, box) {
            final list = wm.taskOrder;
            final each = list.isEmpty ? 160.0 : (box.maxWidth / list.length).clamp(36.0, 165.0).toDouble();
            return Row(children: [
              for (final w in list)
                _TaskButton(
                  w: w,
                  width: each - 3,
                  active: wm.activeId == w.id && !w.minimized,
                  onTap: () => wm.taskbarClick(w.id),
                  onMenu: () => wm.openMenu(w.id),
                ),
            ]);
          }),
        ),
        const _Tray(),
      ]),
    );
  }
}

class _StartButton extends StatelessWidget {
  const _StartButton({required this.open, required this.onTap});
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: kTaskbarHeight,
        padding: const EdgeInsets.only(left: 10, right: 22),
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.only(topRight: Radius.circular(12), bottomRight: Radius.circular(12)),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: open
                ? const [Color(0xFF2B7F25), Color(0xFF1F6A1A)]
                : const [Color(0xFF6CC35F), Xp.startTop, Xp.startBottom],
          ),
          boxShadow: const [BoxShadow(color: Color(0x55000000), offset: Offset(2, 0), blurRadius: 3)],
        ),
        child: const Row(children: [
          _StartLogo(),
          SizedBox(width: 6),
          Text(
            'start',
            style: TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.bold,
              fontStyle: FontStyle.italic,
              shadows: [Shadow(color: Color(0xFF1C4F18), offset: Offset(1, 1), blurRadius: 1)],
            ),
          ),
        ]),
      ),
    );
  }
}

/// Our own start-button mark: four coloured dots.
class _StartLogo extends StatelessWidget {
  const _StartLogo();

  @override
  Widget build(BuildContext context) {
    Widget dot(Color c) => Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 0.8)),
        );
    return SizedBox(
      width: 20,
      height: 20,
      child: Wrap(spacing: 2, runSpacing: 2, children: [
        dot(const Color(0xFFFF6A3D)),
        dot(const Color(0xFF8BE04E)),
        dot(const Color(0xFF4FB2FF)),
        dot(const Color(0xFFFFD54A)),
      ]),
    );
  }
}

class _TaskButton extends StatelessWidget {
  const _TaskButton({required this.w, required this.width, required this.active, required this.onTap, required this.onMenu});
  final DeskWindow w;
  final double width;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final List<Color> colors;
    if (w.flashing) {
      colors = const [Color(0xFFFFC06A), Xp.flash, Color(0xFFD9791A)];
    } else if (active) {
      colors = const [Color(0xFF1C4DB8), Color(0xFF1E52C0), Color(0xFF2A62D2)];
    } else {
      colors = const [Color(0xFF6FA6FF), Color(0xFF3C81F3), Color(0xFF3172E6)];
    }
    return GestureDetector(
      onTap: onTap,
      onSecondaryTap: onMenu,
      onLongPress: onMenu,
      child: Container(
        width: width,
        height: kTaskbarHeight - 8,
        margin: const EdgeInsets.only(right: 3),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(3),
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: colors),
          border: Border.all(color: active ? const Color(0xFF0F3590) : const Color(0xFF2556C8)),
        ),
        child: Row(children: [
          Icon(w.icon, size: 16, color: Colors.white),
          const SizedBox(width: 5),
          Expanded(
            child: Text(w.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
        ]),
      ),
    );
  }
}

class _Tray extends StatefulWidget {
  const _Tray();

  @override
  State<_Tray> createState() => _TrayState();
}

class _TrayState extends State<_Tray> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 15), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final updater = context.watch<DeskUpdater>();
    final desk = context.read<Desk>();
    final now = TimeOfDay.now();
    final h = now.hourOfPeriod == 0 ? 12 : now.hourOfPeriod;
    final time = '$h:${now.minute.toString().padLeft(2, '0')} ${now.period == DayPeriod.am ? 'AM' : 'PM'}';
    Color aimColor;
    if (app.link == LinkState.online) {
      aimColor = app.isAway ? const Color(0xFFFFE08A) : const Color(0xFFFFD000);
    } else if (app.link == LinkState.connecting || app.link == LinkState.reconnecting) {
      aimColor = const Color(0xFFBBBBBB);
    } else {
      aimColor = const Color(0xFF7A8FB8);
    }
    return Container(
      height: kTaskbarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Xp.trayTop, Xp.trayBottom]),
        border: Border(left: BorderSide(color: Color(0xFF0A5FB0))),
      ),
      child: Row(children: [
        if (updater.available) ...[
          Tooltip(
            message: 'Update ready: build ${updater.latestBuild}',
            child: GestureDetector(
              onTap: desk.openUpdate,
              child: const Icon(Icons.new_releases, size: 17, color: Color(0xFFFFD000)),
            ),
          ),
          const SizedBox(width: 10),
        ],
        ListenableBuilder(
          listenable: NetState.instance,
          builder: (c, _) {
            final net = NetState.instance;
            return Row(children: [
              if (net.btAvailable && net.btOn) ...[
                Tooltip(
                  message: 'Bluetooth',
                  child: GestureDetector(
                    onTap: desk.openBluetooth,
                    child: const Icon(Icons.bluetooth, size: 16, color: Colors.white),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              if (net.wifiAvailable) ...[
                Tooltip(
                  message: !net.wifiOn
                      ? 'Wi-Fi is off'
                      : net.wifiConnected
                          ? 'Connected${net.ssid.isEmpty ? '' : ' to ${net.ssid}'}'
                          : 'Not connected',
                  child: GestureDetector(
                    onTap: desk.openNetwork,
                    child: Icon(wifiIcon(net.bars, on: net.wifiOn, connected: net.wifiConnected),
                        size: 17, color: Colors.white),
                  ),
                ),
                const SizedBox(width: 10),
              ],
            ]);
          },
        ),
        Tooltip(
          message: app.link == LinkState.online ? 'AIM: ${app.myScreenName}' : 'AIM: signed off',
          child: GestureDetector(
            onTap: desk.openAim,
            child: Icon(Icons.chat_bubble, size: 17, color: aimColor),
          ),
        ),
        const SizedBox(width: 10),
        Text(time, style: const TextStyle(color: Colors.white, fontSize: 12)),
      ]),
    );
  }
}

// ======================================================================
// Start menu

class StartMenu extends StatefulWidget {
  const StartMenu({super.key});

  @override
  State<StartMenu> createState() => _StartMenuState();
}

class _StartMenuState extends State<StartMenu> {
  bool _programs = false;

  @override
  Widget build(BuildContext context) {
    final desk = context.read<Desk>();
    final wm = context.read<WindowManager>();
    final app = context.watch<AppState>();
    final apps = context.watch<AppList>();
    final user = app.myScreenName.isEmpty ? 'Desktop User' : app.myScreenName;

    void run(VoidCallback f) {
      wm.closeStart();
      f();
    }

    Widget leftItem(IconData icon, Color color, String title, String? sub, VoidCallback onTap) {
      return _HoverRow(
        onTap: () => run(onTap),
        child: Row(children: [
          Icon(icon, size: 30, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title, style: Xp.textBold),
              if (sub != null) Text(sub, style: Xp.textGrey.copyWith(fontSize: 11)),
            ]),
          ),
        ]),
      );
    }

    Widget rightItem(IconData icon, String title, VoidCallback onTap) {
      return _HoverRow(
        onTap: () => run(onTap),
        child: Row(children: [
          Icon(icon, size: 22, color: const Color(0xFF1E3E9B)),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: Xp.textBold.copyWith(color: const Color(0xFF0A246A)))),
        ]),
      );
    }

    final menu = Container(
      width: 410,
      height: 590,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
        border: Border.all(color: const Color(0xFF1C5CD7), width: 1.5),
        boxShadow: const [BoxShadow(color: Color(0x77000000), blurRadius: 8, offset: Offset(3, 0))],
      ),
      child: Column(children: [
        // Header with the user name
        Container(
          height: 62,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: const BoxDecoration(
            borderRadius: BorderRadius.vertical(top: Radius.circular(7)),
            gradient: LinearGradient(colors: [Color(0xFF1F62D8), Color(0xFF3C8CF5), Color(0xFF1F62D8)]),
          ),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFFFFE36B),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: const Icon(Icons.person, size: 32, color: Color(0xFF1E3E9B)),
            ),
            const SizedBox(width: 10),
            Text(user,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    shadows: [Shadow(color: Color(0xFF0A246A), offset: Offset(1, 1))])),
          ]),
        ),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Left (white)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  leftItem(Icons.public, const Color(0xFF1E7BD8), 'Internet', 'Desk Browser', () => desk.openBrowser()),
                  leftItem(Icons.chat_bubble, const Color(0xFFF5B800), 'Instant Messenger', 'AIM', desk.openAim),
                  leftItem(Icons.auto_awesome, const Color(0xFFE8875B), 'Claude', 'claude.ai', desk.openClaude),
                  const XpMenuSeparator(),
                  leftItem(Icons.play_circle, const Color(0xFF3DAA4E), 'Media Player', 'music and videos', desk.openMediaPlayer),
                  leftItem(Icons.music_note, const Color(0xFFE07A1F), 'Mini Player', null, desk.openMiniPlayer),
                  leftItem(Icons.celebration, const Color(0xFFD94F8C), 'Penis Music', 'live remixer', desk.openPenisMusic),
                  leftItem(Icons.description, const Color(0xFF4A6FB5), 'Notepad', null, desk.openNotepad),
                  leftItem(Icons.style, const Color(0xFF2E7D32), 'Solitaire', null, desk.openSolitaire),
                  const XpMenuSeparator(),
                  leftItem(Icons.play_circle_fill, Xp.selection, 'Run...', null, desk.openRun),
                  leftItem(Icons.desktop_windows, Xp.selection, 'Display Properties', null, desk.openDisplay),
                  const Spacer(),
                  const XpMenuSeparator(),
                  _HoverRow(
                    highlighted: _programs,
                    onTap: () {
                      apps.load();
                      setState(() => _programs = !_programs);
                    },
                    child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Text('All Programs', style: Xp.textBold),
                      SizedBox(width: 6),
                      Icon(Icons.play_arrow, size: 18, color: Color(0xFF2E9A2A)),
                    ]),
                  ),
                ]),
              ),
            ),
            // Right (light blue)
            Container(
              width: 170,
              decoration: const BoxDecoration(
                color: Xp.menuBlue,
                border: Border(left: BorderSide(color: Color(0xFF95BDEE))),
              ),
              padding: const EdgeInsets.all(6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                rightItem(Icons.folder_special, 'My Documents', desk.openMyDocuments),
                rightItem(Icons.computer, 'My Computer', () => desk.openExplorer()),
                rightItem(Icons.download, 'Downloads', desk.openDownloads),
                rightItem(Icons.delete_outline, 'Recycle Bin', desk.openRecycleBin),
                const XpMenuSeparator(),
                rightItem(Icons.wifi, 'Wireless Networks', desk.openNetwork),
                rightItem(Icons.bluetooth, 'Bluetooth Devices', desk.openBluetooth),
                const XpMenuSeparator(),
                rightItem(Icons.shield, 'Brave', () => desk.openBrave()),
                rightItem(Icons.settings, 'Android Settings', () => DeskPlatform.launch('com.android.settings')),
                rightItem(Icons.home, 'Choose Home Screen', DeskPlatform.homeSettings),
                rightItem(Icons.wallpaper, 'Wallpaper', desk.openDisplay),
                rightItem(Icons.security_update_good, 'Desktop Update', desk.openUpdate),
              ]),
            ),
          ]),
        ),
        // Bottom bar
        Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Color(0xFF1F62D8), Color(0xFF3C8CF5), Color(0xFF1F62D8)]),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            _BottomButton(icon: Icons.key, color: const Color(0xFFF5A623), label: 'Log Off', onTap: desk.confirmLogOff),
            const SizedBox(width: 14),
            _BottomButton(
                icon: Icons.power_settings_new, color: const Color(0xFFD9441C), label: 'Shut Down', onTap: desk.confirmShutDown),
          ]),
        ),
      ]),
    );

    return Row(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
      menu,
      if (_programs)
        Container(
          width: 280,
          height: 420,
          margin: const EdgeInsets.only(bottom: 42),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border.fromBorderSide(BorderSide(color: Color(0xFF8BA9D8))),
            boxShadow: [BoxShadow(color: Color(0x66000000), blurRadius: 5, offset: Offset(2, 2))],
          ),
          child: !apps.loaded
              ? const Center(child: Text('Loading...', style: Xp.textGrey))
              : ListView(children: [
                  for (final a in apps.apps)
                    _HoverRow(
                      onTap: () => run(() => DeskPlatform.launch(a.package)),
                      onMenu: (at) => xpPopup(context, at, [
                        XpPopupItem('Open', () => run(() => DeskPlatform.launch(a.package)), bold: true),
                        XpPopupItem('Send To Desktop (create shortcut)', () {
                          final dir = desk.desktop.dir;
                          if (dir == null) return;
                          ShortcutFile.create(dir, a.label, app: a.package).then((_) => desk.desktop.refresh());
                        }),
                      ]),
                      child: Row(children: [
                        SizedBox(
                          width: 22,
                          height: 22,
                          child: a.icon.isEmpty ? const Icon(Icons.apps, size: 20) : Image.memory(a.icon),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(a.label, style: Xp.text, overflow: TextOverflow.ellipsis)),
                      ]),
                    ),
                ]),
        ),
    ]);
  }
}

class _BottomButton extends StatelessWidget {
  const _BottomButton({required this.icon, required this.color, required this.label, required this.onTap});
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Row(children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: Colors.white),
          ),
          child: Icon(icon, size: 16, color: Colors.white),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
      ]),
    );
  }
}

class _HoverRow extends StatefulWidget {
  const _HoverRow({required this.child, required this.onTap, this.highlighted = false, this.onMenu});
  final Widget child;
  final VoidCallback onTap;
  final bool highlighted;
  final void Function(Offset global)? onMenu;

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final hi = _hover || widget.highlighted;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTapUp: widget.onMenu == null ? null : (d) => widget.onMenu!(d.globalPosition),
        onLongPressStart: widget.onMenu == null ? null : (d) => widget.onMenu!(d.globalPosition),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          color: hi ? const Color(0xFFC1D2EE) : Colors.transparent,
          child: widget.child,
        ),
      ),
    );
  }
}
