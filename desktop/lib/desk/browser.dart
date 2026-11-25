import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../app/platform_bridge.dart';
import 'desk.dart';
import 'explorer.dart';
import 'file_dialog.dart';
import 'files.dart';
import 'platform.dart';
import 'window_manager.dart';
import 'xp_theme.dart';

const kBravePackage = 'com.brave.browser';
const kHomePage = 'https://duckduckgo.com/';

const _desktopUa =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const _mobileUa =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

// ======================================================================
// Ad blocking

/// Well-known ad and tracker servers. Pages and frames from these are not
/// loaded, and the page script below removes their boxes.
const kAdHosts = <String>{
  'doubleclick.net', 'googlesyndication.com', 'googleadservices.com', 'adservice.google.com',
  'pagead2.googlesyndication.com', 'googletagservices.com', 'adnxs.com', 'taboola.com', 'outbrain.com',
  'criteo.com', 'criteo.net', 'pubmatic.com', 'rubiconproject.com', 'openx.net', 'amazon-adsystem.com',
  'scorecardresearch.com', 'zedo.com', 'adsrvr.org', 'advertising.com', 'moatads.com', 'popads.net',
  'popcash.net', 'propellerads.com', 'exoclick.com', 'mgid.com', 'revcontent.com', 'yieldmo.com', 'media.net',
  'adform.net', 'smartadserver.com', 'casalemedia.com', '33across.com', 'sharethrough.com', 'teads.tv',
  'bidswitch.net', 'adcolony.com', 'applovin.com', 'inmobi.com', 'smaato.net', 'serving-sys.com',
  'adroll.com', 'quantserve.com', 'zergnet.com', 'adblade.com', 'trafficjunky.net', 'juicyads.com',
  'hilltopads.net', 'adsterra.com', 'onclickads.net', 'clickadu.com', 'ad.plus', 'adskeeper.com',
  'lijit.com', 'sovrn.com', 'contextweb.com', 'indexww.com', 'gumgum.com', 'triplelift.com',
};

bool isAdHost(String host) {
  var h = host.toLowerCase();
  while (true) {
    if (kAdHosts.contains(h)) return true;
    final i = h.indexOf('.');
    if (i < 0) return false;
    h = h.substring(i + 1);
    if (!h.contains('.')) return false;
  }
}

String _adJs() {
  final hosts = jsonEncode(kAdHosts.toList());
  return '''
(function () {
  if (window.__deskAdBlock) return;
  window.__deskAdBlock = true;
  var hosts = $hosts;
  function bad(src) {
    if (!src) return false;
    try { var h = new URL(src, location.href).hostname.toLowerCase(); } catch (e) { return false; }
    for (var i = 0; i < hosts.length; i++) {
      var d = hosts[i];
      if (h === d || h.endsWith('.' + d)) return true;
    }
    return false;
  }
  var css = 'ins.adsbygoogle,[id^="google_ads"],[id^="div-gpt-ad"],[class*="taboola"],[id*="taboola"],' +
    '[class*="outbrain"],[id*="outbrain"],.adsbox,.ad-slot,.ad-container,.advertisement,.ad-banner,' +
    '[aria-label="Advertisement"],[data-ad-slot],[data-google-query-id],amp-ad,amp-embed' +
    '{display:none !important}';
  var st = document.createElement('style');
  st.textContent = css;
  (document.head || document.documentElement).appendChild(st);
  function sweep() {
    var els = document.querySelectorAll('iframe[src],script[src],img[src]');
    for (var i = 0; i < els.length; i++) {
      if (bad(els[i].getAttribute('src'))) els[i].remove();
    }
  }
  sweep();
  var pending = false;
  new MutationObserver(function () {
    if (pending) return;
    pending = true;
    setTimeout(function () { pending = false; sweep(); }, 300);
  }).observe(document.documentElement, { childList: true, subtree: true });
  var open = window.open;
  window.open = function (u) {
    if (bad(u)) return null;
    return open.apply(window, arguments);
  };
})();
''';
}

