import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desk.dart';
import 'explorer.dart';
import 'files.dart';
import 'platform.dart';
import 'window_manager.dart';
import 'xp_theme.dart';

// ======================================================================
// Built-in shortcuts (My Computer, Solitaire...)

class DeskShortcut {
  final String id;
  final String label;
  final IconData icon;
  final Color color;
  const DeskShortcut(this.id, this.label, this.icon, this.color);
}

const kDeskShortcuts = <DeskShortcut>[
  DeskShortcut('computer', 'My Computer', Icons.computer, Color(0xFFDDE8FF)),
  DeskShortcut('docs', 'My Documents', Icons.folder_special, Color(0xFFF2C75C)),
  DeskShortcut('recycle', 'Recycle Bin', Icons.delete_outline, Color(0xFFDDE8FF)),
  DeskShortcut('internet', 'Internet', Icons.public, Color(0xFF6FB8FF)),
  DeskShortcut('aim', 'Instant Messenger', Icons.chat_bubble, Color(0xFFF5C400)),
  DeskShortcut('claude', 'Claude', Icons.auto_awesome, Color(0xFFE8875B)),
  DeskShortcut('player', 'Media Player', Icons.play_circle, Color(0xFF8FD14F)),
  DeskShortcut('mini', 'Mini Player', Icons.music_note, Color(0xFFFFB04A)),
  DeskShortcut('notepad', 'Notepad', Icons.description, Color(0xFFE6F0FF)),
  DeskShortcut('solitaire', 'Solitaire', Icons.style, Color(0xFFFFFFFF)),
  DeskShortcut('run', 'Run...', Icons.play_circle_fill, Color(0xFFDDE8FF)),
  DeskShortcut('display', 'Display Properties', Icons.desktop_windows, Color(0xFFDDE8FF)),
  DeskShortcut('network', 'Wireless Networks', Icons.wifi, Color(0xFFBFE3FF)),
  DeskShortcut('bluetooth', 'Bluetooth Devices', Icons.bluetooth, Color(0xFF8FC2FF)),
];

/// Shortcuts that start out hidden (put them back with "Restore Standard Icons"
/// or from the Start menu).
const kHiddenByDefault = {'network', 'bluetooth', 'mini'};

/// Only the Recycle Bin always stays on the desktop.
const kPinnedShortcuts = {'recycle'};

DeskShortcut? shortcutById(String id) {
  for (final s in kDeskShortcuts) {
    if (s.id == id) return s;
  }
  return null;
}

/// Opens a built-in shortcut. False if [id] is unknown.
bool openShortcut(Desk desk, String id) {
  switch (id) {
    case 'computer':
      desk.openExplorer();
    case 'docs':
      unawaited(desk.openMyDocuments());
    case 'recycle':
      desk.openRecycleBin();
    case 'internet':
      desk.openBrowser();
    case 'aim':
      desk.openAim();
    case 'claude':
      desk.openClaude();
    case 'player':
      desk.openMediaPlayer();
    case 'mini':
      desk.openMiniPlayer();
    case 'notepad':
      desk.openNotepad();
    case 'solitaire':
      desk.openSolitaire();
    case 'run':
      desk.openRun();
    case 'display':
      desk.openDisplay();
    case 'network':
      desk.openNetwork();
    case 'bluetooth':
      desk.openBluetooth();
    default:
      return false;
  }
  return true;
}

// ======================================================================
// Shortcut files (".lnk"): a built-in shortcut or an Android app, saved as
// a small text file so it can live in any folder.

class ShortcutTarget {
  final String? shortcut; // built-in id
  final String? app; // Android package
  final String? path; // a file or folder
  const ShortcutTarget({this.shortcut, this.app, this.path});
}

class ShortcutFile {
  static const ext = 'lnk';

  static bool isShortcut(String name) => extOf(name) == ext;

  static String content({String? shortcut, String? app, String? path}) {
    final line = shortcut != null ? 'shortcut=$shortcut' : (app != null ? 'app=$app' : 'path=$path');
    return '[ClassicDesk]\n$line\n';
  }

  static ShortcutTarget? parse(String text) {
    final p = RegExp(r'^\s*path\s*=\s*(.+?)\s*$', multiLine: true).firstMatch(text);
    if (p != null) return ShortcutTarget(path: p.group(1));
    final s = RegExp(r'^\s*shortcut\s*=\s*(\S+)', multiLine: true).firstMatch(text);
    if (s != null) return ShortcutTarget(shortcut: s.group(1));
    final a = RegExp(r'^\s*app\s*=\s*(\S+)', multiLine: true).firstMatch(text);
    if (a != null) return ShortcutTarget(app: a.group(1));
    return null;
  }

