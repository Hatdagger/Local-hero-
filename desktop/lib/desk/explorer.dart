import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desk.dart';
import 'file_dialog.dart';
import 'files.dart';
import 'notepad.dart';
import 'platform.dart';
import 'wallpaper.dart';
import 'window_manager.dart';
import 'xp_theme.dart';

/// Special places that aren't real folders.
const kComputerPath = '::computer';
const kRecyclePath = '::recycle';

const kLocalHeroPackage = 'com.hatdagger.localhero';

int _explorerCount = 0;

/// An Explorer window, starting at [path] (My Computer when null).
DeskWindow explorerWindow({String? path}) {
  final start = path ?? kComputerPath;
  return DeskWindow(
    id: 'explorer:${_explorerCount++}',
    title: Places.titleOf(start),
    icon: start == kRecyclePath ? Icons.delete_outline : Icons.folder_open,
    size: const Size(760, 500),
    minSize: const Size(340, 220),
    content: (c, w) => _Explorer(w: w, start: start),
  );
}

/// What gets dragged between Explorer windows.
class FileDrag {
  final List<String> paths;
  final String from;
  const FileDrag(this.paths, this.from);
}

/// Well-known folders, filled in once storage is known.
class Places {
  static String root = '/storage/emulated/0';
  static String documents = '';
  static List<StorageVolume> volumes = const [];
  static bool hasAccess = false;
  static bool _ready = false;

  static Future<void> init({bool force = false}) async {
    if (_ready && !force) return;
    root = await DeskPlatform.storageRoot();
    documents = (await myDocuments()).path;
    volumes = await DeskPlatform.volumes();
    hasAccess = await DeskPlatform.hasAllFiles();
    final support = await getApplicationSupportDirectory();
    await RecycleBin.instance.init(
      preferred: '$root/.ClassicDesk Recycle Bin',
      fallback: '${support.path}/Recycle Bin',
    );
    _ready = true;
  }

  static String get downloads => '$root/Download';
  static String get pictures => '$root/Pictures';
  static String get music => '$root/Music';
  static String get videos => '$root/Movies';

  static String titleOf(String path) {
    if (path == kComputerPath) return 'My Computer';
    if (path == kRecyclePath) return 'Recycle Bin';
    if (path == documents && documents.isNotEmpty) return 'My Documents';
    for (final v in volumes) {
      if (v.path == path) return v.name;
    }
    if (path == root) return 'Internal storage';
    return baseName(path);
  }

  /// What the address bar shows.
  static String addressOf(String path) {
    if (path == kComputerPath) return 'My Computer';
    if (path == kRecyclePath) return 'Recycle Bin';
    if (path == documents) return 'My Documents';
    return path;
  }

  /// Turns what was typed in the address bar into a place.
  static String? parse(String typed) {
    final t = typed.trim();
    final l = t.toLowerCase();
    if (l.isEmpty) return null;
    if (l == 'my computer' || l == 'computer') return kComputerPath;
    if (l == 'recycle bin' || l == 'recycle') return kRecyclePath;
    if (l == 'my documents' || l == 'documents') return documents;
    if (l == 'downloads' || l == 'my downloads') return downloads;
    if (l == 'pictures' || l == 'my pictures') return pictures;
    if (l == 'music' || l == 'my music') return music;
    if (t.startsWith('/')) return t.length > 1 && t.endsWith('/') ? t.substring(0, t.length - 1) : t;
    return null;
  }
}

enum _View { icons, list, details }

enum _Sort { name, size, type, date }

class _Entry {
  final String path;
  final String name;
  final bool folder;
  final int size;
  final DateTime modified;
  final RecycledItem? recycled;
  final IconData? icon;
  final Color? iconColor;
  final String? note; // My Computer: free space / description
  _Entry(this.path, this.name,
      {this.folder = false, this.size = 0, DateTime? modified, this.recycled, this.icon, this.iconColor, this.note})
      : modified = modified ?? DateTime.fromMillisecondsSinceEpoch(0);

  FileKind get kind => kindOf(name, folder: folder);
  String get type => recycled != null
      ? typeLabel(name, folder: folder)
      : (note != null && icon != null ? note! : typeLabel(name, folder: folder));
}

class _Explorer extends StatefulWidget {
  const _Explorer({required this.w, required this.start});
  final DeskWindow w;
  final String start;

  @override
  State<_Explorer> createState() => _ExplorerState();
}

class _ExplorerState extends State<_Explorer> {
  late String _path = widget.start;
  final List<String> _back = [];
  final List<String> _fwd = [];
  List<_Entry> _entries = [];
  final Set<String> _sel = {};
  String? _anchor;
  int _cursor = -1;
  _View _view = _View.icons;
  _Sort _sort = _Sort.name;
  bool _asc = true;
  bool _showHidden = false;
  String? _error;
  bool _loading = false;
  String? _busy;
  String? _renaming;
  final _renameCtl = TextEditingController();
  final _renameFocus = FocusNode();
  final _addr = TextEditingController();
  final _focus = FocusNode(debugLabel: 'explorer');
  final _scroll = ScrollController();
  bool _mouse = false;
  bool _hitItem = false;
  int _cols = 1;
  late final AppLifecycleListener _life;

  Desk get _desk => context.read<Desk>();
  WindowManager get _wm => context.read<WindowManager>();

  @override
  void initState() {
    super.initState();
    FsEvents.instance.addListener(_reload);
    FileClipboard.instance.addListener(_repaint);
    RecycleBin.instance.addListener(_onBin);
    _life = AppLifecycleListener(onResume: _recheckAccess);
    _renameFocus.addListener(() {
      if (!_renameFocus.hasFocus && _renaming != null) _commitRename();
    });
    _start();
  }