// ======================================================================
// Settings shared by all browser windows: bookmarks, home page, ad blocking

class BrowserSettings extends ChangeNotifier {
  BrowserSettings._() {
    _load();
  }
  static final instance = BrowserSettings._();

  List<(String, String)> bookmarks = [];
  String home = kHomePage;
  bool adBlock = true;

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    home = p.getString('browser.home') ?? kHomePage;
    adBlock = p.getBool('browser.adblock') ?? true;
    final raw = p.getString('browser.bookmarks');
    if (raw != null) {
      try {
        bookmarks = (jsonDecode(raw) as List<dynamic>)
            .map((e) => (e['t'] as String? ?? '', e['u'] as String? ?? ''))
            .where((b) => b.$2.isNotEmpty)
            .toList();
      } catch (_) {}
    } else {
      bookmarks = [
        ('DuckDuckGo', 'https://duckduckgo.com/'),
        ('Wikipedia', 'https://en.wikipedia.org/'),
        ('GitHub - Hatdagger', 'https://github.com/Hatdagger'),
      ];
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('browser.bookmarks', jsonEncode([for (final (t, u) in bookmarks) {'t': t, 'u': u}]));
    await p.setString('browser.home', home);
    await p.setBool('browser.adblock', adBlock);
  }

  bool isBookmarked(String url) => bookmarks.any((b) => b.$2 == url);

  void toggleBookmark(String title, String url) {
    if (isBookmarked(url)) {
      bookmarks.removeWhere((b) => b.$2 == url);
    } else {
      bookmarks.add((title.isEmpty ? url : title, url));
    }
    notifyListeners();
    _save();
  }

  void removeBookmark(String url) {
    bookmarks.removeWhere((b) => b.$2 == url);
    notifyListeners();
    _save();
  }

  void setHome(String url) {
    home = url;
    notifyListeners();
    _save();
  }

  void setAdBlock(bool on) {
    adBlock = on;
    notifyListeners();
    _save();
  }
}

// ======================================================================
// Downloads

enum DlState { running, done, failed, cancelled }

class DownloadItem {
  DownloadItem(this.url, this.name, this.path);
  final String url;
  final String name;
  final String path;
  int received = 0;
  int? total;
  DlState state = DlState.running;
  String? error;
  bool _cancel = false;
}

/// Files the browser saved into Downloads.
class Downloads extends ChangeNotifier {
  Downloads._();
  static final instance = Downloads._();

  final List<DownloadItem> items = [];

  /// The Downloads folder (the device's own one when the desktop may write
  /// there, otherwise "My Downloads" in the desktop's storage).
  static Future<String> folder() async {
    await Places.init();
    if (Places.hasAccess) {
      final d = Directory(Places.downloads);
      try {
        await d.create(recursive: true);
        return d.path;
      } catch (_) {}
    }
    final docs = await myDocuments();
    final d = Directory('${parentOf(docs.path)}/My Downloads');
    await d.create(recursive: true);
    return d.path;
  }

  static String nameFromUrl(String url, {String? disposition}) {
    if (disposition != null) {
      final m = RegExp(r'''filename\*?=(?:UTF-8'')?"?([^";]+)"?''', caseSensitive: false).firstMatch(disposition);
      if (m != null) return Uri.decodeComponent(m.group(1)!.trim());
    }
    final u = Uri.tryParse(url);
    final last = u == null || u.pathSegments.isEmpty ? '' : u.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
    return last.isEmpty ? 'download' : last;
  }