  static ShortcutTarget? read(String path) {
    try {
      return parse(File(path).readAsStringSync());
    } catch (_) {
      return null;
    }
  }

  /// Makes "[label].lnk" in [dir]. Returns its path.
  static Future<String> create(String dir, String label, {String? shortcut, String? app, String? path}) async {
    final safe = label.replaceAll(RegExp(r'[/\\:*?"<>|]'), ' ').trim();
    final name = freeName(dir, '${safe.isEmpty ? 'Shortcut' : safe}.$ext', copySuffix: false);
    final out = '$dir/$name';
    await File(out).writeAsString(content(shortcut: shortcut, app: app, path: path));
    return out;
  }
}

/// Opens a .lnk file. False if it doesn't point anywhere.
Future<bool> openShortcutFile(Desk desk, String path) async {
  final t = ShortcutFile.read(path);
  if (t == null) return false;
  if (t.shortcut != null) return openShortcut(desk, t.shortcut!);
  if (t.app != null) return DeskPlatform.launch(t.app!);
  final p = t.path;
  if (p != null) {
    final type = FileSystemEntity.typeSync(p);
    if (type == FileSystemEntityType.notFound) {
      desk.message('Missing Shortcut', "The item '${baseName(p)}' that this shortcut refers to has been moved or deleted.");
      return true;
    }
    if (type == FileSystemEntityType.directory) {
      desk.openExplorer(p);
    } else {
      await openFileOnDesk(desk, p);
    }
    return true;
  }
  return false;
}

/// Explorer's "Send To > Desktop (create shortcut)".
Future<void> sendToDesktop(Desk desk, List<String> paths) async {
  final dir = desk.desktop.dir;
  if (dir == null) return;
  try {
    for (final p in paths) {
      await ShortcutFile.create(dir, 'Shortcut to ${Places.titleOf(p)}', path: p);
    }
  } catch (e) {
    desk.message('Send To', "Couldn't make the shortcut: ${e is FileSystemException ? e.message : e}");
  }
  FsEvents.instance.changed();
}

// ======================================================================
// Grid layout (pure, tested in test/desktop_icons_test.dart)

typedef Cell = (int, int); // (column, row)

/// Gives every key a grid cell: its saved cell when that fits and is free,
/// otherwise the first free cell going down each column.
Map<String, Cell> layoutIcons(List<String> keys, Map<String, Cell> saved, int cols, int rows) {
  final out = <String, Cell>{};
  final taken = <Cell>{};
  bool fits(Cell c) => c.$1 >= 0 && c.$2 >= 0 && c.$1 < cols && c.$2 < rows;
  for (final k in keys) {
    final s = saved[k];
    if (s != null && fits(s) && !taken.contains(s)) {
      out[k] = s;
      taken.add(s);
    }
  }
  var next = 0;
  for (final k in keys) {
    if (out.containsKey(k)) continue;
    Cell? c;
    while (next < cols * rows) {
      final cand = (next ~/ rows, next % rows);
      next++;
      if (!taken.contains(cand)) {
        c = cand;
        break;
      }
    }
    c ??= (cols - 1, rows - 1); // screen full: pile up in the last cell
    out[k] = c;
    taken.add(c);
  }
  return out;
}

/// The free cell closest to [target] ([target] itself when free).
Cell nearestFree(Cell target, Set<Cell> taken, int cols, int rows) {
  final t = (target.$1.clamp(0, cols - 1), target.$2.clamp(0, rows - 1));
  if (!taken.contains(t)) return t;
  Cell? best;
  var bestD = 1 << 30;
  for (var c = 0; c < cols; c++) {
    for (var r = 0; r < rows; r++) {
      if (taken.contains((c, r))) continue;
      final d = (c - t.$1) * (c - t.$1) * 4 + (r - t.$2) * (r - t.$2);
      if (d < bestD) {
        bestD = d;
        best = (c, r);
      }
    }
  }
  return best ?? t;
}

// ======================================================================
// The desktop's contents

class DeskFile {
  final String path;
  final String name;
  final bool folder;
  final DateTime modified;
  DeskFile(this.path, this.name, this.folder, this.modified);
  String get key => 'f:$name';
}

/// What's on the desktop: the built-in shortcuts that aren't hidden, plus the
/// files in the Desktop folder (on the device when All files access is on,
/// otherwise inside the desktop app), and where each icon sits.
class DesktopModel extends ChangeNotifier {
  DesktopModel() {
    FsEvents.instance.addListener(_onFs);
  }