  Future<void> _start() async {
    final p = await SharedPreferences.getInstance();
    _view = _View.values[(p.getInt('explorer.view') ?? 0).clamp(0, 2)];
    _showHidden = p.getBool('explorer.hidden') ?? false;
    await Places.init();
    if (!Places.hasAccess && !(p.getBool('explorer.askedAccess') ?? false)) {
      await p.setBool('explorer.askedAccess', true);
      unawaited(DeskPlatform.askAllFiles());
    }
    await _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  Future<void> _recheckAccess() async {
    final had = Places.hasAccess;
    final now = await DeskPlatform.hasAllFiles();
    if (now != had) {
      await Places.init(force: true);
      if (mounted) await _load();
    }
  }

  @override
  void dispose() {
    FsEvents.instance.removeListener(_reload);
    FileClipboard.instance.removeListener(_repaint);
    RecycleBin.instance.removeListener(_onBin);
    _life.dispose();
    _renameCtl.dispose();
    _renameFocus.dispose();
    _addr.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  void _onBin() {
    if (_path == kRecyclePath) _reload();
  }

  void _reload() {
    if (mounted) _load(keepSelection: true);
  }

  // ------------------------------------------------------------ loading

  Future<void> _load({bool keepSelection = false}) async {
    final path = _path;
    setState(() {
      _loading = true;
      _addr.text = Places.addressOf(path);
    });
    _wm.setTitle(widget.w.id, Places.titleOf(path));
    widget.w.icon = path == kRecyclePath
        ? Icons.delete_outline
        : (path == kComputerPath ? Icons.computer : Icons.folder_open);
    List<_Entry> list;
    String? error;
    try {
      list = await _list(path);
    } catch (e) {
      list = [];
      error = e is FileSystemException ? (e.osError?.message ?? e.message) : '$e';
    }
    if (!mounted || path != _path) return;
    _sortList(list);
    setState(() {
      _entries = list;
      _error = error;
      _loading = false;
      if (keepSelection) {
        final names = list.map((e) => e.path).toSet();
        _sel.retainWhere(names.contains);
      } else {
        _sel.clear();
        _anchor = null;
      }
      _cursor = _cursor.clamp(-1, list.length - 1);
    });
  }

  Future<List<_Entry>> _list(String path) async {
    if (path == kComputerPath) {
      final out = <_Entry>[];
      out.add(_Entry(Places.documents, 'My Documents',
          folder: true, icon: Icons.folder_special, iconColor: const Color(0xFFE8B84A), note: 'Desktop documents'));
      for (final v in Places.volumes) {
        out.add(_Entry(v.path, v.name,
            folder: true,
            icon: v.removable ? Icons.sd_card : Icons.storage,
            iconColor: const Color(0xFF6A7B93),
            note: v.removable ? 'Removable drive' : 'Local drive'));
      }
      if (Places.volumes.isEmpty) {
        out.add(_Entry(Places.root, 'Internal storage',
            folder: true, icon: Icons.storage, iconColor: const Color(0xFF6A7B93), note: 'Local drive'));
      }
      out.add(_Entry(kRecyclePath, 'Recycle Bin',
          folder: true, icon: Icons.delete_outline, iconColor: const Color(0xFF5F7EA8), note: 'System folder'));
      return out;
    }
    if (path == kRecyclePath) {
      final bin = RecycleBin.instance;
      return [
        for (final i in bin.items)
          _Entry(bin.pathOf(i), i.name, folder: i.folder, modified: i.deleted, recycled: i,
              size: i.folder ? 0 : _sizeOf(bin.pathOf(i))),
      ];
    }
    final out = <_Entry>[];
    await for (final e in Directory(path).list(followLinks: false)) {
      final name = baseName(e.path);
      if (!_showHidden && name.startsWith('.')) continue;
      try {
        final st = await e.stat();
        final folder = st.type == FileSystemEntityType.directory ||
            (st.type == FileSystemEntityType.link && FileSystemEntity.isDirectorySync(e.path));
        out.add(_Entry(e.path, name, folder: folder, size: folder ? 0 : st.size, modified: st.modified));
      } catch (_) {
        out.add(_Entry(e.path, name));
      }
    }
    return out;
  }

  static int _sizeOf(String p) {
    try {
      return File(p).lengthSync();
    } catch (_) {
      return 0;
    }
  }

  void _sortList(List<_Entry> list) {
    if (_path == kComputerPath) return;
    int cmp(_Entry a, _Entry b) {
      if (a.folder != b.folder) return a.folder ? -1 : 1;
      int r;
      switch (_sort) {
        case _Sort.name:
          r = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case _Sort.size:
          r = a.size.compareTo(b.size);
        case _Sort.type:
          r = a.type.compareTo(b.type);
        case _Sort.date:
          r = a.modified.compareTo(b.modified);
      }
      if (r == 0) r = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return _asc ? r : -r;
    }

    list.sort(cmp);
  }

  void _setSort(_Sort s) {
    setState(() {
      if (_sort == s) {
        _asc = !_asc;
      } else {
        _sort = s;
        _asc = s != _Sort.date && s != _Sort.size;
      }
      _sortList(_entries);
    });
  }

  Future<void> _setView(_View v) async {
    setState(() => _view = v);
    final p = await SharedPreferences.getInstance();
    await p.setInt('explorer.view', v.index);
  }

  Future<void> _toggleHidden() async {
    _showHidden = !_showHidden;
    final p = await SharedPreferences.getInstance();
    await p.setBool('explorer.hidden', _showHidden);
    await _load(keepSelection: true);
  }

  // ------------------------------------------------------------ navigation

  void _go(String path, {bool history = true}) {
    if (path == _path) {
      _load(keepSelection: true);
      return;
    }
    if (history) {
      _back.add(_path);
      _fwd.clear();
    }
    _path = path;
    _cursor = -1;
    _renaming = null;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
    _focus.requestFocus();
  }

  void _goBack() {
    if (_back.isEmpty) return;
    _fwd.add(_path);
    _go(_back.removeLast(), history: false);
  }

  void _goForward() {
    if (_fwd.isEmpty) return;
    _back.add(_path);
    _go(_fwd.removeLast(), history: false);
  }

  String? get _upTarget {
    if (_path == kComputerPath) return null;
    if (_path == kRecyclePath || _path == Places.documents) return kComputerPath;
    for (final v in Places.volumes) {
      if (v.path == _path) return kComputerPath;
    }
    if (_path == Places.root || _path == '/') return kComputerPath;
    return parentOf(_path);
  }

  void _goUp() {
    final u = _upTarget;
    if (u != null) _go(u);
  }

  void _submitAddress() {
    final typed = _addr.text.trim();
    final place = Places.parse(typed);
    if (place == null) {
      _desk.message('Address', "Can't find '$typed'. Check the spelling and try again.");
      return;
    }
    if (place.startsWith('::') || FileSystemEntity.isDirectorySync(place)) {
      _go(place);
    } else if (FileSystemEntity.isFileSync(place)) {
      openFileOnDesk(_desk, place);
    } else {
      _desk.message('Address', "Can't find '$typed'. Check the spelling and try again.");
    }
  }

  // ------------------------------------------------------------ selection

  bool get _special => _path == kComputerPath || _path == kRecyclePath;
  bool get _inBin => _path == kRecyclePath;
  bool get _real => !_special;

  List<_Entry> get _selected => _entries.where((e) => _sel.contains(e.path)).toList();

  void _clickItem(int i, PointerDownEvent ev) {
    _hitItem = true;
    _focus.requestFocus();
    final e = _entries[i];
    final kb = HardwareKeyboard.instance;
    final right = ev.buttons & kSecondaryMouseButton != 0;
    setState(() {
      if (right) {
        if (!_sel.contains(e.path)) {
          _sel
            ..clear()
            ..add(e.path);
          _anchor = e.path;
        }
      } else if (kb.isShiftPressed && _anchor != null) {
        final a = _entries.indexWhere((x) => x.path == _anchor);
        if (!kb.isControlPressed) _sel.clear();
        if (a >= 0) {
          for (var k = math.min(a, i); k <= math.max(a, i); k++) {
            _sel.add(_entries[k].path);
          }
        }
      } else if (kb.isControlPressed) {
        if (!_sel.remove(e.path)) _sel.add(e.path);
        _anchor = e.path;
      } else if (!_sel.contains(e.path) || _sel.length == 1) {
        _sel
          ..clear()
          ..add(e.path);
        _anchor = e.path;
      }
      _cursor = i;
    });
  }

  void _clickBackground(PointerDownEvent ev) {
    if (ev.kind == PointerDeviceKind.mouse) {
      _mouse = true;
    } else if (ev.kind == PointerDeviceKind.touch) {
      _mouse = false;
    }
    if (_hitItem) {
      _hitItem = false;
      return;
    }
    _focus.requestFocus();
    if (ev.buttons & kSecondaryMouseButton != 0) return;
    if (_sel.isNotEmpty && !HardwareKeyboard.instance.isControlPressed) {
      setState(() => _sel.clear());
    }
  }

  void _moveCursor(int delta, {bool extend = false}) {
    if (_entries.isEmpty) return;
    final i = _cursor < 0 ? (delta < 0 ? _entries.length - 1 : 0) : (_cursor + delta).clamp(0, _entries.length - 1);
    _setCursor(i, extend: extend);
  }

  void _setCursor(int i, {bool extend = false}) {
    if (_entries.isEmpty) return;
    i = i.clamp(0, _entries.length - 1);
    setState(() {
      _cursor = i;
      final p = _entries[i].path;
      final a = _anchor == null ? -1 : _entries.indexWhere((x) => x.path == _anchor);
      if (extend && a >= 0) {
        _sel.clear();
        for (var k = math.min(a, i); k <= math.max(a, i); k++) {
          _sel.add(_entries[k].path);
        }
      } else {
        _sel
          ..clear()
          ..add(p);
        _anchor = p;
      }
    });
    _ensureVisible(i);
  }

  void _ensureVisible(int i) {
    if (!_scroll.hasClients) return;
    final double top, height;
    if (_view == _View.icons) {
      top = (i ~/ _cols) * _kTileH;
      height = _kTileH;
    } else {
      top = i * _kRowH;
      height = _kRowH;
    }
    final pos = _scroll.position;
    if (top < pos.pixels) {
      _scroll.jumpTo(top);
    } else if (top + height > pos.pixels + pos.viewportDimension) {
      _scroll.jumpTo(math.min(pos.maxScrollExtent, top + height - pos.viewportDimension));
    }
  }

  void _selectAll() => setState(() => _sel
    ..clear()
    ..addAll(_entries.map((e) => e.path)));

  void _invertSelection() => setState(() {
        final all = _entries.map((e) => e.path).toSet();
        final keep = all.difference(_sel);
        _sel
          ..clear()
          ..addAll(keep);
      });

  void _jumpToLetter(String ch) {
    if (_entries.isEmpty) return;
    final c = ch.toLowerCase();
    final start = _cursor < 0 ? 0 : _cursor + 1;
    for (var n = 0; n < _entries.length; n++) {
      final i = (start + n) % _entries.length;
      if (_entries[i].name.toLowerCase().startsWith(c)) {
        _setCursor(i);
        return;
      }
    }
  }

  // ------------------------------------------------------------ keyboard

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    // Only when the file list itself has the keyboard (not the address bar).
    if (!_focus.hasPrimaryFocus) return KeyEventResult.ignored;
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    final k = e.logicalKey;
    final ctrl = kb.isControlPressed, shift = kb.isShiftPressed, alt = kb.isAltPressed;
    final grid = _view == _View.icons;

    if (alt) {
      if (k == LogicalKeyboardKey.arrowLeft) {
        _goBack();
      } else if (k == LogicalKeyboardKey.arrowRight) {
        _goForward();
      } else if (k == LogicalKeyboardKey.arrowUp) {
        _goUp();
      } else if (k == LogicalKeyboardKey.enter) {
        _properties();
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    if (ctrl) {
      if (k == LogicalKeyboardKey.keyA) {
        _selectAll();
      } else if (k == LogicalKeyboardKey.keyC) {
        _copy(cut: false);
      } else if (k == LogicalKeyboardKey.keyX) {
        _copy(cut: true);
      } else if (k == LogicalKeyboardKey.keyV) {
        _paste();
      } else if (k == LogicalKeyboardKey.keyN && shift) {
        _newFolder();
      } else if (k == LogicalKeyboardKey.keyN) {
        _desk.openExplorer(_path);
      } else if (k == LogicalKeyboardKey.keyW) {
        _wm.close(widget.w.id);
      } else if (k == LogicalKeyboardKey.keyL) {
        // Not a real Explorer shortcut, but handy: jump to the address bar.
        return KeyEventResult.ignored;
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      _moveCursor(grid ? _cols : 1, extend: shift);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _moveCursor(grid ? -_cols : -1, extend: shift);
    } else if (k == LogicalKeyboardKey.arrowRight && grid) {
      _moveCursor(1, extend: shift);
    } else if (k == LogicalKeyboardKey.arrowLeft && grid) {
      _moveCursor(-1, extend: shift);
    } else if (k == LogicalKeyboardKey.home) {
      _setCursor(0, extend: shift);
    } else if (k == LogicalKeyboardKey.end) {
      _setCursor(_entries.length - 1, extend: shift);
    } else if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      _openSelected();
    } else if (k == LogicalKeyboardKey.backspace) {
      if (_back.isNotEmpty) {
        _goBack();
      } else {
        _goUp();
      }
    } else if (k == LogicalKeyboardKey.delete) {
      _delete(forever: shift);
    } else if (k == LogicalKeyboardKey.f2) {
      _startRename();
    } else if (k == LogicalKeyboardKey.f5) {
      _load(keepSelection: true);
    } else if (k == LogicalKeyboardKey.escape) {
      if (FileClipboard.instance.cut) {
        FileClipboard.instance.clear();
      } else {
        setState(() => _sel.clear());
      }
    } else {
      final ch = e.character;
      if (ch != null && ch.length == 1 && RegExp(r'[\w ]').hasMatch(ch)) {
        _jumpToLetter(ch);
      } else {
        return KeyEventResult.ignored;
      }
    }
    return KeyEventResult.handled;
  }

  // ------------------------------------------------------------ actions

  void _openSelected() {
    final list = _selected;
    if (list.isEmpty) return;
    if (list.length == 1) {
      _open(list.first);
      return;
    }
    for (final e in list) {
      if (!e.folder) openFileOnDesk(_desk, e.path);
    }
  }

  void _open(_Entry e) {
    if (e.recycled != null) {
      _properties(only: e);
      return;
    }
    if (e.folder) {
      _go(e.path);
    } else {
      openFileOnDesk(_desk, e.path);
    }
  }

  void _copy({required bool cut}) {
    if (!_real || _sel.isEmpty) return;
    FileClipboard.instance.set(_sel.toList(), cut: cut);
    _status('${_sel.length} item${_sel.length == 1 ? '' : 's'} ${cut ? 'cut' : 'copied'}');
  }

  Future<void> _paste() async {
    final clip = FileClipboard.instance;
    if (!_real || clip.paths.isEmpty) return;
    final cut = clip.cut;
    final ok = await _transfer(clip.paths, _path, move: cut);
    if (cut && ok) clip.clear();
  }

  /// Copies or moves [paths] into [dest]. True if everything worked.
  Future<bool> _transfer(List<String> paths, String dest, {required bool move}) async {
    final verb = move ? 'Moving' : 'Copying';
    setState(() => _busy = '$verb ${paths.length} item${paths.length == 1 ? '' : 's'}...');
    final done = <String>[];
    String? failed;
    for (final p in paths) {
      try {
        final n = move ? await FileOps.moveInto(p, dest) : await FileOps.copyInto(p, dest);
        done.add(n);
      } catch (e) {
        failed = '${baseName(p)}: ${e is FileSystemException ? e.message : e}';
        break;
      }
    }
    if (!mounted) return failed == null;
    setState(() => _busy = null);
    FsEvents.instance.changed();
    if (dest == _path) {
      await _load();
      if (!mounted) return failed == null;
      setState(() {
        _sel
          ..clear()
          ..addAll(done);
      });
    }
    if (failed != null) {
      _desk.message(move ? 'Error Moving File' : 'Error Copying File', 'Cannot ${move ? 'move' : 'copy'} $failed');
    }
    return failed == null;
  }

  Future<void> _delete({bool forever = false}) async {
    final list = _selected;
    if (list.isEmpty || _path == kComputerPath) return;
    final what = list.length == 1 ? "'${list.first.name}'" : 'these ${list.length} items';
    if (_inBin) {
      confirmBox(_wm,
          title: 'Confirm File Delete',
          text: 'Are you sure you want to permanently delete $what?',
          icon: Icons.delete_forever,
          onYes: () => _run(() => RecycleBin.instance.purge(list.map((e) => e.recycled!).toList())));
      return;
    }
    if (forever || RecycleBin.instance.folder == null) {
      confirmBox(_wm,
          title: 'Confirm File Delete',
          text: 'Are you sure you want to permanently delete $what? This can\'t be undone.',
          icon: Icons.delete_forever,
          onYes: () => _run(() async {
                for (final e in list) {
                  await FileOps.deleteForever(e.path);
                }
                FsEvents.instance.changed();
              }));
      return;
    }
    await _run(() => RecycleBin.instance.recycle(list.map((e) => e.path).toList()), busy: 'Deleting...');
  }

  Future<void> _restore() async {
    final list = _selected.where((e) => e.recycled != null).map((e) => e.recycled!).toList();
    if (list.isEmpty) return;
    await _run(() => RecycleBin.instance.restore(list), busy: 'Restoring...');
  }

  void _emptyBin() {
    if (RecycleBin.instance.isEmpty) return;
    final n = RecycleBin.instance.items.length;
    confirmBox(_wm,
        title: 'Confirm Multiple File Delete',
        text: 'Are you sure you want to delete all $n item${n == 1 ? '' : 's'} in the Recycle Bin?',
        icon: Icons.delete_forever,
        onYes: () => _run(RecycleBin.instance.empty, busy: 'Emptying the Recycle Bin...'));
  }

  /// Runs a file job, showing [busy] meanwhile and any error afterwards.
  Future<void> _run(Future<void> Function() job, {String? busy}) async {
    if (busy != null) setState(() => _busy = busy);
    try {
      await job();
    } catch (e) {
      _desk.message('Error', e is FileSystemException ? '${e.message} ${e.path ?? ''}'.trim() : '$e');
    }
    if (!mounted) return;
    setState(() => _busy = null);
    await _load(keepSelection: true);
  }

  void _status(String s) {
    setState(() => _busy = s);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && _busy == s) setState(() => _busy = null);
    });
  }

