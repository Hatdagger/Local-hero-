import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app/app_state.dart';
import 'app/input_mode.dart';
import 'app/settings.dart';
import 'desk/desk.dart';
import 'desk/network.dart';
import 'desk/platform.dart';
import 'desk/shell.dart';
import 'desk/updater.dart';
import 'desk/wallpaper.dart';
import 'desk/window_manager.dart';
import 'desk/xp_theme.dart';
import 'desk/xp_window.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = AppSettings();
  await settings.load();
  final input = InputMode(settings);
  final app = AppState(settings, input);
  final wallpaper = WallpaperSettings();
  await wallpaper.load();
  final wm = WindowManager();
  final apps = AppList();
  final desk = Desk(wm, app, apps);
  final updater = DeskUpdater()..start();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: input),
        ChangeNotifierProvider.value(value: app),
        ChangeNotifierProvider.value(value: wallpaper),
        ChangeNotifierProvider.value(value: wm),
        ChangeNotifierProvider.value(value: apps),
        ChangeNotifierProvider.value(value: updater),
        Provider.value(value: desk),
        ChangeNotifierProvider.value(value: desk.desktop),
      ],
      child: const DeskApp(),
    ),
  );
  apps.load();
  if (settings.server.isNotEmpty && settings.autoLoginAccount != null) {
    await app.tryAutoLogin();
  }
}

class DeskApp extends StatefulWidget {
  const DeskApp({super.key});

  @override
  State<DeskApp> createState() => _DeskAppState();
}

class _DeskAppState extends State<DeskApp> {
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _life = AppLifecycleListener(onStateChange: (s) {
      app.setForeground(s == AppLifecycleState.resumed || s == AppLifecycleState.inactive);
      if (s == AppLifecycleState.resumed) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        context.read<AppList>().load(force: true);
        context.read<Desk>().desktop.load();
        NetState.instance.refresh();
      }
    });
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClassicDesk',
      debugShowCheckedModeBanner: false,
      theme: Xp.theme(),
      home: const NoBack(child: Scaffold(backgroundColor: Colors.black, body: DesktopShell())),
    );
  }
}
