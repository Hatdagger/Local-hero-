import 'dart:io';

import 'package:classic_desk/desk/browser.dart';
import 'package:classic_desk/desk/files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('desk_files_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('names, kinds and sizes', () {
    expect(baseName('/a/b/c.txt'), 'c.txt');
    expect(parentOf('/a/b/c.txt'), '/a/b');
    expect(parentOf('/a'), '/');
    expect(extOf('Song.MP3'), 'mp3');
    expect(extOf('.hidden'), '');
    expect(kindOf('notes.txt'), FileKind.text);
    expect(kindOf('pic.jpeg'), FileKind.image);
    expect(kindOf('song.flac'), FileKind.audio);
    expect(kindOf('page.html'), FileKind.web);
    expect(kindOf('x', folder: true), FileKind.folder);
    expect(typeLabel('a.txt'), 'Text Document');
    expect(formatSize(512), '512 bytes');
    expect(formatSize(2048), '2 KB');
    expect(formatSize(5 * 1024 * 1024 + 300000), '5.3 MB');
    expect(isInside('/a/b/c', '/a/b'), isTrue);
    expect(isInside('/a/bc', '/a/b'), isFalse);
  });

  test('free names for copies', () async {
    final d = tmp.path;
    expect(freeName(d, 'a.txt'), 'a.txt');
    await File('$d/a.txt').writeAsString('x');
    expect(freeName(d, 'a.txt'), 'a - Copy.txt');
    await File('$d/a - Copy.txt').writeAsString('x');
    expect(freeName(d, 'a.txt'), 'a - Copy (2).txt');
    expect(freeName(d, 'a.txt', copySuffix: false), 'a (2).txt');
  });

  test('copy, move and delete folders', () async {
    final src = Directory('${tmp.path}/src/inner');
    await src.create(recursive: true);
    await File('${src.path}/f.txt').writeAsString('hello');
    final dest = Directory('${tmp.path}/dest');
    await dest.create();

    final copied = await FileOps.copyInto('${tmp.path}/src', dest.path);
    expect(copied, '${dest.path}/src');
    expect(await File('$copied/inner/f.txt').readAsString(), 'hello');

    // Copying into the same folder makes "- Copy".
    final again = await FileOps.copyInto('${tmp.path}/src', tmp.path);
    expect(baseName(again), 'src - Copy');

    // A folder can't go inside itself.
    await expectLater(FileOps.moveInto('${tmp.path}/src', '${tmp.path}/src/inner'), throwsA(isA<FileSystemException>()));

    final moved = await FileOps.moveInto('${tmp.path}/src - Copy', dest.path);
    expect(Directory(moved).existsSync(), isTrue);
    expect(Directory('${tmp.path}/src - Copy').existsSync(), isFalse);

    final (bytes, files, _) = await FileOps.measure(dest.path);
    expect(files, 2);
    expect(bytes, 10);

    await FileOps.deleteForever(dest.path);
    expect(dest.existsSync(), isFalse);
  });

  test('recycle bin keeps, restores and empties', () async {
    final bin = RecycleBin.instance;
    await bin.init(preferred: '${tmp.path}/bin', fallback: '${tmp.path}/bin2');
    expect(bin.folder, '${tmp.path}/bin');
    final f = File('${tmp.path}/docs/note.txt');
    await f.create(recursive: true);
    await f.writeAsString('keep me');

    await bin.recycle([f.path]);
    expect(f.existsSync(), isFalse);
    expect(bin.items.length, 1);
    expect(bin.items.first.original, f.path);
    expect(File(bin.pathOf(bin.items.first)).existsSync(), isTrue);

    await bin.restore(List.of(bin.items));
    expect(await f.readAsString(), 'keep me');
    expect(bin.isEmpty, isTrue);

    await bin.recycle([f.path]);
    await bin.empty();
    expect(bin.isEmpty, isTrue);
    expect(f.existsSync(), isFalse);
  });

  test('ad blocking matches ad servers and their subdomains only', () {
    expect(isAdHost('doubleclick.net'), isTrue);
    expect(isAdHost('stats.g.doubleclick.net'), isTrue);
    expect(isAdHost('example.com'), isFalse);
    expect(isAdHost('notdoubleclick.net'), isFalse);
  });
}
