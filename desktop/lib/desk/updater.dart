import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../app/platform_bridge.dart';
import 'window_manager.dart';
import 'xp_theme.dart';

/// This copy's build number (GitHub Actions run number), 0 for local builds.
const int kDeskBuild = int.fromEnvironment('DESK_BUILD');
const String _base = 'https://github.com/Hatdagger/Local-hero-/releases/download/desktop-latest';

enum UpdateStep { idle, needsPermission, downloading, installing, failed }

/// Checks the "desktop-latest" release on GitHub and installs newer builds
/// from inside the desktop. Android restarts the desktop once it's in.
class DeskUpdater extends ChangeNotifier {
  Timer? _timer;
  int? latestBuild;
  String? latestDate;
  bool checking = false;
  String? error;
  UpdateStep step = UpdateStep.idle;
  double progress = 0;
  String? problem;
  File? _apk;

  bool get available => kDeskBuild > 0 && (latestBuild ?? 0) > kDeskBuild;
  bool get busy => step == UpdateStep.downloading || step == UpdateStep.installing;

  void start() {
    check();
    _timer = Timer.periodic(const Duration(hours: 2), (_) => check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> check() async {
    if (checking) return;
    checking = true;
    error = null;
    notifyListeners();
    try {
      final r = await http
          .get(Uri.parse('$_base/desk-version.json?t=${DateTime.now().millisecondsSinceEpoch}'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw 'GitHub answered ${r.statusCode}';
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      latestBuild = (j['build'] as num?)?.toInt();
      latestDate = j['date'] as String?;
    } catch (e) {
      error = "Couldn't check for updates: $e";
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  void _to(UpdateStep s, {String? why}) {
    step = s;
    problem = why;
    notifyListeners();
  }

  Future<void> install() async {
    if (busy) return;
    PlatformBridge.onInstallFailed = (m) => _to(UpdateStep.failed, why: "Android didn't install it ($m).");
    try {
      if (!await PlatformBridge.canInstallUpdates()) {
        // One-time Android switch ("Allow from this source"); carry on after.
        _to(UpdateStep.needsPermission);
        PlatformBridge.onResumed = () async {
          if (step != UpdateStep.needsPermission) return;
          if (await PlatformBridge.canInstallUpdates()) {
            PlatformBridge.onResumed = null;
            step = UpdateStep.idle;
            unawaited(install());
          }
        };
        await PlatformBridge.allowInstallUpdates();
        return;
      }
      final file = _apk != null && await _apk!.exists() ? _apk! : await _download();
      _apk = file;
      _to(UpdateStep.installing);
      await PlatformBridge.installApk(file.path);
      // If Android shows its box and it's dismissed, the button works again.
      Timer(const Duration(seconds: 6), () {
        if (step == UpdateStep.installing) _to(UpdateStep.idle);
      });
    } catch (e) {
      _to(UpdateStep.failed, why: "The update didn't finish: $e");
    }
  }

  Future<File> _download() async {
    progress = 0;
    _to(UpdateStep.downloading);
    final dir = await getTemporaryDirectory();
    final out = File('${dir.path}/ClassicDesk-${latestBuild ?? 0}.apk');
    final client = http.Client();
    try {
      final resp = await client
          .send(http.Request('GET', Uri.parse('$_base/ClassicDesk.apk')))
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) throw 'GitHub answered ${resp.statusCode}';
      final total = resp.contentLength ?? 0;
      final sink = out.openWrite();
      var got = 0;
      var shown = 0.0;
      try {
        await for (final chunk in resp.stream.timeout(const Duration(seconds: 60))) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) {
            progress = got / total;
            if (progress - shown >= 0.01) {
              shown = progress;
              notifyListeners();
            }
          }
        }
      } finally {
        await sink.close();
      }
      if (got < 1024 || (total > 0 && got != total)) throw 'the download was cut short';
      progress = 1;
      return out;
    } finally {
      client.close();
    }
  }
}

DeskWindow updateWindow() => DeskWindow(
      id: 'update',
      title: 'Desktop Update',
      icon: Icons.security_update_good,
      size: const Size(380, 250),
      resizable: false,
      canMaximize: false,
      content: (c, w) => const _UpdatePanel(),
    );

class _UpdatePanel extends StatelessWidget {
  const _UpdatePanel();

  @override
  Widget build(BuildContext context) {
    final u = context.watch<DeskUpdater>();
    final String status;
    if (kDeskBuild == 0) {
      status = 'This is a test build without a version number, so it can\'t tell what is newer.';
    } else if (u.checking) {
      status = 'Checking for updates...';
    } else if (u.error != null) {
      status = u.error!;
    } else if (u.available) {
      status = 'A new version is ready: build ${u.latestBuild}${u.latestDate == null ? '' : ' (${u.latestDate})'}.';
    } else {
      status = 'You have the newest version.';
    }
    String? stepText;
    switch (u.step) {
      case UpdateStep.needsPermission:
        stepText = 'Allow ClassicDesk to install updates in the Android screen that opened, then come back.';
      case UpdateStep.downloading:
        stepText = 'Downloading... ${(u.progress * 100).round()}%';
      case UpdateStep.installing:
        stepText = 'Installing. The desktop will close and start again as the new version.';
      case UpdateStep.failed:
        stepText = u.problem;
      case UpdateStep.idle:
        stepText = null;
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(u.available ? Icons.new_releases : Icons.verified, size: 34, color: u.available ? Xp.flash : const Color(0xFF2E9A2A)),
          const SizedBox(width: 10),
          Expanded(child: Text(status, style: Xp.text)),
        ]),
        const SizedBox(height: 8),
        Text('Installed: build ${kDeskBuild == 0 ? '(unknown)' : kDeskBuild}', style: Xp.textGrey),
        const SizedBox(height: 8),
        if (stepText != null) Text(stepText, style: Xp.text),
        if (u.step == UpdateStep.downloading) ...[
          const SizedBox(height: 6),
          LinearProgressIndicator(value: u.progress, minHeight: 10, color: const Color(0xFF2EA62A), backgroundColor: Colors.white),
        ],
        const Spacer(),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          XpButton(label: 'Check Now', onPressed: u.checking || u.busy ? null : u.check),
          const SizedBox(width: 6),
          XpButton(
            label: 'Install Update',
            isDefault: true,
            onPressed: u.available && !u.busy ? u.install : null,
          ),
        ]),
      ]),
    );
  }
}
