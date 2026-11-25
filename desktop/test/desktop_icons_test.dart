import 'package:classic_desk/desk/desktop_icons.dart';
import 'package:flutter/painting.dart';
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

  test('a group of icons moves together and keeps its spacing', () {
    final layout = {'a': (0, 0), 'b': (0, 1), 'c': (1, 1), 'x': (3, 1)};
    final m = moveGroup(layout, ['a', 'b', 'c'], 'b', (2, 1), 5, 4);
    expect(m['b'], (2, 1));
    expect(m['a'], (2, 0));
    // c would land on x, which is staying put, so it goes next to it
    expect(m['c'], isNot((3, 1)));
    expect(m.containsKey('x'), isFalse);
    expect(m.values.toSet().length, 3);
  });

  test('a group can shift onto cells it is leaving', () {
    final m = moveGroup({'a': (0, 0), 'b': (1, 0)}, ['a', 'b'], 'a', (1, 0), 4, 2);
    expect(m, {'a': (1, 0), 'b': (2, 0)});
  });

  test('selection box picks the icons it touches', () {
    final layout = {'a': (0, 0), 'b': (1, 0), 'c': (0, 2)};
    const origin = Offset(8, 10);
    final box = Rect.fromPoints(const Offset(20, 20), Offset(8 + kCellW + 10, 30));
    expect(iconsInBox(layout, box, origin), {'a', 'b'});
    expect(iconsInBox(layout, const Rect.fromLTWH(600, 600, 5, 5), origin), isEmpty);
  });

  test('shortcut files', () {
    expect(ShortcutFile.parse(ShortcutFile.content(shortcut: 'solitaire'))!.shortcut, 'solitaire');
    expect(ShortcutFile.parse(ShortcutFile.content(app: 'com.foo'))!.app, 'com.foo');
    expect(ShortcutFile.parse(ShortcutFile.content(path: '/storage/My Stuff/a b.txt'))!.path, '/storage/My Stuff/a b.txt');
    expect(ShortcutFile.parse('nothing here'), isNull);
    expect(ShortcutFile.isShortcut('Solitaire.lnk'), isTrue);
  });
}