  Future<void> _newFolder() async {
    if (!_real) return;
    final name = freeName(_path, 'New Folder', copySuffix: false);
    try {
      await Directory('$_path/$name').create();
    } catch (e) {
      _desk.message('Error', 'Cannot create the folder here. ${e is FileSystemException ? e.message : ''}');
      return;
    }
    FsEvents.instance.changed();
    await _load();
    _startRename(path: '$_path/$name');
  }

  Future<void> _newTextFile() async {
    if (!_real) return;
    final name = freeName(_path, 'New Text Document.txt', copySuffix: false);
    try {
      await File('$_path/$name').writeAsString('');
    } catch (e) {
      _desk.message('Error', 'Cannot create the file here. ${e is FileSystemException ? e.message : ''}');
      return;
    }
    FsEvents.instance.changed();
    await _load();
    _startRename(path: '$_path/$name');
  }

  void _startRename({String? path}) {
    if (!_real) return;
    final p = path ?? (_sel.length == 1 ? _sel.first : null);
    if (p == null) return;
    final i = _entries.indexWhere((e) => e.path == p);
    if (i < 0) return;
    final name = _entries[i].name;
    setState(() {
      _renaming = p;
      _sel
        ..clear()
        ..add(p);
      _cursor = i;
      _renameCtl.text = name;
      final ext = extOf(name);
      final end = _entries[i].folder || ext.isEmpty ? name.length : name.length - ext.length - 1;
      _renameCtl.selection = TextSelection(baseOffset: 0, extentOffset: end);
    });
    _ensureVisible(i);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _renameFocus.requestFocus();
    });
  }

  Future<void> _commitRename() async {
    final p = _renaming;
    if (p == null) return;
    _renaming = null;
    final name = _renameCtl.text.trim();
    if (name.isEmpty || name == baseName(p)) {
      setState(() {});
      _focus.requestFocus();
      return;
    }
    if (name.contains('/')) {
      _desk.message('Rename', 'A file name can\'t contain "/".');
      setState(() {});
      return;
    }
    final dest = '${parentOf(p)}/$name';
    if (FileSystemEntity.typeSync(dest, followLinks: false) != FileSystemEntityType.notFound) {
      _desk.message('Error Renaming File', "Cannot rename ${baseName(p)}: a file named '$name' already exists.");
      setState(() {});
      return;
    }
    try {
      await FileOps.moveTo(p, dest);
    } catch (e) {
      _desk.message('Error Renaming File', 'Cannot rename ${baseName(p)}. ${e is FileSystemException ? e.message : ''}');
    }
    FsEvents.instance.changed();
    await _load();
    if (!mounted) return;
    setState(() {
      _sel
        ..clear()
        ..add(dest);
      _anchor = dest;
      _cursor = _entries.indexWhere((e) => e.path == dest);
    });
    _focus.requestFocus();
  }

  void _cancelRename() {
    setState(() => _renaming = null);
    _focus.requestFocus();
  }

  void _properties({_Entry? only}) {
    final list = only != null ? [only] : _selected;
    if (list.isEmpty && _real) {
      _wm.open(propertiesWindow([_Entry(_path, Places.titleOf(_path), folder: true)].map(_propsOf).toList()));
      return;
    }
    if (list.isEmpty) return;
    _wm.open(propertiesWindow(list.map(_propsOf).toList()));
  }

  FileProps _propsOf(_Entry e) => FileProps(
        path: e.path,
        name: e.name,
        folder: e.folder,
        type: e.type,
        modified: e.modified,
        original: e.recycled?.original,
      );

  Future<void> _setWallpaper(_Entry e) async {
    final wp = context.read<WallpaperSettings>();
    try {
      final dir = await getApplicationSupportDirectory();
      final dest = '${dir.path}/wallpaper_${DateTime.now().millisecondsSinceEpoch}.${extOf(e.name)}';
      await File(e.path).copy(dest);
      await wp.apply(kind: 'image', imagePath: dest, position: wp.kind == 'image' ? wp.position : 'fill', color: wp.color);
    } catch (_) {
      _desk.message('Desktop Background', "Couldn't use ${e.name} as the background.");
    }
  }

  // ------------------------------------------------------------ drag and drop

  bool _canDrop(FileDrag d, String dest) {
    if (dest == kComputerPath) return false;
    if (dest == kRecyclePath) return d.from != kRecyclePath;
    if (d.from == kRecyclePath) return false;
    for (final p in d.paths) {
      if (p == dest || isInside(dest, p)) return false;
    }
    return d.paths.any((p) => parentOf(p) != dest) || HardwareKeyboard.instance.isControlPressed;
  }

  Future<void> _drop(FileDrag d, String dest) async {
    if (dest == kRecyclePath) {
      await _run(() => RecycleBin.instance.recycle(d.paths), busy: 'Deleting...');
      return;
    }
    final copy = HardwareKeyboard.instance.isControlPressed;
    final ok = await _transfer(d.paths, dest, move: !copy);
    if (ok && !copy) {
      final clip = FileClipboard.instance;
      if (clip.cut && clip.paths.any(d.paths.contains)) clip.clear();
    }
  }

  // ------------------------------------------------------------ menus

  Future<void> _popup(Offset global, List<_M> items) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final local = overlay.globalToLocal(global);
    final v = await showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(local.dx, local.dy, overlay.size.width - local.dx, overlay.size.height - local.dy),
      items: [
        for (var i = 0; i < items.length; i++)
          if (items[i].label == null)
            const PopupMenuDivider(height: 7)
          else
            PopupMenuItem<int>(
              value: i,
              height: 26,
              enabled: items[i].onTap != null,
              child: SizedBox(
                width: 200,
                child: Row(children: [
                  SizedBox(width: 18, child: items[i].checked ? const Icon(Icons.check, size: 15) : null),
                  Expanded(
                    child: Text(items[i].label!,
                        style: (items[i].bold ? Xp.textBold : Xp.text)
                            .copyWith(color: items[i].onTap == null ? const Color(0xFFACA899) : null)),
                  ),
                  if (items[i].shortcut != null) Text(items[i].shortcut!, style: Xp.text),
                ]),
              ),
            ),
      ],
    );
    if (v != null) items[v].onTap?.call();
    if (mounted) _focus.requestFocus();
  }

  void _itemMenu(Offset global) {
    final list = _selected;
    if (list.isEmpty) return;
    final one = list.length == 1 ? list.first : null;
    if (_inBin) {
      _popup(global, [
        _M('Restore', _restore, bold: true),
        const _M.sep(),
        _M('Delete', () => _delete()),
        const _M.sep(),
        _M('Properties', _properties),
      ]);
      return;
    }
    if (_path == kComputerPath) {
      _popup(global, [
        _M('Open', one == null ? null : () => _open(one), bold: true),
        _M('Open in New Window', one == null || one.path.startsWith('::') ? null : () => _desk.openExplorer(one.path)),
        if (one?.path == kRecyclePath) ...[
          const _M.sep(),
          _M('Empty Recycle Bin', RecycleBin.instance.isEmpty ? null : _emptyBin),
        ],
        const _M.sep(),
        _M('Properties', one == null || one.path.startsWith('::') ? null : _properties),
      ]);
      return;
    }
    final kind = one?.kind;
    _popup(global, [
      _M('Open', () => _openSelected(), bold: true),
      if (one != null && one.folder) _M('Open in New Window', () => _desk.openExplorer(one.path)),
      if (kind == FileKind.text) _M('Edit in Notepad', () => openInNotepad(_desk, one!.path)),
      if (kind == FileKind.audio) _M('Play in Local Hero', () => playInLocalHero(_desk, one!.path)),
      if (kind == FileKind.web || kind == FileKind.text) _M('Open in Browser', () => openInBrowser(_desk, one!.path)),
      if (one != null && !one.folder) _M('Open With...', () => openWithChooser(_desk, one.path)),
      if (kind == FileKind.image && kViewableImages.contains(extOf(one!.name)))
        _M('Set as Desktop Background', () => _setWallpaper(one)),
      const _M.sep(),
      _M('Cut', () => _copy(cut: true), shortcut: 'Ctrl+X'),
      _M('Copy', () => _copy(cut: false), shortcut: 'Ctrl+C'),
      if (one != null && one.folder)
        _M('Paste Into Folder',
            FileClipboard.instance.paths.isEmpty
                ? null
                : () async {
                    final clip = FileClipboard.instance;
                    final ok = await _transfer(clip.paths, one.path, move: clip.cut);
                    if (ok && clip.cut) clip.clear();
                  }),
      const _M.sep(),
      _M('Delete', () => _delete(), shortcut: 'Del'),
      _M('Rename', one == null ? null : () => _startRename(path: one.path), shortcut: 'F2'),
      const _M.sep(),
      _M('Properties', _properties),
    ]);
  }

  void _backgroundMenu(Offset global) {
    if (_inBin) {
      _popup(global, [
        _M('Empty Recycle Bin', RecycleBin.instance.isEmpty ? null : _emptyBin),
        const _M.sep(),
        ..._viewItems(),
        const _M.sep(),
        _M('Refresh', () => _load(keepSelection: true)),
      ]);
      return;
    }
    _popup(global, [
      ..._viewItems(),
      const _M.sep(),
      _M('Sort by Name', () => _setSort(_Sort.name), checked: _sort == _Sort.name),
      _M('Sort by Size', () => _setSort(_Sort.size), checked: _sort == _Sort.size),
      _M('Sort by Type', () => _setSort(_Sort.type), checked: _sort == _Sort.type),
      _M('Sort by Date Modified', () => _setSort(_Sort.date), checked: _sort == _Sort.date),
      const _M.sep(),
      _M('Refresh', () => _load(keepSelection: true)),
      if (_real) ...[
        const _M.sep(),
        _M('Paste', FileClipboard.instance.paths.isEmpty ? null : _paste, shortcut: 'Ctrl+V'),
        const _M.sep(),
        _M('New Folder', _newFolder),
        _M('New Text Document', _newTextFile),
        const _M.sep(),
        _M('Properties', () => _properties()),
      ],
    ]);
  }

  List<_M> _viewItems() => [
        _M('Icons', () => _setView(_View.icons), checked: _view == _View.icons),
        _M('List', () => _setView(_View.list), checked: _view == _View.list),
        _M('Details', () => _setView(_View.details), checked: _view == _View.details),
      ];

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final clip = FileClipboard.instance;
    final selCount = _sel.length;
    final menus = <(String, List<MenuBarEntry>)>[
      (
        'File',
        [
          MenuBarEntry('New Window', () => _desk.openExplorer(_path), shortcut: 'Ctrl+N'),
          MenuBarEntry('New Folder', _real ? _newFolder : null, shortcut: 'Ctrl+Shift+N'),
          MenuBarEntry('New Text Document', _real ? _newTextFile : null),
          const MenuBarEntry.separator(),
          MenuBarEntry('Open', selCount > 0 ? _openSelected : null),
          MenuBarEntry('Delete', selCount > 0 && _path != kComputerPath ? () => _delete() : null),
          MenuBarEntry('Rename', selCount == 1 && _real ? () => _startRename() : null, shortcut: 'F2'),
          MenuBarEntry('Properties', () => _properties(), shortcut: 'Alt+Enter'),
          if (_inBin) ...[
            const MenuBarEntry.separator(),
            MenuBarEntry('Restore', selCount > 0 ? _restore : null),
            MenuBarEntry('Empty Recycle Bin', RecycleBin.instance.isEmpty ? null : _emptyBin),
          ],
          const MenuBarEntry.separator(),
          MenuBarEntry('Close', () => _wm.close(widget.w.id)),
        ]
      ),
      (
        'Edit',
        [
          MenuBarEntry('Cut', selCount > 0 && _real ? () => _copy(cut: true) : null, shortcut: 'Ctrl+X'),
          MenuBarEntry('Copy', selCount > 0 && _real ? () => _copy(cut: false) : null, shortcut: 'Ctrl+C'),
          MenuBarEntry('Paste', clip.paths.isNotEmpty && _real ? _paste : null, shortcut: 'Ctrl+V'),
          const MenuBarEntry.separator(),
          MenuBarEntry('Select All', _entries.isEmpty ? null : _selectAll, shortcut: 'Ctrl+A'),
          MenuBarEntry('Invert Selection', _entries.isEmpty ? null : _invertSelection),
        ]
      ),
      (
        'View',
        [
          MenuBarEntry('Icons', () => _setView(_View.icons), checked: _view == _View.icons),
          MenuBarEntry('List', () => _setView(_View.list), checked: _view == _View.list),
          MenuBarEntry('Details', () => _setView(_View.details), checked: _view == _View.details),
          const MenuBarEntry.separator(),
          MenuBarEntry('Show Hidden Files', _toggleHidden, checked: _showHidden),
          const MenuBarEntry.separator(),
          MenuBarEntry('Refresh', () => _load(keepSelection: true), shortcut: 'F5'),
        ]
      ),
      (
        'Go',
        [
          MenuBarEntry('Back', _back.isEmpty ? null : _goBack, shortcut: 'Alt+Left'),
          MenuBarEntry('Forward', _fwd.isEmpty ? null : _goForward, shortcut: 'Alt+Right'),
          MenuBarEntry('Up One Level', _upTarget == null ? null : _goUp, shortcut: 'Alt+Up'),
          const MenuBarEntry.separator(),
          MenuBarEntry('My Computer', () => _go(kComputerPath)),
          MenuBarEntry('My Documents', () => _go(Places.documents)),
          MenuBarEntry('Downloads', () => _go(Places.downloads)),
          MenuBarEntry('Recycle Bin', () => _go(kRecyclePath)),
        ]
      ),
      (
        'Tools',
        [
          MenuBarEntry(Places.hasAccess ? 'All Files Access (allowed)' : 'Allow Access to All Files...',
              DeskPlatform.askAllFiles),
          MenuBarEntry('Empty Recycle Bin', RecycleBin.instance.isEmpty ? null : _emptyBin),
        ]
      ),
    ];

    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        XpMenuBar(menus: menus),
        _toolbar(),
        _addressBar(),
        Expanded(
          child: LayoutBuilder(builder: (c, box) {
            final pane = box.maxWidth >= 560;
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (pane) SizedBox(width: 190, child: _taskPane()),
              Expanded(child: _listArea()),
            ]);
          }),
        ),
        _statusBar(),
      ]),
    );
  }

  Widget _toolbar() {
    Widget btn(IconData icon, String label, VoidCallback? onTap, {bool showLabel = false}) {
      final enabled = onTap != null;
      return Tooltip(
        message: label,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
            child: Row(children: [
              Icon(icon, size: 22, color: enabled ? const Color(0xFF2E7D32) : const Color(0xFFB0B0B0)),
              if (showLabel) ...[
                const SizedBox(width: 3),
                Text(label, style: Xp.text.copyWith(color: enabled ? null : const Color(0xFFACA899))),
              ],
            ]),
          ),
        ),
      );
    }

    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: const BoxDecoration(
        color: Xp.face,
        border: Border(top: BorderSide(color: Color(0xFFD8D2BD)), bottom: BorderSide(color: Color(0xFFD8D2BD))),
      ),
      child: Row(children: [
        btn(Icons.arrow_back, 'Back', _back.isEmpty ? null : _goBack, showLabel: true),
        btn(Icons.arrow_forward, 'Forward', _fwd.isEmpty ? null : _goForward),
        const SizedBox(width: 4),
        Tooltip(
          message: 'Up',
          child: InkWell(
            onTap: _upTarget == null ? null : _goUp,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.drive_folder_upload,
                  size: 22, color: _upTarget == null ? const Color(0xFFB0B0B0) : const Color(0xFFE8B84A)),
            ),
          ),
        ),
        Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 6), color: const Color(0xFFC5C2B2)),
        btn(Icons.create_new_folder, 'New Folder', _real ? _newFolder : null),
        btn(Icons.content_cut, 'Cut', _sel.isNotEmpty && _real ? () => _copy(cut: true) : null),
        btn(Icons.content_copy, 'Copy', _sel.isNotEmpty && _real ? () => _copy(cut: false) : null),
        btn(Icons.content_paste, 'Paste', FileClipboard.instance.paths.isNotEmpty && _real ? _paste : null),
        btn(Icons.delete, 'Delete', _sel.isNotEmpty && _path != kComputerPath ? () => _delete() : null),
        Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 6), color: const Color(0xFFC5C2B2)),
        PopupMenuButton<_View>(
          tooltip: 'Views',
          padding: EdgeInsets.zero,
          onSelected: _setView,
          itemBuilder: (_) => [
            for (final v in _View.values)
              CheckedPopupMenuItem(
                value: v,
                checked: _view == v,
                height: 28,
                child: Text(switch (v) { _View.icons => 'Icons', _View.list => 'List', _View.details => 'Details' },
                    style: Xp.text),
              ),
          ],
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: Row(children: [
              Icon(Icons.view_module, size: 22, color: Color(0xFF1E3E9B)),
              Icon(Icons.arrow_drop_down, size: 16),
            ]),
          ),
        ),
        const Spacer(),
        if (_loading)
          const Padding(
            padding: EdgeInsets.only(right: 6),
            child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          ),
      ]),
    );
  }

  Widget _addressBar() {
    final (icon, color) = _path == kComputerPath
        ? (Icons.computer, const Color(0xFF4A6FB5))
        : _path == kRecyclePath
            ? (Icons.delete_outline, const Color(0xFF5F7EA8))
            : (Icons.folder_open, const Color(0xFFE8B84A));
    return Container(
      color: Xp.face,
      padding: const EdgeInsets.fromLTRB(6, 3, 6, 4),
      child: Row(children: [
        const Text('Address', style: Xp.textGrey),
        const SizedBox(width: 6),
        Expanded(
          child: Container(
            height: 24,
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Xp.fieldBorder)),
            child: Row(children: [
              const SizedBox(width: 3),
              Icon(icon, size: 16, color: color),
              Expanded(
                child: TextField(
                  controller: _addr,
                  style: Xp.text,
                  onSubmitted: (_) => _submitAddress(),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 5),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Places',
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.arrow_drop_down, size: 18),
                onSelected: _go,
                itemBuilder: (_) => [
                  for (final (label, p) in _placeList())
                    PopupMenuItem(value: p, height: 26, child: Text(label, style: Xp.text)),
                ],
              ),
            ]),
          ),
        ),
        const SizedBox(width: 4),
        XpButton(label: 'Go', minWidth: 40, onPressed: _submitAddress),
      ]),
    );
  }

  List<(String, String)> _placeList() => [
        ('My Computer', kComputerPath),
        ('My Documents', Places.documents),
        for (final v in Places.volumes) (v.name, v.path),
        ('Downloads', Places.downloads),
        ('Pictures', Places.pictures),
        ('Music', Places.music),
        ('Videos', Places.videos),
        ('Recycle Bin', kRecyclePath),
      ];

  Widget _taskPane() {
    final one = _sel.length == 1 && _selected.isNotEmpty ? _selected.first : null;
    Widget link(IconData icon, String label, VoidCallback? onTap, {Color color = const Color(0xFF1E3E9B)}) {
      return InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Icon(icon, size: 16, color: onTap == null ? const Color(0xFFB0B0B0) : color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(label,
                  style: Xp.text.copyWith(
                      fontSize: 12, color: onTap == null ? const Color(0xFFACA899) : const Color(0xFF0C32A4))),
            ),
          ]),
        ),
      );
    }

    Widget box(String title, List<Widget> children) => Container(
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

    final tasks = <Widget>[
      if (_inBin) ...[
        link(Icons.delete_forever, 'Empty the Recycle Bin', RecycleBin.instance.isEmpty ? null : _emptyBin),
        link(Icons.restore_from_trash, 'Restore the selected items', _sel.isEmpty ? null : _restore),
      ] else if (_real) ...[
        link(Icons.create_new_folder, 'Make a new folder', _newFolder, color: const Color(0xFFE8B84A)),
        if (one != null) ...[
          link(Icons.drive_file_rename_outline, 'Rename this ${one.folder ? 'folder' : 'file'}',
              () => _startRename(path: one.path)),
          link(Icons.content_copy, 'Copy this ${one.folder ? 'folder' : 'file'}', () => _copy(cut: false)),
          link(Icons.content_cut, 'Move this ${one.folder ? 'folder' : 'file'}', () => _copy(cut: true)),
          link(Icons.close, 'Delete this ${one.folder ? 'folder' : 'file'}', () => _delete(),
              color: const Color(0xFFD03A1B)),
        ] else if (_sel.length > 1) ...[
          link(Icons.content_copy, 'Copy the selected items', () => _copy(cut: false)),
          link(Icons.content_cut, 'Move the selected items', () => _copy(cut: true)),
          link(Icons.close, 'Delete the selected items', () => _delete(), color: const Color(0xFFD03A1B)),
        ],
        if (FileClipboard.instance.paths.isNotEmpty) link(Icons.content_paste, 'Paste here', _paste),
      ] else ...[
        link(Icons.info_outline, 'View system information', () => _desk.message(
            'My Computer', 'Internal storage: ${Places.root}\nAll files access: ${Places.hasAccess ? 'allowed' : 'not allowed'}',
            icon: Icons.info)),
      ],
    ];

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Color(0xFF7BA2E7), Color(0xFF6375D6)]),
      ),
      child: ListView(children: [
        box(_inBin ? 'Recycle Bin Tasks' : (_real ? 'File and Folder Tasks' : 'System Tasks'), tasks),
        box('Other Places', [
          for (final (label, p) in _placeList())
            if (p != _path)
              link(
                p == kComputerPath
                    ? Icons.computer
                    : p == kRecyclePath
                        ? Icons.delete_outline
                        : Icons.folder,
                label,
                () => _go(p),
                color: p == kComputerPath || p == kRecyclePath ? const Color(0xFF4A6FB5) : const Color(0xFFE8B84A),
              ),
        ]),
        if (one != null)
          box('Details', [
            Text(one.name, style: Xp.textBold.copyWith(fontSize: 12)),
            Text(one.type, style: Xp.text.copyWith(fontSize: 12)),
            if (!one.folder) Text('Size: ${formatSize(one.size)}', style: Xp.text.copyWith(fontSize: 12)),
            if (one.recycled != null)
              Text('From: ${parentOf(one.recycled!.original)}', style: Xp.text.copyWith(fontSize: 12)),
            if (one.modified.millisecondsSinceEpoch > 0)
              Text('${one.recycled != null ? 'Deleted' : 'Modified'}: ${formatDate(one.modified)}',
                  style: Xp.text.copyWith(fontSize: 12)),
          ]),
        const SizedBox(height: 10),
      ]),
    );
  }

  Widget _statusBar() {
    String text;
    if (_busy != null) {
      text = _busy!;
    } else if (_sel.isNotEmpty) {
      final files = _selected.where((e) => !e.folder);
      final bytes = files.fold<int>(0, (a, e) => a + e.size);
      text = '${_sel.length} object${_sel.length == 1 ? '' : 's'} selected'
          '${files.isEmpty ? '' : '    ${formatSize(bytes)}'}';
    } else {
      text = '${_entries.length} object${_entries.length == 1 ? '' : 's'}';
    }
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: const BoxDecoration(color: Xp.face, border: Border(top: BorderSide(color: Color(0xFFC5C2B2)))),
      alignment: Alignment.centerLeft,
      child: Row(children: [
        Expanded(child: Text(text, style: Xp.text.copyWith(fontSize: 12), overflow: TextOverflow.ellipsis)),
        if (!Places.hasAccess)
          GestureDetector(
            onTap: DeskPlatform.askAllFiles,
            child: Text('Limited access - click to allow all files',
                style: Xp.text.copyWith(fontSize: 12, color: const Color(0xFF0C32A4), decoration: TextDecoration.underline)),
          ),
      ]),
    );
  }

  Widget _listArea() {
    Widget body;
    if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.block, size: 36, color: Color(0xFFD03A1B)),
            const SizedBox(height: 8),
            Text("${Places.titleOf(_path)} can't be opened.", style: Xp.textBold, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(_error!, style: Xp.textGrey, textAlign: TextAlign.center),
            if (!Places.hasAccess) ...[
              const SizedBox(height: 10),
              const Text('The desktop needs "All files access" to see this folder.', style: Xp.text),
              const SizedBox(height: 8),
              XpButton(label: 'Allow access...', isDefault: true, onPressed: DeskPlatform.askAllFiles, minWidth: 110),
            ],
          ]),
        ),
      );
    } else if (_entries.isEmpty && !_loading) {
      body = Center(
          child: Text(_inBin ? 'The Recycle Bin is empty.' : 'This folder is empty.', style: Xp.textGrey));
    } else {
      body = switch (_view) {
        _View.icons => _iconsView(),
        _View.list => _listView(),
        _View.details => _detailsView(),
      };
    }

    final area = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _clickBackground,
      onPointerHover: (e) {
        if (e.kind == PointerDeviceKind.mouse && !_mouse) setState(() => _mouse = true);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapUp: (d) => _backgroundMenu(d.globalPosition),
        onLongPressStart: (d) => _backgroundMenu(d.globalPosition),
        child: Container(color: Colors.white, child: body),
      ),
    );

    return DragTarget<FileDrag>(
      onWillAcceptWithDetails: (d) => _canDrop(d.data, _path),
      onAcceptWithDetails: (d) => _drop(d.data, _path),
      builder: (c, cand, rej) => Container(
        foregroundDecoration: cand.isNotEmpty
            ? BoxDecoration(border: Border.all(color: Xp.selection, width: 2))
            : null,
        child: area,
      ),
    );
  }

  static const double _kTileW = 96;
  static const double _kTileH = 86;
  static const double _kRowH = 22;

  Widget _iconsView() {
    return LayoutBuilder(builder: (c, box) {
      _cols = math.max(1, (box.maxWidth - 8) ~/ _kTileW);
      return Scrollbar(
        controller: _scroll,
        child: GridView.builder(
          controller: _scroll,
          padding: const EdgeInsets.all(4),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: _cols, mainAxisExtent: _kTileH),
          itemCount: _entries.length,
          itemBuilder: (c, i) => _item(i, _ItemStyle.tile),
        ),
      );
    });
  }

  Widget _listView() {
    return Scrollbar(
      controller: _scroll,
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(vertical: 2),
        itemExtent: _kRowH,
        itemCount: _entries.length,
        itemBuilder: (c, i) => Align(alignment: Alignment.centerLeft, child: _item(i, _ItemStyle.row)),
      ),
    );
  }

  Widget _detailsView() {
    final bin = _inBin;
    final comp = _path == kComputerPath;
    Widget head(String label, _Sort? s, {double? width, bool right = false}) {
      final w = InkWell(
        onTap: s == null || comp ? null : () => _setSort(s),
        child: Container(
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: const BoxDecoration(
            color: Color(0xFFEBEADB),
            border: Border(right: BorderSide(color: Color(0xFFC7C5B2)), bottom: BorderSide(color: Color(0xFFC7C5B2))),
          ),
          alignment: right ? Alignment.centerRight : Alignment.centerLeft,
          child: Row(mainAxisAlignment: right ? MainAxisAlignment.end : MainAxisAlignment.start, children: [
            Flexible(child: Text(label, style: Xp.text.copyWith(fontSize: 12), overflow: TextOverflow.ellipsis)),
            if (s != null && s == _sort && !comp)
              Icon(_asc ? Icons.arrow_drop_up : Icons.arrow_drop_down, size: 16, color: const Color(0xFF8A8A8A)),
          ]),
        ),
      );
      return width == null ? Expanded(child: w) : SizedBox(width: width, child: w);
    }

    return LayoutBuilder(builder: (c, box) {
      final narrow = box.maxWidth < 460;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          head('Name', _Sort.name),
          if (bin && !narrow) head('Original Location', null, width: 170),
          if (!comp) head('Size', _Sort.size, width: 80, right: true),
          if (!narrow) head(comp ? 'Type' : 'Type', _Sort.type, width: 130),
          if (!comp && !narrow) head(bin ? 'Date Deleted' : 'Date Modified', _Sort.date, width: 140),
        ]),
        Expanded(
          child: Scrollbar(
            controller: _scroll,
            child: ListView.builder(
              controller: _scroll,
              itemExtent: _kRowH,
              itemCount: _entries.length,
              itemBuilder: (c, i) => _item(i, _ItemStyle.details, narrow: narrow),
            ),
          ),
        ),
      ]);
    });
  }

  Widget _item(int i, _ItemStyle style, {bool narrow = false}) {
    final e = _entries[i];
    final selected = _sel.contains(e.path);
    final cut = FileClipboard.instance.isCut(e.path);
    final renaming = _renaming == e.path;
    final (kIcon, kColor) = iconFor(e.kind);
    final icon = e.icon ?? kIcon;
    final color = e.iconColor ?? kColor;
    final focused = _focus.hasFocus;
    final hiBg = selected ? (focused ? Xp.selection : const Color(0xFFD4D0C8)) : null;
    final hiFg = selected && focused ? Colors.white : Colors.black;

    Widget label(TextStyle base, {int maxLines = 1, TextAlign align = TextAlign.start}) {
      if (renaming) {
        return Container(
          decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.black)),
          width: style == _ItemStyle.tile ? 90 : 220,
          child: Focus(
            onKeyEvent: (n, ev) {
              if (ev is KeyDownEvent && ev.logicalKey == LogicalKeyboardKey.escape) {
                _cancelRename();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TextField(
              controller: _renameCtl,
              focusNode: _renameFocus,
              style: base,
              textAlign: align,
              maxLines: 1,
              onSubmitted: (_) => _commitRename(),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(horizontal: 2, vertical: 3),
              ),
            ),
          ),
        );
      }
      return Container(
        color: hiBg,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(e.name,
            maxLines: maxLines, overflow: TextOverflow.ellipsis, textAlign: align, style: base.copyWith(color: hiFg)),
      );
    }

    final iconW = Opacity(
      opacity: cut ? 0.45 : 1,
      child: Icon(icon, size: style == _ItemStyle.tile ? 40 : 16, color: color),
    );

    Widget child;
    switch (style) {
      case _ItemStyle.tile:
        child = SizedBox(
          width: _kTileW - 4,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(3),
              color: selected ? const Color(0x55316AC5) : null,
              child: iconW,
            ),
            const SizedBox(height: 3),
            label(Xp.text.copyWith(fontSize: 12), maxLines: 2, align: TextAlign.center),
          ]),
        );
      case _ItemStyle.row:
        child = SizedBox(
          height: _kRowH,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(width: 4),
            iconW,
            const SizedBox(width: 4),
            Flexible(child: label(Xp.text.copyWith(fontSize: 12))),
          ]),
        );
      case _ItemStyle.details:
        final small = Xp.text.copyWith(fontSize: 12);
        Widget cell(String t, double w, {bool right = false}) => SizedBox(
              width: w,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(t, style: small, overflow: TextOverflow.ellipsis, textAlign: right ? TextAlign.right : null),
              ),
            );
        final bin = _inBin, comp = _path == kComputerPath;
        child = Container(
          color: i == _cursor && focused && !selected ? const Color(0xFFF1F5FB) : null,
          child: Row(children: [
            Expanded(
              child: Row(children: [
                const SizedBox(width: 4),
                iconW,
                const SizedBox(width: 4),
                Flexible(child: Align(alignment: Alignment.centerLeft, child: label(small))),
              ]),
            ),
            if (bin && !narrow) cell(parentOf(e.recycled?.original ?? ''), 170),
            if (!comp) cell(e.folder ? '' : formatSize(e.size), 80, right: true),
            if (!narrow) cell(e.type, 130),
            if (!comp && !narrow) cell(e.modified.millisecondsSinceEpoch == 0 ? '' : formatDate(e.modified), 140),
          ]),
        );
    }

    Widget tile = Listener(
      onPointerDown: (ev) => _clickItem(i, ev),
      child: GestureDetector(
        onDoubleTap: renaming ? null : () => _open(e),
        onSecondaryTapUp: (d) => _itemMenu(d.globalPosition),
        onLongPressStart: (d) {
          setState(() {
            _sel
              ..clear()
              ..add(e.path);
            _anchor = e.path;
          });
          _itemMenu(d.globalPosition);
        },
        child: child,
      ),
    );

    // Folders accept drops.
    if (e.folder && e.path != kComputerPath) {
      final inner = tile;
      tile = DragTarget<FileDrag>(
        onWillAcceptWithDetails: (d) => _canDrop(d.data, e.path),
        onAcceptWithDetails: (d) => _drop(d.data, e.path),
        builder: (c, cand, rej) => Container(
          decoration: cand.isNotEmpty ? BoxDecoration(color: const Color(0x33316AC5), border: Border.all(color: Xp.selection)) : null,
          child: inner,
        ),
      );
    }

    // Items can be dragged with the mouse (on touch, hold for the menu instead).
    if (!renaming && _path != kComputerPath) {
      final paths = selected ? _selected.map((x) => x.path).toList() : [e.path];
      tile = Draggable<FileDrag>(
        data: FileDrag(paths, _path),
        maxSimultaneousDrags: _mouse ? 1 : 0,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        onDragStarted: () {
          if (!selected) {
            setState(() {
              _sel
                ..clear()
                ..add(e.path);
            });
          }
        },
        feedback: _DragFeedback(icon: icon, color: color, label: paths.length == 1 ? e.name : '${paths.length} items'),
        child: tile,
      );
    }
    return tile;
  }
}

