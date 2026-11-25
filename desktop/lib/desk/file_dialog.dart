import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'window_manager.dart';
import 'xp_theme.dart';

/// The desktop's own "My Documents" folder (inside the app's storage until
/// the file manager arrives).
Future<Directory> myDocuments() async {
  final base = await getApplicationDocumentsDirectory();
  final d = Directory('${base.path}/My Documents');
  if (!await d.exists()) await d.create(recursive: true);
  return d;
}

enum FileDialogMode { open, save }

/// What the Open dialog hands back: a file in My Documents, or the text of a
/// file picked from elsewhere on the device.
class PickedFile {
  final String name;
  final String? path; // null when it came from another place on the device
  final String? content;
  PickedFile(this.name, {this.path, this.content});
}

/// Open / Save As window listing My Documents.
DeskWindow fileDialogWindow({
  required String owner,
  required FileDialogMode mode,
  required String extension,
  String initialName = '',
  required void Function(PickedFile f) onDone,
}) {
  return DeskWindow(
    id: 'filedlg:$owner',
    title: mode == FileDialogMode.open ? 'Open' : 'Save As',
    icon: mode == FileDialogMode.open ? Icons.folder_open : Icons.save,
    size: const Size(440, 360),
    resizable: false,
    canMaximize: false,
    canMinimize: false,
    content: (c, w) => _FileDialog(w: w, mode: mode, ext: extension, initialName: initialName, onDone: onDone),
  );
}

class _FileDialog extends StatefulWidget {
  const _FileDialog({required this.w, required this.mode, required this.ext, required this.initialName, required this.onDone});
  final DeskWindow w;
  final FileDialogMode mode;
  final String ext;
  final String initialName;
  final void Function(PickedFile f) onDone;

  @override
  State<_FileDialog> createState() => _FileDialogState();
}

class _FileDialogState extends State<_FileDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.initialName);
  List<FileSystemEntity> _files = [];
  Directory? _dir;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await myDocuments();
    final list = d.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    if (!mounted) return;
    setState(() {
      _dir = d;
      _files = list;
    });
  }

  String _base(String path) => path.split('/').last;

  void _finish() {
    final wm = context.read<WindowManager>();
    var n = _name.text.trim();
    if (n.isEmpty || _dir == null) return;
    if (n.contains('/')) {
      setState(() => _error = 'A file name can\'t contain "/".');
      return;
    }
    if (!n.contains('.')) n = '$n.${widget.ext}';
    final path = '${_dir!.path}/$n';
    if (widget.mode == FileDialogMode.open && !File(path).existsSync()) {
      setState(() => _error = "Can't find $n.");
      return;
    }
    wm.close(widget.w.id);
    widget.onDone(PickedFile(n, path: path));
  }

  Future<void> _otherPlace() async {
    final wm = context.read<WindowManager>();
    try {
      final r = await FilePicker.platform.pickFiles(withData: true);
      final f = r?.files.single;
      if (f == null || f.bytes == null) return;
      final text = String.fromCharCodes(f.bytes!);
      wm.close(widget.w.id);
      widget.onDone(PickedFile(f.name, content: _decode(f.bytes!, text)));
    } catch (_) {}
  }

  static String _decode(List<int> bytes, String fallback) {
    try {
      return const Utf8Decoder().convert(bytes);
    } catch (_) {
      return fallback;
    }
  }

  @override
  Widget build(BuildContext context) {
    final wm = context.read<WindowManager>();
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(widget.mode == FileDialogMode.open ? 'Look in: ' : 'Save in: ', style: Xp.text),
          const Icon(Icons.folder, size: 18, color: Color(0xFFE8B84A)),
          const SizedBox(width: 4),
          const Text('My Documents', style: Xp.textBold),
        ]),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Xp.fieldBorder)),
            child: _files.isEmpty
                ? const Center(child: Text('(empty)', style: Xp.textGrey))
                : ListView(children: [
                    for (final f in _files)
                      GestureDetector(
                        onTap: () => setState(() => _name.text = _base(f.path)),
                        onDoubleTap: () {
                          _name.text = _base(f.path);
                          _finish();
                        },
                        child: Container(
                          color: _name.text == _base(f.path) ? Xp.selection : null,
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          child: Row(children: [
                            Icon(Icons.description, size: 16,
                                color: _name.text == _base(f.path) ? Colors.white : const Color(0xFF4A6FB5)),
                            const SizedBox(width: 6),
                            Text(_base(f.path),
                                style: Xp.text.copyWith(color: _name.text == _base(f.path) ? Colors.white : null)),
                          ]),
                        ),
                      ),
                  ]),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          const SizedBox(width: 70, child: Text('File name:', style: Xp.text)),
          Expanded(child: XpField(controller: _name, autofocus: true, onSubmitted: (_) => _finish())),
          const SizedBox(width: 6),
          XpButton(label: widget.mode == FileDialogMode.open ? 'Open' : 'Save', isDefault: true, onPressed: _finish),
        ]),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_error!, style: Xp.text.copyWith(color: const Color(0xFFAA0000))),
          ),
        const SizedBox(height: 6),
        Row(children: [
          if (widget.mode == FileDialogMode.open) XpButton(label: 'Other place...', onPressed: _otherPlace),
          const Spacer(),
          XpButton(label: 'Cancel', onPressed: () => wm.close(widget.w.id)),
        ]),
      ]),
    );
  }
}