  Future<void> start(String url, {String? userAgent}) async {
    final dir = await folder();
    final client = http.Client();
    DownloadItem? item;
    try {
      final req = http.Request('GET', Uri.parse(url));
      if (userAgent != null) req.headers['User-Agent'] = userAgent;
      final res = await client.send(req);
      if (res.statusCode >= 400) throw HttpException('Server said ${res.statusCode}');
      var name = nameFromUrl(url, disposition: res.headers['content-disposition']);
      name = name.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
      name = freeName(dir, name, copySuffix: false);
      item = DownloadItem(url, name, '$dir/$name')..total = res.contentLength;
      items.insert(0, item);
      notifyListeners();
      final sink = File(item.path).openWrite();
      var last = DateTime.now();
      try {
        await for (final chunk in res.stream) {
          if (item._cancel) break;
          sink.add(chunk);
          item.received += chunk.length;
          if (DateTime.now().difference(last).inMilliseconds > 250) {
            last = DateTime.now();
            notifyListeners();
          }
        }
      } finally {
        await sink.close();
      }
      if (item._cancel) {
        item.state = DlState.cancelled;
        try {
          await File(item.path).delete();
        } catch (_) {}
      } else {
        item.state = DlState.done;
        unawaited(PlatformBridge.scanFile(item.path));
        FsEvents.instance.changed();
      }
    } catch (e) {
      if (item == null) {
        item = DownloadItem(url, nameFromUrl(url), '')..state = DlState.failed;
        items.insert(0, item);
      }
      item.state = DlState.failed;
      item.error = e is HttpException ? e.message : '$e';
    } finally {
      client.close();
      notifyListeners();
    }
  }

  void cancel(DownloadItem i) {
    i._cancel = true;
  }

  void clearFinished() {
    items.removeWhere((i) => i.state != DlState.running);
    notifyListeners();
  }
}

const _downloadExts = {
  'apk', 'apks', 'xapk', 'zip', '7z', 'rar', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'iso', 'exe', 'msi', 'dmg', 'deb',
  'rpm', 'appimage', 'bin', 'img', 'pdf', 'mp3', 'flac', 'ogg', 'opus', 'm4a', 'wav', 'mp4', 'mkv', 'webm', 'avi',
  'mov', 'epub', 'cbz', 'cbr', 'torrent', 'docx', 'xlsx', 'pptx', 'odt', 'ods', 'chd', 'cue', 'nes', 'sfc', 'gba',
};

bool _looksLikeDownload(Uri u) {
  if (u.scheme != 'http' && u.scheme != 'https') return false;
  final last = u.pathSegments.isEmpty ? '' : u.pathSegments.last;
  return _downloadExts.contains(extOf(last));
}

DeskWindow downloadsWindow() => DeskWindow(
      id: 'downloads',
      title: 'Downloads',
      icon: Icons.download,
      size: const Size(520, 360),
      minSize: const Size(320, 200),
      content: (c, w) => const _DownloadsView(),
    );

class _DownloadsView extends StatelessWidget {
  const _DownloadsView();