enum _ItemStyle { tile, row, details }

class _M {
  final String? label;
  final VoidCallback? onTap;
  final String? shortcut;
  final bool bold;
  final bool checked;
  const _M(this.label, this.onTap, {this.shortcut, this.bold = false, this.checked = false});
  const _M.sep()
      : label = null,
        onTap = null,
        shortcut = null,
        bold = false,
        checked = false;
}

class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.icon, required this.color, required this.label});
  final IconData icon;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: const Offset(8, 8),
      child: Opacity(
        opacity: 0.75,
        child: Material(
          type: MaterialType.transparency,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 32, color: color),
            const SizedBox(width: 4),
            Container(
              color: Xp.selection,
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              child: Text(label, style: Xp.text.copyWith(color: Colors.white, fontSize: 12)),
            ),
          ]),
        ),
      ),
    );
  }
}

// ======================================================================
// Opening files

Future<void> openInNotepad(Desk desk, String path) async {
  desk.wm.open(notepadFileWindow(path));
}

Future<void> openInBrowser(Desk desk, String path) async {
  desk.openBrowser(Uri.file(path).toString());
}

Future<void> openWithChooser(Desk desk, String path) async {
  final ok = await DeskPlatform.openWith(path);
  if (!ok) desk.message('Open With', "No app on this device can open '${baseName(path)}'.");
}

