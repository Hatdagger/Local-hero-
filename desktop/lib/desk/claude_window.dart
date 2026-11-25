import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'window_manager.dart';
import 'xp_theme.dart';

const kClaudeId = 'claude';

/// A desktop-browser identity so the site uses its full desktop layout.
const _desktopUa =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// The site's own left sidebar, hidden because our tabs sit across the top.
/// It looks for a tall navigation strip on the far left and hides it, and
/// keeps doing so as the page changes.
const _hideSidebarJs = r'''
(function () {
  if (window.__deskSidebar) return;
  window.__deskSidebar = true;
  var pending = false;
  function hide() {
    pending = false;
    var navs = document.querySelectorAll('nav');
    for (var i = 0; i < navs.length; i++) {
      var n = navs[i];
      var r = n.getBoundingClientRect();
      if (r.width === 0 || r.left > 6 || r.height < window.innerHeight * 0.6 || r.width > window.innerWidth * 0.45) continue;
      var el = n;
      while (el.parentElement && el.parentElement !== document.body) {
        var pr = el.parentElement.getBoundingClientRect();
        if (pr.width > r.width + 4) break;
        el = el.parentElement;
      }
      el.style.setProperty('display', 'none', 'important');
    }
  }
  hide();
  new MutationObserver(function () {
    if (pending) return;
    pending = true;
    requestAnimationFrame(hide);
  }).observe(document.documentElement, { childList: true, subtree: true });
})();
''';

const _tabs = <(String, String, IconData)>[
  ('New chat', '/new', Icons.add_comment),
  ('Chats', '/recents', Icons.forum),
  ('Projects', '/projects', Icons.folder),
  ('Artifacts', '/artifacts', Icons.widgets),
  ('Code', '/code', Icons.code),
];

DeskWindow claudeWindow() => DeskWindow(
      id: kClaudeId,
      title: 'Claude',
      icon: Icons.auto_awesome,
      size: const Size(900, 640),
      minSize: const Size(420, 320),
      content: (c, w) => const _ClaudeWindow(),
    );

class _ClaudeWindow extends StatefulWidget {
  const _ClaudeWindow();

  @override
  State<_ClaudeWindow> createState() => _ClaudeWindowState();
}

class _ClaudeWindowState extends State<_ClaudeWindow> {
  late final WebViewController _web;
  String _path = '/new';
  bool _loading = true;
  bool _hideSidebar = true;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_desktopUa)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: (url) {
          if (!mounted) return;
          setState(() => _loading = false);
          _noteUrl(url);
          if (_hideSidebar) _web.runJavaScript(_hideSidebarJs);
        },
        onUrlChange: (c) => _noteUrl(c.url),
      ))
      ..loadRequest(Uri.parse('https://claude.ai/new'));
  }

  void _noteUrl(String? url) {
    if (url == null || !mounted) return;
    final u = Uri.tryParse(url);
    if (u == null) return;
    setState(() => _path = u.path);
  }

  void _go(String path) => _web.loadRequest(Uri.parse('https://claude.ai$path'));

  bool _isTab(String tabPath) {
    if (tabPath == '/new') return _path == '/new' || _path == '/';
    if (tabPath == '/recents') return _path.startsWith('/recents') || _path.startsWith('/chat');
    return _path.startsWith(tabPath);
  }

  @override
  Widget build(BuildContext context) {
    final wm = context.read<WindowManager>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Tab strip across the top.
      Container(
        height: 34,
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
        decoration: const BoxDecoration(
          color: Xp.face,
          border: Border(bottom: BorderSide(color: Color(0xFF919B9C))),
        ),
        child: Row(children: [
          _NavButton(icon: Icons.arrow_back, tip: 'Back', onTap: () => _web.goBack()),
          _NavButton(icon: Icons.arrow_forward, tip: 'Forward', onTap: () => _web.goForward()),
          _NavButton(icon: Icons.refresh, tip: 'Refresh', onTap: () => _web.reload()),
          const SizedBox(width: 6),
          Expanded(
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final (label, path, icon) in _tabs)
                _Tab(label: label, icon: icon, selected: _isTab(path), onTap: () => _go(path)),
            ]),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          PopupMenuButton<String>(
            tooltip: 'More',
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.more_vert, size: 18),
            onSelected: (v) {
              if (v == 'sidebar') {
                setState(() => _hideSidebar = !_hideSidebar);
                _web.reload();
              } else if (v == 'settings') {
                _go('/settings');
              } else if (v == 'close') {
                wm.close(kClaudeId);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'sidebar', child: Text(_hideSidebar ? "Show the site's sidebar" : "Hide the site's sidebar")),
              const PopupMenuItem(value: 'settings', child: Text('Settings')),
              const PopupMenuItem(value: 'close', child: Text('Close')),
            ],
          ),
        ]),
      ),
      Expanded(child: WebViewWidget(controller: _web)),
    ]);
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.icon, required this.selected, required this.onTap});
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: selected ? Colors.white : const Color(0xFFF4F3EE),
          border: Border(
            top: BorderSide(color: selected ? const Color(0xFFFFC83C) : const Color(0xFF919B9C), width: selected ? 3 : 1),
            left: const BorderSide(color: Color(0xFF919B9C)),
            right: const BorderSide(color: Color(0xFF919B9C)),
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
        ),
        alignment: Alignment.center,
        child: Row(children: [
          Icon(icon, size: 15, color: const Color(0xFF1E3E9B)),
          const SizedBox(width: 5),
          Text(label, style: selected ? Xp.textBold : Xp.text),
        ]),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.icon, required this.tip, required this.onTap});
  final IconData icon;
  final String tip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(4), child: Icon(icon, size: 18, color: const Color(0xFF2E7D32))),
      ),
    );
  }
}