  @override
  Widget build(BuildContext context) {
    final desk = context.read<Desk>();
    return ListenableBuilder(
      listenable: Downloads.instance,
      builder: (c, _) {
        final items = Downloads.instance.items;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Xp.fieldBorder)),
              child: items.isEmpty
                  ? const Center(child: Text('No downloads yet.', style: Xp.textGrey))
                  : ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (c, i) => const Divider(height: 1),
                      itemBuilder: (c, i) {
                        final d = items[i];
                        final (icon, color) = iconFor(kindOf(d.name));
                        final pct = d.total == null || d.total == 0 ? null : d.received / d.total!;
                        final status = switch (d.state) {
                          DlState.running =>
                            '${formatSize(d.received)}${d.total != null ? ' of ${formatSize(d.total!)}' : ''}',
                          DlState.done => 'Done - ${formatSize(d.received)}',
                          DlState.failed => 'Failed: ${d.error ?? ''}',
                          DlState.cancelled => 'Cancelled',
                        };
                        return Padding(
                          padding: const EdgeInsets.all(6),
                          child: Row(children: [
                            Icon(icon, color: color, size: 28),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(d.name, style: Xp.textBold, overflow: TextOverflow.ellipsis),
                                if (d.state == DlState.running)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 3),
                                    child: LinearProgressIndicator(value: pct, minHeight: 6),
                                  ),
                                Text(status, style: Xp.textGrey.copyWith(fontSize: 11), overflow: TextOverflow.ellipsis),
                              ]),
                            ),
                            const SizedBox(width: 6),
                            if (d.state == DlState.running)
                              XpButton(label: 'Cancel', minWidth: 60, onPressed: () => Downloads.instance.cancel(d)),
                            if (d.state == DlState.done) ...[
                              XpButton(label: 'Open', minWidth: 50, onPressed: () => openFileOnDesk(desk, d.path)),
                              const SizedBox(width: 4),
                              XpButton(label: 'Folder', minWidth: 50, onPressed: () => desk.openExplorer(parentOf(d.path))),
                            ],
                          ]),
                        );
                      },
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(children: [
              XpButton(
                label: 'Open Downloads Folder',
                minWidth: 150,
                onPressed: () async => desk.openExplorer(await Downloads.folder()),
              ),
              const Spacer(),
              XpButton(label: 'Clear List', onPressed: Downloads.instance.clearFinished),
            ]),
          ),
        ]);
      },
    );
  }
}

// ======================================================================
// The browser window

int _browserCount = 0;

/// Keyboard shortcuts typed while a web page has the keyboard arrive here,
/// for the active browser window (window id -> handler).
final Map<String, void Function(String name)> browserKeyHandlers = {};

DeskWindow browserWindow({String? url}) {
  final id = 'browser:${_browserCount++}';
  return DeskWindow(
    id: id,
    title: 'Internet',
    icon: Icons.public,
    size: const Size(1000, 680),
    minSize: const Size(420, 300),
    content: (c, w) => _Browser(w: w, startUrl: url),
  );
}

class _Tab {
  _Tab(this.c, this.url);
  final WebViewController c;
  String url;
  String title = 'New Tab';
  bool loading = true;
  int progress = 0;
  bool canBack = false;
  bool canForward = false;
  bool mobile = false;
}

class _Browser extends StatefulWidget {
  const _Browser({required this.w, this.startUrl});
  final DeskWindow w;
  final String? startUrl;

  @override
  State<_Browser> createState() => _BrowserState();
}

class _BrowserState extends State<_Browser> {
  final List<_Tab> _tabs = [];
  int _active = 0;
  final _addr = TextEditingController();
  final _addrFocus = FocusNode();
  final _settings = BrowserSettings.instance;
  String? _blockedNote;

  _Tab get _tab => _tabs[_active];
  Desk get _desk => context.read<Desk>();

  @override
  void initState() {
    super.initState();
    _settings.addListener(_repaint);
    browserKeyHandlers[widget.w.id] = _external;
    _newTab(widget.startUrl);
  }