Future<void> playInLocalHero(Desk desk, String path) async {
  final ok = await DeskPlatform.openWith(path, package: kLocalHeroPackage);
  if (!ok) desk.message('Play', "Couldn't play '${baseName(path)}'.");
}

/// Opens a file the way double-clicking it should.
Future<void> openFileOnDesk(Desk desk, String path) async {
  final name = baseName(path);
  final ext = extOf(name);
  switch (kindOf(name)) {
    case FileKind.folder:
      desk.openExplorer(path);
    case FileKind.text:
      await openInNotepad(desk, path);
    case FileKind.image:
      if (kViewableImages.contains(ext)) {
        desk.wm.open(pictureWindow(path));
      } else {
        await openWithChooser(desk, path);
      }
    case FileKind.audio:
      await playInLocalHero(desk, path);
    case FileKind.web:
      if (ext == 'url' || ext == 'webloc') {
        final url = _shortcutTarget(path);
        if (url != null) {
          desk.openBrowser(url);
        } else {
          desk.message('Internet Shortcut', "'$name' doesn't contain a web address.");
        }
      } else {
        await openInBrowser(desk, path);
      }
    default:
      await openWithChooser(desk, path);
  }
}

String? _shortcutTarget(String path) {
  try {
    final text = File(path).readAsStringSync();
    final m = RegExp(r'^\s*URL\s*=\s*(\S+)', multiLine: true, caseSensitive: false).firstMatch(text) ??
        RegExp(r'<string>(https?://[^<]+)</string>').firstMatch(text);
    return m?.group(1);
  } catch (_) {
    return null;
  }
}