  String? dir;
  List<DeskFile> files = [];
  Map<String, Cell> cells = {};
  Set<String> hidden = {...kHiddenByDefault};
  bool _loading = false;

  List<DeskShortcut> get shortcuts => kDeskShortcuts.where((s) => !hidden.contains(s.id)).toList();

  /// Icon keys in their natural order.
  List<String> get keys => [
        for (final s in shortcuts) 'sc:${s.id}',
        for (final f in files) f.key,
      ];

  DeskFile? fileFor(String key) {
    for (final f in files) {
      if (f.key == key) return f;
    }
    return null;
  }

  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('deskCells');
      if (raw != null) {
        try {
          final m = Map<String, dynamic>.from(jsonDecode(raw) as Map);
          cells = {
            for (final e in m.entries)
              if (e.value is List && (e.value as List).length == 2)
                e.key: ((e.value as List)[0] as int, (e.value as List)[1] as int),
          };
        } catch (_) {}
      }
      final h = p.getStringList('deskHidden');
      if (h != null) hidden = h.toSet();

      await Places.init(force: true);
      final support = await getApplicationSupportDirectory();
      final private = '${support.path}/Desktop';
      final wanted = Places.hasAccess ? '${Places.root}/Desktop' : private;
      try {
        await Directory(wanted).create(recursive: true);
        dir = wanted;
      } catch (_) {
        await Directory(private).create(recursive: true);
        dir = private;
      }
      // All files access was turned on since: bring the old desktop files over.
      if (dir != private && Directory(private).existsSync()) {
        try {
          for (final e in Directory(private).listSync()) {
            await FileOps.moveInto(e.path, dir!);
          }
        } catch (_) {}
      }
      Places.desktop = dir!;
      await refresh();
    } finally {
      _loading = false;
    }
  }

  void _onFs() => unawaited(refresh());

  Future<void> refresh() async {
    final d = dir;
    if (d == null) return;
    final list = <DeskFile>[];
    try {
      await for (final e in Directory(d).list(followLinks: false)) {
        final name = baseName(e.path);
        if (name.startsWith('.')) continue;
        final folder = e is Directory;
        DateTime mod;
        try {
          mod = (await e.stat()).modified;
        } catch (_) {
          mod = DateTime.now();
        }
        list.add(DeskFile(e.path, name, folder, mod));
      }
    } catch (_) {}
    list.sort((a, b) {
      if (a.folder != b.folder) return a.folder ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    files = list;
    notifyListeners();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('deskCells', jsonEncode({for (final e in cells.entries) e.key: [e.value.$1, e.value.$2]}));
    await p.setStringList('deskHidden', hidden.toList());
  }

  /// Remembers cells for icons that don't have one yet, so they stay put
  /// when other icons come and go.
  void keepCells(Map<String, Cell> layout) {
    var changed = false;
    for (final e in layout.entries) {
      if (!cells.containsKey(e.key)) {
        cells[e.key] = e.value;
        changed = true;
      }
    }
    if (changed) unawaited(_save());
  }

  void saveCells() {
    unawaited(_save());
    notifyListeners();
  }

  void place(String key, Cell c) {
    cells[key] = c;
    unawaited(_save());
    notifyListeners();
  }

  void renamed(String oldKey, String newKey) {
    final c = cells.remove(oldKey);
    if (c != null) cells[newKey] = c;
    unawaited(_save());
  }

  void hide(String id) {
    if (kPinnedShortcuts.contains(id)) return;
    hidden.add(id);
    cells.remove('sc:$id');
    unawaited(_save());
    notifyListeners();
  }

  void unhide(String id) {
    if (!hidden.remove(id)) return;
    unawaited(_save());
    notifyListeners();
  }

  void restoreStandard() {
    hidden = {...kHiddenByDefault};
    unawaited(_save());
    notifyListeners();
  }

  /// Lines the icons up again: shortcuts first, then files by [byType] or name.
  void arrange({bool byType = false}) {
    final fs = List.of(files);
    if (byType) {
      fs.sort((a, b) {
        if (a.folder != b.folder) return a.folder ? -1 : 1;
        final t = typeLabel(a.name, folder: a.folder).compareTo(typeLabel(b.name, folder: b.folder));
        return t != 0 ? t : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    }
    cells.clear();
    _arrangeOrder = [for (final s in shortcuts) 'sc:${s.id}', for (final f in fs) f.key];
    unawaited(_save());
    notifyListeners();
  }

  /// Set by [arrange]: the order to lay icons out in, used once.
  List<String>? _arrangeOrder;
  List<String>? takeArrangeOrder() {
    final o = _arrangeOrder;
    _arrangeOrder = null;
    return o;
  }
}

/// A built-in shortcut being dragged around the desktop.
class ShortcutDrag {
  final String id;
  const ShortcutDrag(this.id);
}

// ======================================================================
// Popup menu in the desktop style

class XpPopupItem {
  final String? label;
  final VoidCallback? onTap;
  final bool bold;
  const XpPopupItem(this.label, this.onTap, {this.bold = false});
  const XpPopupItem.sep()
      : label = null,
        onTap = null,
        bold = false;
}

Future<void> xpPopup(BuildContext context, Offset global, List<XpPopupItem> items) async {
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
              width: 190,
              child: Text(items[i].label!,
                  style: (items[i].bold ? Xp.textBold : Xp.text)
                      .copyWith(color: items[i].onTap == null ? const Color(0xFFACA899) : null)),
            ),
          ),
    ],
  );
  if (v != null) items[v].onTap?.call();
}