  @override
  void dispose() {
    _settings.removeListener(_repaint);
    browserKeyHandlers.remove(widget.w.id);
    _addr.dispose();
    _addrFocus.dispose();
    super.dispose();
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  void _external(String name) {
    switch (name) {
      case 'ctrlT':
        _newTab(null);
      case 'ctrlW':
        _closeTab(_active);
      case 'ctrlL':
        _focusAddress();
      case 'f5':
        _tab.c.reload();
      case 'altLeft':
        _tab.c.goBack();
      case 'altRight':
        _tab.c.goForward();
    }
  }

  void _focusAddress() {
    DeskPlatform.focusDesktop();
    _addrFocus.requestFocus();
    _addr.selection = TextSelection(baseOffset: 0, extentOffset: _addr.text.length);
  }

  // ------------------------------------------------------------ tabs

  void _newTab(String? url) {
    final start = url ?? _settings.home;
    late final _Tab t;
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_desktopUa)
      ..setBackgroundColor(Colors.white);
    t = _Tab(c, start);
    c.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: (r) => _onRequest(t, r),
      onPageStarted: (u) => _update(t, url: u, loading: true),
      onProgress: (p) => _update(t, progress: p),
      onPageFinished: (u) async {
        if (_settings.adBlock) {
          try {
            await c.runJavaScript(_adJs());
          } catch (_) {}
        }
        String? title;
        try {
          title = await c.getTitle();
        } catch (_) {}
        _update(t, url: u, loading: false, title: title);
      },
      onUrlChange: (ch) => _update(t, url: ch.url),
      onWebResourceError: (e) {
        if (e.isForMainFrame == true) _update(t, loading: false);
      },
    ));
    c.loadRequest(Uri.parse(start));
    setState(() {
      _tabs.add(t);
      _active = _tabs.length - 1;
      _addr.text = start;
    });
    if (url == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusAddress();
      });
    }
  }

  void _closeTab(int i) {
    if (_tabs.length == 1) {
      context.read<WindowManager>().close(widget.w.id);
      return;
    }
    setState(() {
      _tabs.removeAt(i);
      if (_active >= _tabs.length) _active = _tabs.length - 1;
      if (i < _active) _active--;
      _addr.text = _tab.url;
    });
    _syncTitle();
  }

  void _select(int i) {
    setState(() {
      _active = i;
      _addr.text = _tab.url;
    });
    _syncTitle();
  }

  Future<void> _update(_Tab t, {String? url, bool? loading, int? progress, String? title}) async {
    if (!mounted) return;
    var back = t.canBack, fwd = t.canForward;
    try {
      back = await t.c.canGoBack();
      fwd = await t.c.canGoForward();
    } catch (_) {}
    if (!mounted || !_tabs.contains(t)) return;
    setState(() {
      if (url != null) t.url = url;
      if (loading != null) t.loading = loading;
      if (progress != null) t.progress = progress;
      if (title != null && title.isNotEmpty) t.title = title;
      if (title == null && url != null && t.title == 'New Tab') t.title = Uri.tryParse(url)?.host ?? url;
      t.canBack = back;
      t.canForward = fwd;
      if (identical(t, _tab) && url != null && !_addrFocus.hasFocus) _addr.text = t.url;
    });
    if (identical(t, _tab)) _syncTitle();
  }

  void _syncTitle() {
    final t = _tab.title;
    context.read<WindowManager>().setTitle(widget.w.id, t.isEmpty || t == 'New Tab' ? 'Internet' : '$t - Internet');
  }

  NavigationDecision _onRequest(_Tab t, NavigationRequest r) {
    final u = Uri.tryParse(r.url);
    if (u == null) return NavigationDecision.navigate;
    if (_settings.adBlock && u.host.isNotEmpty && isAdHost(u.host)) {
      if (r.isMainFrame) {
        setState(() => _blockedNote = 'Blocked a jump to an ad site (${u.host}).');
        Future.delayed(const Duration(seconds: 4), () {
          if (mounted) setState(() => _blockedNote = null);
        });
      }
      return NavigationDecision.prevent;
    }
    const web = {'http', 'https', 'file', 'about', 'data', 'javascript', 'blob'};
    if (!web.contains(u.scheme)) {
      // mailto:, tel:, market:, intent: ... go to Android.
      unawaited(PlatformBridge.openUrl(r.url));
      return NavigationDecision.prevent;
    }
    if (r.isMainFrame && _looksLikeDownload(u)) {
      _download(r.url, t);
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  void _download(String url, _Tab? t) {
    unawaited(Downloads.instance.start(url, userAgent: t?.mobile == true ? _mobileUa : _desktopUa));
    context.read<WindowManager>().open(downloadsWindow());
  }

  // ------------------------------------------------------------ address bar

  void _go([String? typed]) {
    final text = (typed ?? _addr.text).trim();
    if (text.isEmpty) return;
    final url = toUrl(text);
    _tab.c.loadRequest(Uri.parse(url));
    _addr.text = url;
    _tab.url = url;
    setState(() {});
  }

  /// Address bar text to a web address: a URL, a host name, or a search.
  static String toUrl(String text) {
    if (RegExp(r'^[a-z][a-z0-9+.-]*:', caseSensitive: false).hasMatch(text) && !text.contains(' ')) {
      return text;
    }
    final hostLike = !text.contains(' ') &&
        (RegExp(r'^[\w-]+(\.[\w-]+)+(:\d+)?(/.*)?$').hasMatch(text) || text.startsWith('localhost'));
    if (hostLike) return 'https://$text';
    return 'https://duckduckgo.com/?q=${Uri.encodeQueryComponent(text)}';
  }

  Future<void> _toggleMobile() async {
    final t = _tab;
    t.mobile = !t.mobile;
    await t.c.setUserAgent(t.mobile ? _mobileUa : _desktopUa);
    await t.c.reload();
    setState(() {});
  }

  Future<void> _openInBrave() async {
    final url = _tab.url;
    await openBraveWindow(_desk, url: url.startsWith('http') ? url : null);
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final wm = context.read<WindowManager>();
    final t = _tab;
    final starred = _settings.isBookmarked(t.url);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyT, control: true): () => _newTab(null),
        const SingleActivator(LogicalKeyboardKey.keyW, control: true): () => _closeTab(_active),
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): _focusAddress,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => _desk.openBrowser(),
        const SingleActivator(LogicalKeyboardKey.f5): () => _tab.c.reload(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () => _tab.c.goBack(),
        const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): () => _tab.c.goForward(),
      },
      child: Focus(
        autofocus: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      XpMenuBar(menus: [
        (
          'File',
          [
            MenuBarEntry('New Tab', () => _newTab(null), shortcut: 'Ctrl+T'),
            MenuBarEntry('New Window', () => _desk.openBrowser(), shortcut: 'Ctrl+N'),
            MenuBarEntry('Open in Brave', _openInBrave),
            const MenuBarEntry.separator(),
            MenuBarEntry('Download This Address', t.url.startsWith('http') ? () => _download(t.url, t) : null),
            MenuBarEntry('Downloads', () => wm.open(downloadsWindow())),
            const MenuBarEntry.separator(),
            MenuBarEntry('Close Tab', () => _closeTab(_active), shortcut: 'Ctrl+W'),
            MenuBarEntry('Close', () => wm.close(widget.w.id)),
          ]
        ),
        (
          'View',
          [
            MenuBarEntry('Reload', () => t.c.reload(), shortcut: 'F5'),
            MenuBarEntry('Mobile Site', _toggleMobile, checked: t.mobile),
          ]
        ),
        (
          'Favorites',
          [
            MenuBarEntry(starred ? 'Remove from Favorites' : 'Add to Favorites...',
                () => _settings.toggleBookmark(t.title, t.url)),
            const MenuBarEntry.separator(),
            for (final (title, url) in _settings.bookmarks) MenuBarEntry(title, () => _go(url)),
          ]
        ),
        (
          'Tools',
          [
            MenuBarEntry('Block Ads', () => _settings.setAdBlock(!_settings.adBlock), checked: _settings.adBlock),
            MenuBarEntry('Use This Page as Home Page', t.url.startsWith('http') ? () => _settings.setHome(t.url) : null),
            MenuBarEntry('Open in Brave', _openInBrave),
          ]
        ),
      ]),
      _tabStrip(),
      _toolbar(t, starred),
      if (_settings.bookmarks.isNotEmpty) _linksBar(),
      Expanded(
        child: Stack(children: [
          Positioned.fill(child: WebViewWidget(key: ObjectKey(t), controller: t.c)),
          if (t.loading)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: LinearProgressIndicator(value: t.progress == 0 ? null : t.progress / 100, minHeight: 3),
            ),
        ]),
      ),
      Container(
        height: 20,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        color: Xp.face,
        alignment: Alignment.centerLeft,
        child: Text(
          _blockedNote ?? (t.loading ? 'Opening page ${t.url}...' : 'Done'),
          style: Xp.text.copyWith(fontSize: 11),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ]),
      ),
    );
  }

  Widget _tabStrip() {
    return Container(
      height: 30,
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      decoration: const BoxDecoration(color: Xp.face, border: Border(bottom: BorderSide(color: Color(0xFF919B9C)))),
      child: Row(children: [
        Expanded(
          child: LayoutBuilder(builder: (c, box) {
            final each = (box.maxWidth / _tabs.length).clamp(60.0, 200.0).toDouble();
            return Row(children: [
              for (var i = 0; i < _tabs.length; i++)
                GestureDetector(
                  onTap: () => _select(i),
                  onTertiaryTapUp: (_) => _closeTab(i),
                  child: Container(
                    width: each - 2,
                    margin: const EdgeInsets.only(right: 2),
                    padding: const EdgeInsets.only(left: 6),
                    decoration: BoxDecoration(
                      color: i == _active ? Colors.white : const Color(0xFFF4F3EE),
                      border: Border(
                        top: BorderSide(
                            color: i == _active ? const Color(0xFFFFC83C) : const Color(0xFF919B9C),
                            width: i == _active ? 3 : 1),
                        left: const BorderSide(color: Color(0xFF919B9C)),
                        right: const BorderSide(color: Color(0xFF919B9C)),
                      ),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                    ),
                    child: Row(children: [
                      _tabs[i].loading
                          ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))
                          : const Icon(Icons.public, size: 14, color: Color(0xFF1E7BD8)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(_tabs[i].title,
                            style: (i == _active ? Xp.textBold : Xp.text).copyWith(fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      InkWell(
                        onTap: () => _closeTab(i),
                        child: const Padding(padding: EdgeInsets.all(3), child: Icon(Icons.close, size: 13)),
                      ),
                    ]),
                  ),
                ),
            ]);
          }),
        ),
        Tooltip(
          message: 'New tab (Ctrl+T)',
          child: InkWell(
            onTap: () => _newTab(null),
            child: const Padding(padding: EdgeInsets.all(3), child: Icon(Icons.add, size: 18)),
          ),
        ),
      ]),
    );
  }

  Widget _toolbar(_Tab t, bool starred) {
    Widget btn(IconData icon, String tip, VoidCallback? onTap, {Color color = const Color(0xFF2E7D32)}) => Tooltip(
          message: tip,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(icon, size: 20, color: onTap == null ? const Color(0xFFB0B0B0) : color),
            ),
          ),
        );
    return Container(
      color: Xp.face,
      padding: const EdgeInsets.fromLTRB(4, 3, 4, 3),
      child: Row(children: [
        btn(Icons.arrow_back, 'Back (Alt+Left)', t.canBack ? () => t.c.goBack() : null),
        btn(Icons.arrow_forward, 'Forward (Alt+Right)', t.canForward ? () => t.c.goForward() : null),
        t.loading
            ? btn(Icons.close, 'Stop', () => t.c.runJavaScript('window.stop()'), color: const Color(0xFFD03A1B))
            : btn(Icons.refresh, 'Refresh (F5)', () => t.c.reload()),
        btn(Icons.home, 'Home', () => _go(_settings.home), color: const Color(0xFF1E3E9B)),
        const SizedBox(width: 4),
        Expanded(
          child: Container(
            height: 24,
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Xp.fieldBorder)),
            child: Row(children: [
              const SizedBox(width: 3),
              Icon(t.url.startsWith('https') ? Icons.lock : Icons.public, size: 14, color: const Color(0xFF6A7B93)),
              Expanded(
                child: Focus(
                  onFocusChange: (f) {
                    if (f) _addr.selection = TextSelection(baseOffset: 0, extentOffset: _addr.text.length);
                  },
                  child: TextField(
                    controller: _addr,
                    focusNode: _addrFocus,
                    style: Xp.text,
                    keyboardType: TextInputType.url,
                    onSubmitted: (_) => _go(),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 5),
                    ),
                  ),
                ),
              ),
              InkWell(
                onTap: () => _settings.toggleBookmark(t.title, t.url),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(starred ? Icons.star : Icons.star_border,
                      size: 18, color: starred ? const Color(0xFFF5B800) : const Color(0xFF8A8A8A)),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(width: 4),
        XpButton(label: 'Go', minWidth: 36, onPressed: _go),
        const SizedBox(width: 4),
        Tooltip(
          message: 'Open this page in Brave',
          child: InkWell(
            onTap: _openInBrave,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFC5C2B2)),
                borderRadius: BorderRadius.circular(3),
              ),
              child: const Row(children: [
                Icon(Icons.shield, size: 16, color: Color(0xFFFB542B)),
                SizedBox(width: 3),
                Text('Brave', style: Xp.text),
              ]),
            ),
          ),
        ),
        btn(Icons.download, 'Downloads', () => context.read<WindowManager>().open(downloadsWindow()),
            color: const Color(0xFF1E3E9B)),
      ]),
    );
  }

  Widget _linksBar() {
    return Container(
      height: 24,
      color: Xp.face,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(children: [
        Text('Links', style: Xp.textGrey.copyWith(fontSize: 12)),
        const SizedBox(width: 6),
        Expanded(
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final (title, url) in _settings.bookmarks)
              GestureDetector(
                onSecondaryTapUp: (d) => _bookmarkMenu(d.globalPosition, url),
                onLongPressStart: (d) => _bookmarkMenu(d.globalPosition, url),
                child: InkWell(
                  onTap: () => _go(url),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Row(children: [
                      const Icon(Icons.public, size: 13, color: Color(0xFF1E7BD8)),
                      const SizedBox(width: 3),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 150),
                        child: Text(title, style: Xp.text.copyWith(fontSize: 12), overflow: TextOverflow.ellipsis),
                      ),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  Future<void> _bookmarkMenu(Offset global, String url) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final p = overlay.globalToLocal(global);
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(p.dx, p.dy, overlay.size.width - p.dx, overlay.size.height - p.dy),
      items: const [
        PopupMenuItem(value: 'open', height: 26, child: Text('Open', style: Xp.text)),
        PopupMenuItem(value: 'tab', height: 26, child: Text('Open in New Tab', style: Xp.text)),
        PopupMenuItem(value: 'brave', height: 26, child: Text('Open in Brave', style: Xp.text)),
        PopupMenuDivider(height: 7),
        PopupMenuItem(value: 'del', height: 26, child: Text('Delete', style: Xp.text)),
      ],
    );
    if (!mounted) return;
    switch (v) {
      case 'open':
        _go(url);
      case 'tab':
        _newTab(url);
      case 'brave':
        await openBraveWindow(_desk, url: url);
      case 'del':
        _settings.removeBookmark(url);
    }
  }
}

/// Opens Brave as a floating window over the desktop area (above the
/// taskbar). Android only sizes it when desktop / freeform windows are on.
Future<void> openBraveWindow(Desk desk, {String? url}) async {
  final views = WidgetsBinding.instance.platformDispatcher.views;
  final dpr = views.isEmpty ? 1.0 : views.first.devicePixelRatio;
  final r = Rect.fromLTWH(0, 0, desk.wm.desk.width * dpr, desk.wm.desk.height * dpr);
  final ok = await DeskPlatform.launchBounded(kBravePackage, url: url, bounds: r);
  if (!ok) {
    desk.message('Brave', "Brave isn't installed on this tablet. Get it from the Play Store, then try again.",
        icon: Icons.info);
  }
}

/// For keys passed over from Android while a web page has the keyboard.
bool isBrowserWindow(String? id) => id != null && id.startsWith('browser:');