// ======================================================================
// Small windows: confirm box, properties, picture viewer

void confirmBox(WindowManager wm,
    {required String title, required String text, required VoidCallback onYes, IconData icon = Icons.help}) {
  wm.open(DeskWindow(
    id: 'confirm:${DateTime.now().microsecondsSinceEpoch}',
    title: title,
    icon: icon,
    size: const Size(400, 150),
    resizable: false,
    canMaximize: false,
    canMinimize: false,
    content: (c, w) => Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 32, color: Xp.selection),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: Xp.text)),
          ]),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          XpButton(
              label: 'Yes',
              isDefault: true,
              onPressed: () {
                wm.close(w.id);
                onYes();
              }),
          const SizedBox(width: 6),
          XpButton(label: 'No', onPressed: () => wm.close(w.id)),
        ]),
      ]),
    ),
  ));
}

class FileProps {
  final String path;
  final String name;
  final bool folder;
  final String type;
  final DateTime modified;
  final String? original;
  const FileProps(
      {required this.path,
      required this.name,
      required this.folder,
      required this.type,
      required this.modified,
      this.original});
}

DeskWindow propertiesWindow(List<FileProps> items) {
  final one = items.length == 1 ? items.first : null;
  return DeskWindow(
    id: 'props:${DateTime.now().microsecondsSinceEpoch}',
    title: one == null ? 'Properties' : '${one.name} Properties',
    icon: Icons.info_outline,
    size: const Size(380, 330),
    resizable: false,
    canMaximize: false,
    canMinimize: false,
    content: (c, w) => _Properties(w: w, items: items),
  );
}