// ======================================================================
// The desktop surface: wallpaper area, icons, drag and drop

const double kCellW = 86;
const double kCellH = 86;
const double kIconW = 78;

class DesktopIcons extends StatefulWidget {
  const DesktopIcons({super.key, required this.area, required this.background, this.onBackgroundTap});

  /// Where icons may go (the desk minus any docked window).
  final Rect area;

  /// The wallpaper, drawn underneath.
  final Widget background;
  final VoidCallback? onBackgroundTap;

  @override
  State<DesktopIcons> createState() => _DesktopIconsState();
}

class _DesktopIconsState extends State<DesktopIcons> {
  final _key = GlobalKey();
  String? _selected;
  String? _renaming;
  final _renameCtl = TextEditingController();
  final _renameFocus = FocusNode();
  Map<String, Cell> _layout = {};
  int _cols = 1, _rows = 1;

  Desk get _desk => context.read<Desk>();
  DesktopModel get _model => _desk.desktop;

  @override
  void initState() {
    super.initState();
    _renameFocus.addListener(() {
      if (!_renameFocus.hasFocus && _renaming != null) unawaited(_commitRename());
    });
  }

  @override
  void dispose() {
    _renameCtl.dispose();
    _renameFocus.dispose();
    super.dispose();
  }

  Offset get _origin => Offset(widget.area.left + 8, 10);

  Cell _cellAt(Offset global) {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    final p = (box?.globalToLocal(global) ?? global) - _origin;
    return ((p.dx / kCellW).floor().clamp(0, _cols - 1), (p.dy / kCellH).floor().clamp(0, _rows - 1));
  }

  Set<Cell> _takenExcept(Iterable<String> keys) =>
      {for (final e in _layout.entries) if (!keys.contains(e.key)) e.value};

  /// Puts [key] at (or next to) the cell under [global].
  void _placeAt(String key, Offset global) {
    final c = nearestFree(_cellAt(global), _takenExcept([key]), _cols, _rows);
    _model.place(key, c);
  }

  // ------------------------------------------------------------ drops

  bool _accepts(Object? d) {
    if (d is ShortcutDrag) return true;
    if (d is FileDrag) return d.from != kRecyclePath && d.from != kComputerPath;
    return false;
  }

  Future<void> _dropOnDesk(Object data, Offset global) async {
    if (data is ShortcutDrag) {
      _placeAt('sc:${data.id}', global);
      return;
    }
    if (data is! FileDrag) return;
    final dir = _model.dir;
    if (dir == null) return;
    if (data.from == dir) {
      for (final p in data.paths) {
        _placeAt('f:${baseName(p)}', global);
      }
      return;
    }
    // From an Explorer window: move it onto the desktop (Ctrl copies).
    final copy = HardwareKeyboard.instance.isControlPressed;
    final target = _cellAt(global);
    final taken = _takenExcept(const []);
    try {
      for (final p in data.paths) {
        final dest = copy ? await FileOps.copyInto(p, dir) : await FileOps.moveInto(p, dir);
        final c = nearestFree(target, taken, _cols, _rows);
        taken.add(c);
        _model.cells['f:${baseName(dest)}'] = c;
      }
    } catch (e) {
      _desk.message('Desktop', "Couldn't move it: ${e is FileSystemException ? e.message : e}");
    }
    FsEvents.instance.changed();
    await _model.refresh();
    _model.saveCells();
  }

