import 'package:classic_desk/desk/window_manager.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

DeskWindow win(String id) => DeskWindow(
      id: id,
      title: id,
      icon: const IconData(0xe000),
      content: (c, w) => const SizedBox(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('opening activates and stacks windows', () {
    final wm = WindowManager();
    wm.open(win('a'));
    wm.open(win('b'));
    expect(wm.activeId, 'b');
    expect(wm.zOrder.map((w) => w.id), ['a', 'b']);
    wm.focus('a');
    expect(wm.zOrder.last.id, 'a');
  });

  test('opening in the background flashes and keeps focus', () {
    final wm = WindowManager();
    wm.open(win('a'));
    wm.open(win('im'), activate: false);
    expect(wm.activeId, 'a');
    expect(wm.byId('im')!.flashing, isTrue);
    expect(wm.zOrder.last.id, 'a');
    wm.focus('im');
    expect(wm.byId('im')!.flashing, isFalse);
  });

  test('Win+M and Shift+Win+M', () {
    final wm = WindowManager();
    wm.open(win('a'));
    wm.open(win('b'));
    wm.minimizeAll();
    expect(wm.zOrder.every((w) => w.minimized), isTrue);
    expect(wm.activeId, isNull);
    wm.undoMinimizeAll();
    expect(wm.zOrder.any((w) => w.minimized), isFalse);
    expect(wm.activeId, isNotNull);
  });

  test('Alt+Tab goes to the previous window and cycles', () {
    final wm = WindowManager();
    wm.open(win('a'));
    wm.open(win('b'));
    wm.open(win('c'));
    wm.startSwitch();
    wm.commitSwitch();
    expect(wm.activeId, 'b');
    wm.startSwitch();
    wm.switchStep();
    wm.commitSwitch();
    expect(wm.activeId, 'a');
  });

  test('taskbar click minimizes the active window and restores it', () {
    final wm = WindowManager();
    wm.open(win('a'));
    wm.taskbarClick('a');
    expect(wm.byId('a')!.minimized, isTrue);
    wm.taskbarClick('a');
    expect(wm.byId('a')!.minimized, isFalse);
    expect(wm.activeId, 'a');
  });

  test('Alt+Space menu: letters and keyboard move', () {
    final wm = WindowManager();
    wm.open(win('a'));
    final start = wm.byId('a')!.rect;
    wm.openMenu('a');
    expect(wm.menuLetter('m'), isTrue);
    expect(wm.kbMode, KbMode.move);
    wm.kbArrow(12, 0);
    wm.kbEnd(keep: false);
    expect(wm.byId('a')!.rect, start);
    wm.openMenu('a');
    wm.menuLetter('x');
    expect(wm.byId('a')!.maximized, isTrue);
    wm.openMenu('a');
    wm.menuLetter('c');
    expect(wm.isOpen('a'), isFalse);
  });

  test('resizing respects the minimum size', () {
    final wm = WindowManager();
    wm.open(win('a'));
    wm.resizeBy('a', Edge.right | Edge.bottom, const Offset(-1000, -1000));
    final r = wm.byId('a')!.rect;
    expect(r.width, 180);
    expect(r.height, 120);
  });
}
