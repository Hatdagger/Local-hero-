import 'package:classic_desk/desk/desktop_icons.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('icons keep saved cells and fill gaps down each column', () {
    final l = layoutIcons(['a', 'b', 'c', 'd'], {'b': (2, 1), 'c': (2, 1)}, 3, 2);
    expect(l['b'], (2, 1));
    expect(l['a'], (0, 0));
    expect(l['c'], (0, 1)); // its saved cell was taken by b
    expect(l['d'], (1, 0));
  });

  test('saved cells off screen are reflowed', () {
    final l = layoutIcons(['a'], {'a': (9, 9)}, 2, 2);
    expect(l['a'], (0, 0));
  });

  test('nearest free cell', () {
    expect(nearestFree((1, 1), {}, 3, 3), (1, 1));
    expect(nearestFree((1, 1), {(1, 1)}, 3, 3), anyOf((1, 0), (1, 2)));
    expect(nearestFree((5, 5), {}, 3, 3), (2, 2));
  });

  test('shortcut files', () {
    expect(ShortcutFile.parse(ShortcutFile.content(shortcut: 'solitaire'))!.shortcut, 'solitaire');
    expect(ShortcutFile.parse(ShortcutFile.content(app: 'com.foo'))!.app, 'com.foo');
    expect(ShortcutFile.parse(ShortcutFile.content(path: '/storage/My Stuff/a b.txt'))!.path, '/storage/My Stuff/a b.txt');
    expect(ShortcutFile.parse('nothing here'), isNull);
    expect(ShortcutFile.isShortcut('Solitaire.lnk'), isTrue);
  });
}