  Future<void> _dropInFolder(Object data, String folder) async {
    try {
      if (data is ShortcutDrag) {
        final s = shortcutById(data.id);
        if (s == null) return;
        await ShortcutFile.create(folder, s.label, shortcut: s.id);
        _model.hide(s.id);
      } else if (data is FileDrag) {
        final copy = HardwareKeyboard.instance.isControlPressed;
        for (final p in data.paths) {
          if (p == folder) continue;
          if (copy) {
            await FileOps.copyInto(p, folder);
          } else {
            await FileOps.moveInto(p, folder);
          }
        }
      }
    } catch (e) {
      _desk.message('Desktop', "Couldn't move it: ${e is FileSystemException ? e.message : e}");
    }
    FsEvents.instance.changed();
  }

  Future<void> _dropInBin(Object data) async {
    if (data is ShortcutDrag) {
      _model.hide(data.id);
      return;
    }
    if (data is FileDrag) {
      try {
        await RecycleBin.instance.recycle(data.paths);
      } catch (e) {
        _desk.message('Recycle Bin', "Couldn't delete: ${e is FileSystemException ? e.message : e}");
      }
    }
  }

  // ------------------------------------------------------------ actions

  void _open(String key) {
    if (key.startsWith('sc:')) {
      openShortcut(_desk, key.substring(3));
      return;
    }
    final f = _model.fileFor(key);
    if (f == null) return;
    if (f.folder) {
      _desk.openExplorer(f.path);
    } else {
      unawaited(openFileOnDesk(_desk, f.path));
    }
  }

