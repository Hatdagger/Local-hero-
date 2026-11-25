import 'package:classic_desk/desk/solitaire_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('deal lays out 28 tableau cards and 24 in the stock', () {
    final g = Klondike(seed: 1);
    expect(g.tableau.fold<int>(0, (a, p) => a + p.length), 28);
    expect(g.stock.length, 24);
    for (var i = 0; i < 7; i++) {
      expect(g.tableau[i].length, i + 1);
      expect(g.tableau[i].last.faceUp, isTrue);
    }
  });

  test('draw three, recycle and undo', () {
    final g = Klondike(seed: 2, drawThree: true);
    g.drawFromStock();
    expect(g.waste.length, 3);
    expect(g.stock.length, 21);
    g.undo();
    expect(g.waste, isEmpty);
    expect(g.stock.length, 24);
    for (var i = 0; i < 8; i++) {
      g.drawFromStock();
    }
    expect(g.stock, isEmpty);
    g.drawFromStock(); // put the waste back
    expect(g.stock.length, 24);
    expect(g.waste, isEmpty);
  });

  test('building rules', () {
    final g = Klondike(seed: 3);
    final redSeven = PlayingCard(Suit.hearts, 7, faceUp: true);
    final blackEight = PlayingCard(Suit.spades, 8, faceUp: true);
    g.tableau[0]
      ..clear()
      ..add(blackEight);
    expect(g.canDrop([redSeven], const PileRef(PileKind.tableau, 0)), isTrue);
    expect(g.canDrop([PlayingCard(Suit.clubs, 7, faceUp: true)], const PileRef(PileKind.tableau, 0)), isFalse);
    g.tableau[1].clear();
    expect(g.canDrop([redSeven], const PileRef(PileKind.tableau, 1)), isFalse);
    expect(g.canDrop([PlayingCard(Suit.hearts, 13, faceUp: true)], const PileRef(PileKind.tableau, 1)), isTrue);
    expect(g.canDrop([PlayingCard(Suit.hearts, 1, faceUp: true)], const PileRef(PileKind.foundation, 0)), isTrue);
    expect(g.canDrop([PlayingCard(Suit.hearts, 2, faceUp: true)], const PileRef(PileKind.foundation, 0)), isFalse);
  });

  test('ace goes home with a double-click and scores 10', () {
    final g = Klondike(seed: 4);
    g.tableau[0]
      ..clear()
      ..add(PlayingCard(Suit.clubs, 1, faceUp: true));
    expect(g.sendHome(const PileRef(PileKind.tableau, 0)), isTrue);
    expect(g.foundations.any((f) => f.length == 1), isTrue);
    expect(g.score, 10);
  });
}