class _Properties extends StatefulWidget {
  const _Properties({required this.w, required this.items});
  final DeskWindow w;
  final List<FileProps> items;

  @override
  State<_Properties> createState() => _PropertiesState();
}

class _PropertiesState extends State<_Properties> {
  (int, int, int)? _size;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    var b = 0, f = 0, d = 0;
    for (final i in widget.items) {
      final (bb, ff, dd) = await FileOps.measure(i.path);
      b += bb;
      f += ff;
      d += dd + (i.folder ? 1 : 0);
    }
    if (mounted) setState(() => _size = (b, f, d));
  }

  @override
  Widget build(BuildContext context) {
    final wm = context.read<WindowManager>();
    final one = widget.items.length == 1 ? widget.items.first : null;
    final kind = one == null ? FileKind.other : kindOf(one.name, folder: one.folder);
    final (icon, color) = iconFor(kind);
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 100, child: Text(k, style: Xp.text)),
            Expanded(child: SelectableText(v, style: Xp.text)),
          ]),
        );
    final s = _size;
    final sizeText = s == null ? 'Calculating...' : '${formatSize(s.$1)} (${s.$1} bytes)';
    final contains = s == null ? '' : '${s.$2} Files, ${math.max(0, s.$3 - (one?.folder == true ? 1 : 0))} Folders';
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(one == null ? Icons.copy_all : icon, size: 36, color: color),
          const SizedBox(width: 12),
          Expanded(
              child: Text(one?.name ?? '${widget.items.length} items', style: Xp.textBold, overflow: TextOverflow.ellipsis)),
        ]),
        const Divider(),
        if (one != null) row('Type:', one.type),
        if (one != null) row(one.original != null ? 'Original:' : 'Location:', one.original ?? parentOf(one.path)),
        row('Size:', sizeText),
        if (one == null || one.folder) row('Contains:', contains),
        if (one != null && one.modified.millisecondsSinceEpoch > 0)
          row(one.original != null ? 'Deleted:' : 'Modified:', formatDate(one.modified)),
        const Spacer(),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          XpButton(label: 'OK', isDefault: true, onPressed: () => wm.close(widget.w.id)),
        ]),
      ]),
    );
  }
}