  void _startRename(String key) {
    final f = _model.fileFor(key);
    if (f == null) return;
    setState(() {
      _selected = key;
      _renaming = key;
      _renameCtl.text = f.name;
      final dot = f.folder ? -1 : f.name.lastIndexOf('.');
      _renameCtl.selection = TextSelection(baseOffset: 0, extentOffset: dot > 0 ? dot : f.name.length);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _renameFocus.requestFocus());
  }

  Future<void> _commitRename({bool cancel = false}) async {
    final key = _renaming;
    if (key == null) return;
    setState(() => _renaming = null);
    final f = _model.fileFor(key);
    final name = _renameCtl.text.trim();
    if (cancel || f == null || name.isEmpty || name == f.name) return;
    if (name.contains('/')) {
      _desk.message('Rename', 'A file name can\'t contain a "/".');
      return;
    }
    final dest = '${parentOf(f.path)}/$name';
    if (FileSystemEntity.typeSync(dest, followLinks: false) != FileSystemEntityType.notFound) {
      _desk.message('Rename', "There is already something called '$name' on the desktop.");
      return;
    }
    try {
      await FileOps.moveTo(f.path, dest);
      _model.renamed(key, 'f:$name');
      setState(() => _selected = 'f:$name');
    } catch (e) {
      _desk.message('Rename', "Couldn't rename: ${e is FileSystemException ? e.message : e}");
    }
    FsEvents.instance.changed();
  }

  void _delete(String key) {
    if (key.startsWith('sc:')) {
      final s = shortcutById(key.substring(3));
      if (s == null) return;
      confirmBox(_desk.wm,
          title: 'Confirm Delete',
          text: "Remove the '${s.label}' icon from the desktop? You can put it back with Customize Desktop "
              '(right-click the desktop).',
          icon: Icons.delete_outline,
          onYes: () => _model.hide(s.id));
      return;
    }
    final f = _model.fileFor(key);
    if (f == null) return;
    confirmBox(_desk.wm,
        title: f.folder ? 'Confirm Folder Delete' : 'Confirm File Delete',
        text: "Are you sure you want to send '${f.name}' to the Recycle Bin?",
        icon: Icons.delete_outline,
        onYes: () => unawaited(_dropInBin(FileDrag([f.path], _model.dir ?? ''))));
  }

  Future<void> _newItem(Offset global, {required bool folder}) async {
    final dir = _model.dir;
    if (dir == null) return;
    final name = freeName(dir, folder ? 'New Folder' : 'New Text Document.txt', copySuffix: false);
    try {
      if (folder) {
        await Directory('$dir/$name').create();
      } else {
        await File('$dir/$name').writeAsString('');
      }
    } catch (e) {
      _desk.message('Desktop', "Couldn't create it: ${e is FileSystemException ? e.message : e}");
      return;
    }
    _placeAt('f:$name', global);
    await _model.refresh();
    FsEvents.instance.changed();
    if (mounted) _startRename('f:$name');
  }

  Future<void> _paste(Offset global) async {
    final clip = FileClipboard.instance;
    final dir = _model.dir;
    if (clip.paths.isEmpty || dir == null) return;
    final target = _cellAt(global);
    final taken = _takenExcept(const []);
    try {
      for (final p in clip.paths) {
        final dest = clip.cut ? await FileOps.moveInto(p, dir) : await FileOps.copyInto(p, dir);
        final c = nearestFree(target, taken, _cols, _rows);
        taken.add(c);
        _model.cells['f:${baseName(dest)}'] = c;
      }
      if (clip.cut) clip.clear();
    } catch (e) {
      _desk.message('Paste', "Couldn't paste: ${e is FileSystemException ? e.message : e}");
    }
    FsEvents.instance.changed();
    await _model.refresh();
    _model.saveCells();
  }

  void _properties(String key) {
    final f = _model.fileFor(key);
    if (f == null) {
      if (key == 'sc:display') _desk.openDisplay();
      return;
    }
    _desk.wm.open(propertiesWindow([
      FileProps(
          path: f.path,
          name: f.name,
          folder: f.folder,
          type: ShortcutFile.isShortcut(f.name) ? 'Shortcut' : typeLabel(f.name, folder: f.folder),
          modified: f.modified),
    ]));
  }

  void _iconMenu(String key, Offset global) {
    setState(() => _selected = key);
    final f = _model.fileFor(key);
    final sc = key.startsWith('sc:') ? key.substring(3) : null;
    unawaited(xpPopup(context, global, [
      XpPopupItem('Open', () => _open(key), bold: true),
      if (f != null && !f.folder && kindOf(f.name) == FileKind.text)
        XpPopupItem('Edit in Notepad', () => unawaited(openInNotepad(_desk, f.path))),
      if (sc == 'recycle')
        XpPopupItem('Empty Recycle Bin', RecycleBin.instance.isEmpty ? null : () => unawaited(RecycleBin.instance.empty())),
      if (f != null) ...[
        const XpPopupItem.sep(),
        XpPopupItem('Cut', () => FileClipboard.instance.set([f.path], cut: true)),
        XpPopupItem('Copy', () => FileClipboard.instance.set([f.path], cut: false)),
      ],
      const XpPopupItem.sep(),
      XpPopupItem('Delete', sc != null && kPinnedShortcuts.contains(sc) ? null : () => _delete(key)),
      if (f != null) XpPopupItem('Rename', () => _startRename(key)),
      const XpPopupItem.sep(),
      XpPopupItem('Properties', f != null || sc == 'display' ? () => _properties(key) : null),
    ]));
  }

  void _backgroundMenu(Offset global) {
    setState(() => _selected = null);
    unawaited(xpPopup(context, global, [
      XpPopupItem('Arrange Icons by Name', () => _model.arrange()),
      XpPopupItem('Arrange Icons by Type', () => _model.arrange(byType: true)),
      XpPopupItem('Refresh', () {
        unawaited(_model.refresh());
        unawaited(context.read<AppList>().load(force: true));
      }),
      const XpPopupItem.sep(),
      XpPopupItem('Paste', FileClipboard.instance.paths.isEmpty ? null : () => unawaited(_paste(global))),
      const XpPopupItem.sep(),
      XpPopupItem('New Folder', () => unawaited(_newItem(global, folder: true))),
      XpPopupItem('New Text Document', () => unawaited(_newItem(global, folder: false))),
      const XpPopupItem.sep(),
      XpPopupItem('Customize Desktop...', () => _desk.wm.open(customizeDesktopWindow(_model))),
      XpPopupItem('Open Desktop Folder', _model.dir == null ? null : () => _desk.openExplorer(_model.dir)),
      XpPopupItem('Properties', _desk.openDisplay),
    ]));
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final model = context.watch<DesktopModel>();
    final apps = context.watch<AppList>();
    final area = widget.area;
    _cols = ((area.width - 8) / kCellW).floor().clamp(1, 60);
    _rows = ((area.height - 10) / kCellH).floor().clamp(1, 40);
    final keys = model.keys;
    final order = model.takeArrangeOrder();
    _layout = layoutIcons(order ?? keys, model.cells, _cols, _rows);
    for (final k in keys) {
      _layout[k] ??= (0, 0);
    }
    final layout = _layout;
    WidgetsBinding.instance.addPostFrameCallback((_) => model.keepCells(layout));

    final icons = <Widget>[];
    for (final k in keys) {
      final c = layout[k]!;
      icons.add(Positioned(
        left: _origin.dx + c.$1 * kCellW,
        top: _origin.dy + c.$2 * kCellH,
        child: _buildIcon(k, model, apps),
      ));
    }

    return Stack(key: _key, children: [
      Positioned.fill(
        child: DragTarget<Object>(
          onWillAcceptWithDetails: (d) => _accepts(d.data),
          onAcceptWithDetails: (d) => unawaited(_dropOnDesk(d.data, d.offset)),
          builder: (c, cand, rej) => GestureDetector(
            onTap: () {
              setState(() => _selected = null);
              widget.onBackgroundTap?.call();
            },
            onSecondaryTapUp: (d) => _backgroundMenu(d.globalPosition),
            onLongPressStart: (d) => _backgroundMenu(d.globalPosition),
            child: widget.background,
          ),
        ),
      ),
      ...icons,
    ]);
  }

  Widget _buildIcon(String key, DesktopModel model, AppList apps) {
    final selected = _selected == key;
    late Widget picture;
    late String label;
    String? folderPath;
    var isBin = false;
    var shortcutArrow = false;
    Object dragData;

    if (key.startsWith('sc:')) {
      final s = shortcutById(key.substring(3))!;
      label = s.label;
      isBin = s.id == 'recycle';
      dragData = ShortcutDrag(s.id);
      picture = isBin
          ? ListenableBuilder(
              listenable: RecycleBin.instance,
              builder: (c, _) => _glyph(RecycleBin.instance.isEmpty ? Icons.delete_outline : Icons.delete, s.color),
            )
          : _glyph(s.icon, s.color);
    } else {
      final f = model.fileFor(key)!;
      label = f.name;
      dragData = FileDrag([f.path], model.dir ?? '');
      if (f.folder) folderPath = f.path;
      if (ShortcutFile.isShortcut(f.name)) {
        shortcutArrow = true;
        label = f.name.substring(0, f.name.length - ShortcutFile.ext.length - 1);
        final t = ShortcutFile.read(f.path);
        final s = t?.shortcut == null ? null : shortcutById(t!.shortcut!);
        AndroidApp? app;
        if (t?.app != null) {
          for (final a in apps.apps) {
            if (a.package == t!.app) app = a;
          }
        }
        if (s != null) {
          picture = _glyph(s.icon, s.color);
        } else if (t?.path != null) {
          final tp = t!.path!;
          final isDir = FileSystemEntity.isDirectorySync(tp);
          final (icon, color) = iconFor(kindOf(baseName(tp), folder: isDir));
          picture = _glyph(icon, color);
        } else if (app != null && app.icon.isNotEmpty) {
          picture = Padding(padding: const EdgeInsets.all(2), child: Image.memory(app.icon, width: 40, height: 40));
        } else {
          picture = _glyph(Icons.apps, const Color(0xFFDDE8FF));
        }
      } else {
        final (icon, color) = iconFor(kindOf(f.name, folder: f.folder));
        picture = _glyph(icon, color);
      }
    }

    Widget pic = Container(
      padding: const EdgeInsets.all(2),
      color: selected ? const Color(0x66316AC5) : null,
      child: Stack(children: [
        picture,
        if (shortcutArrow)
          Positioned(
            left: 0,
            bottom: 0,
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(color: Colors.white, border: Border.all(color: const Color(0xFF7A7A7A))),
              child: const Icon(Icons.north_east, size: 11, color: Color(0xFF1E3E9B)),
            ),
          ),
      ]),
    );

    final Widget text;
    if (_renaming == key) {
      text = SizedBox(
        width: kIconW,
        child: KeyboardListener(
          focusNode: FocusNode(skipTraversal: true),
          onKeyEvent: (e) {
            if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
              unawaited(_commitRename(cancel: true));
            }
          },
          child: TextField(
            controller: _renameCtl,
            focusNode: _renameFocus,
            textAlign: TextAlign.center,
            maxLines: 1,
            style: Xp.text.copyWith(fontSize: 12),
            decoration: const InputDecoration(
              isDense: true,
              filled: true,
              fillColor: Colors.white,
              contentPadding: EdgeInsets.symmetric(horizontal: 2, vertical: 3),
              border: OutlineInputBorder(borderRadius: BorderRadius.zero),
            ),
            onSubmitted: (_) => unawaited(_commitRename()),
          ),
        ),
      );
    } else {
      text = Container(
        color: selected ? Xp.selection : null,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            shadows: [Shadow(color: Colors.black, offset: Offset(1, 1), blurRadius: 1)],
          ),
        ),
      );
    }

    Widget tile = GestureDetector(
      onTap: () => setState(() => _selected = key),
      onDoubleTap: () {
        setState(() => _selected = key);
        _open(key);
      },
      onSecondaryTapUp: (d) => _iconMenu(key, d.globalPosition),
      onLongPressStart: (d) => _iconMenu(key, d.globalPosition),
      child: SizedBox(
        width: kIconW,
        child: Column(mainAxisSize: MainAxisSize.min, children: [pic, const SizedBox(height: 3), text]),
      ),
    );

    // Folders and the Recycle Bin take things dropped on them.
    if (folderPath != null || isBin) {
      final inner = tile;
      final fp = folderPath;
      tile = DragTarget<Object>(
        onWillAcceptWithDetails: (d) {
          if (!_accepts(d.data)) return false;
          final data = d.data;
          if (isBin) return !(data is ShortcutDrag && kPinnedShortcuts.contains(data.id));
          if (data is FileDrag) return !data.paths.contains(fp);
          return data is ShortcutDrag && !kPinnedShortcuts.contains(data.id);
        },
        onAcceptWithDetails: (d) => unawaited(isBin ? _dropInBin(d.data) : _dropInFolder(d.data, fp!)),
        builder: (c, cand, rej) => Container(
          decoration: cand.isNotEmpty
              ? BoxDecoration(color: const Color(0x55316AC5), borderRadius: BorderRadius.circular(4))
              : null,
          child: inner,
        ),
      );
    }

    if (_renaming == key) return tile;
    return Draggable<Object>(
      data: dragData,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: () => setState(() => _selected = key),
      feedback: _IconFeedback(picture: picture, label: label),
      childWhenDragging: Opacity(opacity: 0.4, child: tile),
      child: tile,
    );
  }

  static Widget _glyph(IconData icon, Color color) => Icon(icon, size: 40, color: color, shadows: const [
        Shadow(color: Color(0x88000000), offset: Offset(1, 2), blurRadius: 2),
      ]);
}

