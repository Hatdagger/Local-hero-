import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'file_dialog.dart';
import 'window_manager.dart';
import 'xp_theme.dart';

int _notepadCount = 0;

DeskWindow notepadWindow({String? path, String? name, String? content}) {
  final id = 'notepad:${_notepadCount++}';
  return DeskWindow(
    id: id,
    title: '${name ?? 'Untitled'} - Notepad',
    icon: Icons.description,
    size: const Size(560, 420),
    minSize: const Size(240, 160),
    content: (c, w) => _Notepad(w: w, path: path, name: name, initial: content),
  );
}

class _Notepad extends StatefulWidget {
  const _Notepad({required this.w, this.path, this.name, this.initial});
  final DeskWindow w;
  final String? path;
  final String? name;
  final String? initial;

  @override
  State<_Notepad> createState() => _NotepadState();
}

enum _After { nothing, close, newFile, open }

class _NotepadState extends State<_Notepad> {
  final _text = TextEditingController();
  final _undo = UndoHistoryController();
  final _focus = FocusNode();
  final _hScroll = ScrollController();
  String? _path;
  String _name = 'Untitled';
  String _saved = '';
  bool _wrap = true;
  double _fontSize = 14;
  bool _mono = true;
  bool _asking = false;
  _After _after = _After.nothing;
  String? _status;

  bool get _dirty => _text.text != _saved;
  WindowManager get _wm => context.read<WindowManager>();

  @override
  void initState() {
    super.initState();
    _path = widget.path;
    _name = widget.name ?? 'Untitled';
    if (widget.initial != null) {
      _text.text = widget.initial!;
      // Opened from another place on the device: not saved here yet.
      _saved = widget.path == null ? '' : widget.initial!;
    } else if (widget.path != null) {
      try {
        _text.text = File(widget.path!).readAsStringSync();
      } catch (_) {}
      _saved = _text.text;
    }
    widget.w.beforeClose = () {
      if (!_dirty) return true;
      _ask(_After.close);
      return false;
    };
    _text.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _undo.dispose();
    _focus.dispose();
    _hScroll.dispose();
    super.dispose();
  }

  void _setName(String name, String? path) {
    _name = name;
    _path = path;
    _wm.setTitle(widget.w.id, '$name - Notepad');
  }

  // ------------------------------------------------------------ file

  void _ask(_After after) {
    setState(() {
      _asking = true;
      _after = after;
    });
  }

  void _continue() {
    final a = _after;
    _after = _After.nothing;
    switch (a) {
      case _After.close:
        _wm.close(widget.w.id, force: true);
      case _After.newFile:
        _newNow();
      case _After.open:
        _openNow();
      case _After.nothing:
        break;
    }
  }

  void _new() => _dirty ? _ask(_After.newFile) : _newNow();

  void _newNow() {
    _text.text = '';
    _saved = '';
    _setName('Untitled', null);
  }

  void _open() => _dirty ? _ask(_After.open) : _openNow();

  void _openNow() {
    _wm.open(fileDialogWindow(
      owner: widget.w.id,
      mode: FileDialogMode.open,
      extension: 'txt',
      onDone: (f) {
        if (!mounted) return;
        String content = f.content ?? '';
        if (f.path != null) {
          try {
            content = File(f.path!).readAsStringSync();
          } catch (_) {
            _status = "Couldn't read ${f.name}";
          }
        }
        _text.text = content;
        _saved = f.path == null ? '' : content;
        _setName(f.name, f.path);
        _wm.focus(widget.w.id);
      },
    ));
  }

  /// Saves; returns false if it had to ask for a name first.
  bool _save() {
    if (_path == null) {
      _saveAs();
      return false;
    }
    try {
      File(_path!).writeAsStringSync(_text.text);
      setState(() {
        _saved = _text.text;
        _status = 'Saved $_name';
      });
      return true;
    } catch (e) {
      setState(() => _status = "Couldn't save: $e");
      return false;
    }
  }

  void _saveAs() {
    _wm.open(fileDialogWindow(
      owner: widget.w.id,
      mode: FileDialogMode.save,
      extension: 'txt',
      initialName: _name == 'Untitled' ? '' : _name,
      onDone: (f) {
        if (!mounted) return;
        _setName(f.name, f.path);
        _wm.focus(widget.w.id);
        if (_save()) _continue();
      },
    ));
  }

  // ------------------------------------------------------------ edit

  void _cut() {
    _copy();
    _replaceSelection('');
  }

  void _copy() {
    final s = _text.selection;
    if (!s.isValid || s.isCollapsed) return;
    Clipboard.setData(ClipboardData(text: s.textInside(_text.text)));
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (d?.text != null) _replaceSelection(d!.text!);
  }

  void _replaceSelection(String with_) {
    final s = _text.selection;
    final t = _text.text;
    final start = s.isValid ? s.start : t.length;
    final end = s.isValid ? s.end : t.length;
    _text.value = TextEditingValue(
      text: t.replaceRange(start, end, with_),
      selection: TextSelection.collapsed(offset: start + with_.length),
    );
    _focus.requestFocus();
  }

