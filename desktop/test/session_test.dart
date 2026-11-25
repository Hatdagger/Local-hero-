import 'package:classic_desk/desk/session.dart';
import 'package:classic_desk/desk/window_manager.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

DeskWindow win(String id, {String? reopen}) =>
    DeskWindow(id: id, title: id, icon: const IconData(0), content: (c, w) => const SizedBox(), reopen: reopen);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('window kinds share a remembered place', () {
    expect(WindowManager.layoutKey('explorer:12'), 'explorer');
    expect(WindowManager.layoutKey('mediaplayer'), 'mediaplayer');
    expect(WindowManager.layoutKey('aim:im:bob'), 'aim:im:bob');
  });

  test('open windows survive saving and loading', () {
    final list = [
      const SavedWindow('explorer|/storage/emulated/0/Music', Rect.fromLTWH(10, 20, 700, 500), active: true),
      const SavedWindow('player', Rect.fromLTWH(0, 0, 800, 600), maximized: true, minimized: true),
    ];
    final back = SessionCodec.decodeWindows(SessionCodec.encodeWindows(list));
    expect(back.length, 2);
    expect(back[0].reopen, 'explorer|/storage/emulated/0/Music');
    expect(back[0].rect, const Rect.fromLTWH(10, 20, 700, 500));
    expect(back[0].active, isTrue);
    expect(back[1].maximized, isTrue);
    expect(back[1].minimized, isTrue);
    expect(SessionCodec.decodeWindows('rubbish'), isEmpty);
    expect(SessionCodec.decodeWindows('[{"reopen": "x"}]'), isEmpty);
  });

  test('remembered places survive saving and loading', () {
    final back = SessionCodec.decodeBounds(SessionCodec.encodeBounds({
      'explorer': const SavedBounds(Rect.fromLTWH(5, 6, 400, 300), false),
      'mediaplayer': const SavedBounds(Rect.fromLTWH(1, 2, 900, 650), true),
    }));
    expect(back['explorer']!.rect, const Rect.fromLTWH(5, 6, 400, 300));
    expect(back['mediaplayer']!.maximized, isTrue);
  });

  test('only windows that can reopen are saved, bottom to top', () {
    final a = win('explorer:1', reopen: 'explorer|/x');
    final b = win('msg:1');
    final c = win('solitaire');
    final snap = SessionCodec.snapshot([a, b, c], 'solitaire', (w) => w.reopen ?? (w.id == 'solitaire' ? 'solitaire' : null));
    expect(snap.map((s) => s.reopen), ['explorer|/x', 'solitaire']);
    expect(snap.last.active, isTrue);
  });

  test('a window opens where its kind was last time', () {
    final wm = WindowManager()..desk = const Size(1280, 720);
    wm.savedBounds['explorer'] = const SavedBounds(Rect.fromLTWH(100, 80, 600, 400), false);
    final w1 = wm.open(win('explorer:1'));
    expect(w1.rect, const Rect.fromLTWH(100, 80, 600, 400));
    final w2 = wm.open(win('explorer:2'));
    expect(w2.rect.topLeft, const Offset(126, 106)); // stepped so it doesn't hide the first
    w1.rect = const Rect.fromLTWH(300, 200, 500, 350);
    wm.close(w1.id);
    expect(wm.savedBounds['explorer']!.rect, const Rect.fromLTWH(300, 200, 500, 350));
  });
}