class _IconFeedback extends StatelessWidget {
  const _IconFeedback({required this.picture, required this.label});
  final Widget picture;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: const Offset(-39, -22),
      child: Opacity(
        opacity: 0.7,
        child: Material(
          type: MaterialType.transparency,
          child: SizedBox(
            width: kIconW,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              picture,
              const SizedBox(height: 3),
              Container(
                color: Xp.selection,
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ======================================================================
// Customize Desktop: tick which built-in icons show

DeskWindow customizeDesktopWindow(DesktopModel model) => DeskWindow(
      id: 'customize-desktop',
      title: 'Desktop Items',
      icon: Icons.desktop_windows,
      size: const Size(380, 470),
      resizable: false,
      canMaximize: false,
      canMinimize: false,
      content: (c, w) => _CustomizeDesktop(model: model, w: w),
    );

class _CustomizeDesktop extends StatefulWidget {
  const _CustomizeDesktop({required this.model, required this.w});
  final DesktopModel model;
  final DeskWindow w;

  @override
  State<_CustomizeDesktop> createState() => _CustomizeDesktopState();
}

class _CustomizeDesktopState extends State<_CustomizeDesktop> {
  late final Set<String> _shown = {
    for (final s in kDeskShortcuts)
      if (!widget.model.hidden.contains(s.id)) s.id,
  };

  void _apply() {
    for (final s in kDeskShortcuts) {
      if (_shown.contains(s.id) || kPinnedShortcuts.contains(s.id)) {
        widget.model.unhide(s.id);
      } else {
        widget.model.hide(s.id);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wm = context.read<Desk>().wm;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Desktop icons', style: Xp.textBold),
        const SizedBox(height: 4),
        const Text('Tick the icons you want on the desktop. Your own files and folders can be deleted '
            'from the desktop like any other file.', style: Xp.textGrey),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Xp.fieldBorder)),
            child: ListView(children: [
              for (final sc in kDeskShortcuts)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  child: Row(children: [
                    Icon(sc.icon, size: 20, color: sc.color == const Color(0xFFFFFFFF) ? Xp.selection : sc.color),
                    const SizedBox(width: 6),
                    Expanded(
                      child: kPinnedShortcuts.contains(sc.id)
                          ? Text('${sc.label} (always shown)', style: Xp.textGrey)
                          : XpCheck(
                              label: sc.label,
                              value: _shown.contains(sc.id),
                              onChanged: (v) => setState(() => v ? _shown.add(sc.id) : _shown.remove(sc.id)),
                            ),
                    ),
                  ]),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          XpButton(
              label: 'Show All',
              onPressed: () => setState(() => _shown.addAll(kDeskShortcuts.map((s) => s.id)))),
          const SizedBox(width: 6),
          XpButton(
              label: 'Hide All',
              onPressed: () => setState(() => _shown.removeWhere((id) => !kPinnedShortcuts.contains(id)))),
          const Spacer(),
          XpButton(
              label: 'OK',
              isDefault: true,
              onPressed: () {
                _apply();
                wm.close(widget.w.id);
              }),
          const SizedBox(width: 6),
          XpButton(label: 'Cancel', onPressed: () => wm.close(widget.w.id)),
        ]),
      ]),
    );
  }
}