  void _selectAll() {
    _text.selection = TextSelection(baseOffset: 0, extentOffset: _text.text.length);
    _focus.requestFocus();
  }

  void _timeDate() {
    final n = DateTime.now();
    final h = n.hour % 12 == 0 ? 12 : n.hour % 12;
    final stamp = '$h:${n.minute.toString().padLeft(2, '0')} ${n.hour < 12 ? 'AM' : 'PM'} ${n.month}/${n.day}/${n.year}';
    _replaceSelection(stamp);
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: _fontSize,
      color: Colors.black,
      fontFamily: _mono ? 'monospace' : null,
      height: 1.3,
    );
    Widget field = TextField(
      controller: _text,
      focusNode: _focus,
      undoController: _undo,
      maxLines: null,
      expands: _wrap,
      keyboardType: TextInputType.multiline,
      style: style,
      decoration: const InputDecoration(border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.all(4)),
    );
    if (!_wrap) {
      // No word wrap: a very wide page you can scroll sideways.
      field = Scrollbar(
        controller: _hScroll,
        child: SingleChildScrollView(
          controller: _hScroll,
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: 3000, child: SingleChildScrollView(child: field)),
        ),
      );
    }

    final body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      XpMenuBar(menus: [
        ('File', [
          MenuBarEntry('New', _new, shortcut: 'Ctrl+N'),
          MenuBarEntry('Open...', _open, shortcut: 'Ctrl+O'),
          MenuBarEntry('Save', _save, shortcut: 'Ctrl+S'),
          MenuBarEntry('Save As...', _saveAs),
          const MenuBarEntry.separator(),
          MenuBarEntry('Exit', () => _wm.close(widget.w.id)),
        ]),
        ('Edit', [
          MenuBarEntry('Undo', _undo.value.canUndo ? _undo.undo : null, shortcut: 'Ctrl+Z'),
          const MenuBarEntry.separator(),
          MenuBarEntry('Cut', _cut, shortcut: 'Ctrl+X'),
          MenuBarEntry('Copy', _copy, shortcut: 'Ctrl+C'),
          MenuBarEntry('Paste', _paste, shortcut: 'Ctrl+V'),
          MenuBarEntry('Delete', () => _replaceSelection(''), shortcut: 'Del'),
          const MenuBarEntry.separator(),
          MenuBarEntry('Select All', _selectAll, shortcut: 'Ctrl+A'),
          MenuBarEntry('Time/Date', _timeDate, shortcut: 'F5'),
        ]),
        ('Format', [
          MenuBarEntry('Word Wrap', () => setState(() => _wrap = !_wrap), checked: _wrap),
          MenuBarEntry('Typewriter Font', () => setState(() => _mono = !_mono), checked: _mono),
          const MenuBarEntry.separator(),
          MenuBarEntry('Bigger Text', () => setState(() => _fontSize = (_fontSize + 2).clamp(9, 40).toDouble())),
          MenuBarEntry('Smaller Text', () => setState(() => _fontSize = (_fontSize - 2).clamp(9, 40).toDouble())),
        ]),
      ]),
      Expanded(
        child: Container(
          decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Xp.fieldBorder)),
          child: field,
        ),
      ),
      Container(
        height: 20,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.centerLeft,
        child: Text(_status ?? (_path == null ? '' : 'My Documents\\$_name'),
            style: Xp.text.copyWith(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    ]);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () => _save(),
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): _open,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _new,
        const SingleActivator(LogicalKeyboardKey.f5): _timeDate,
      },
      child: Stack(children: [
        Positioned.fill(child: body),
        if (_asking) ...[
          const Positioned.fill(child: ColoredBox(color: Color(0x22000000))),
          Center(
            child: Container(
              width: 330,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Xp.face,
                border: Border.all(color: Xp.frame, width: 2),
                boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 6, offset: Offset(2, 2))],
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  const Icon(Icons.warning_amber_rounded, size: 32, color: Color(0xFFE0A800)),
                  const SizedBox(width: 10),
                  Expanded(child: Text('Do you want to save the changes to $_name?', style: Xp.text)),
                ]),
                const SizedBox(height: 14),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  XpButton(
                      label: 'Yes',
                      isDefault: true,
                      onPressed: () {
                        setState(() => _asking = false);
                        if (_save()) _continue();
                      }),
                  const SizedBox(width: 6),
                  XpButton(
                      label: 'No',
                      onPressed: () {
                        setState(() => _asking = false);
                        _saved = _text.text;
                        _continue();
                      }),
                  const SizedBox(width: 6),
                  XpButton(
                      label: 'Cancel',
                      onPressed: () => setState(() {
                            _asking = false;
                            _after = _After.nothing;
                          })),
                ]),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}