int _pictureCount = 0;

/// A simple picture viewer with previous/next through the folder's pictures.
DeskWindow pictureWindow(String path) => DeskWindow(
      id: 'picture:${_pictureCount++}',
      title: '${baseName(path)} - Picture Viewer',
      icon: Icons.image,
      size: const Size(640, 480),
      minSize: const Size(260, 200),
      content: (c, w) => _PictureViewer(w: w, path: path),
    );

class _PictureViewer extends StatefulWidget {
  const _PictureViewer({required this.w, required this.path});
  final DeskWindow w;
  final String path;

  @override
  State<_PictureViewer> createState() => _PictureViewerState();
}

class _PictureViewerState extends State<_PictureViewer> {
  late String _path = widget.path;
  List<String> _all = [];
  final _tc = TransformationController();

  @override
  void initState() {
    super.initState();
    try {
      _all = Directory(parentOf(widget.path))
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((p) => kViewableImages.contains(extOf(baseName(p))))
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    } catch (_) {
      _all = [widget.path];
    }
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _step(int d) {
    if (_all.length < 2) return;
    final n = _all.length;
    final i = math.max(0, _all.indexOf(_path));
    setState(() {
      _path = _all[((i + d) % n + n) % n];
      _tc.value = Matrix4.identity();
    });
    context.read<WindowManager>().setTitle(widget.w.id, '${baseName(_path)} - Picture Viewer');
  }

  @override
  Widget build(BuildContext context) {
    final desk = context.read<Desk>();
    return Focus(
      autofocus: true,
      onKeyEvent: (n, e) {
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        if (e.logicalKey == LogicalKeyboardKey.arrowRight || e.logicalKey == LogicalKeyboardKey.space) {
          _step(1);
        } else if (e.logicalKey == LogicalKeyboardKey.arrowLeft || e.logicalKey == LogicalKeyboardKey.backspace) {
          _step(-1);
        } else {
          return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      },
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: Container(
            color: Colors.white,
            child: InteractiveViewer(
              transformationController: _tc,
              maxScale: 8,
              child: Center(
                child: Image.file(File(_path),
                    key: ValueKey(_path),
                    errorBuilder: (c, e, s) => const Text("This picture can't be shown.", style: Xp.textGrey)),
              ),
            ),
          ),
        ),
        Container(
          height: 38,
          color: Xp.face,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(
                tooltip: 'Previous', onPressed: _all.length > 1 ? () => _step(-1) : null, icon: const Icon(Icons.arrow_back)),
            IconButton(
                tooltip: 'Next', onPressed: _all.length > 1 ? () => _step(1) : null, icon: const Icon(Icons.arrow_forward)),
            IconButton(
                tooltip: 'Actual size', onPressed: () => _tc.value = Matrix4.identity(), icon: const Icon(Icons.fit_screen)),
            const SizedBox(width: 12),
            XpButton(
              label: 'Set as Background',
              minWidth: 130,
              onPressed: () async {
                final wp = context.read<WallpaperSettings>();
                try {
                  final dir = await getApplicationSupportDirectory();
                  final dest = '${dir.path}/wallpaper_${DateTime.now().millisecondsSinceEpoch}.${extOf(_path)}';
                  await File(_path).copy(dest);
                  await wp.apply(
                      kind: 'image', imagePath: dest, position: wp.kind == 'image' ? wp.position : 'fill', color: wp.color);
                } catch (_) {
                  desk.message('Desktop Background', "Couldn't use this picture as the background.");
                }
              },
            ),
            const SizedBox(width: 6),
            XpButton(label: 'Open With...', minWidth: 90, onPressed: () => openWithChooser(desk, _path)),
          ]),
        ),
      ]),
    );
  }
}
