import 'dart:math' as math;

/// Klondike solitaire rules, kept apart from the drawing so they can be tested.

enum Suit { clubs, diamonds, hearts, spades }

extension SuitInfo on Suit {
  bool get red => this == Suit.diamonds || this == Suit.hearts;
  String get symbol => const {Suit.clubs: '♣', Suit.diamonds: '♦', Suit.hearts: '♥', Suit.spades: '♠'}[this]!;
}

class PlayingCard {
  final Suit suit;
  final int rank; // 1 = Ace ... 13 = King
  bool faceUp;
  PlayingCard(this.suit, this.rank, {this.faceUp = false});

  PlayingCard copy() => PlayingCard(suit, rank, faceUp: faceUp);
  String get rankLabel => const ['', 'A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K'][rank];
  @override
  String toString() => '$rankLabel${suit.symbol}${faceUp ? '' : '?'}';
}

enum PileKind { stock, waste, foundation, tableau }

class PileRef {
  final PileKind kind;
  final int index;
  const PileRef(this.kind, [this.index = 0]);
  @override
  bool operator ==(Object o) => o is PileRef && o.kind == kind && o.index == index;
  @override
  int get hashCode => Object.hash(kind, index);
}

class _Snapshot {
  final List<List<PlayingCard>> piles;
  final int score;
  final int passes;
  _Snapshot(this.piles, this.score, this.passes);
}

class Klondike {
  Klondike({this.drawThree = true, int? seed}) {
    deal(seed: seed);
  }

  bool drawThree;
  List<PlayingCard> stock = [];
  List<PlayingCard> waste = [];
  List<List<PlayingCard>> foundations = List.generate(4, (_) => <PlayingCard>[]);
  List<List<PlayingCard>> tableau = List.generate(7, (_) => <PlayingCard>[]);
  int score = 0;
  int passes = 0;
  int moves = 0;
  final List<_Snapshot> _undo = [];

  void deal({int? seed}) {
    final rng = math.Random(seed);
    final deck = [
      for (final s in Suit.values)
        for (var r = 1; r <= 13; r++) PlayingCard(s, r),
    ]..shuffle(rng);
    foundations = List.generate(4, (_) => <PlayingCard>[]);
    tableau = List.generate(7, (_) => <PlayingCard>[]);
    for (var i = 0; i < 7; i++) {
      for (var j = i; j < 7; j++) {
        tableau[j].add(deck.removeLast());
      }
      tableau[i].last.faceUp = true;
    }
    stock = deck;
    waste = [];
    score = 0;
    passes = 0;
    moves = 0;
    _undo.clear();
  }

  List<PlayingCard> pile(PileRef p) => switch (p.kind) {
        PileKind.stock => stock,
        PileKind.waste => waste,
        PileKind.foundation => foundations[p.index],
        PileKind.tableau => tableau[p.index],
      };

  bool get won => foundations.every((f) => f.length == 13);
  bool get canUndo => _undo.isNotEmpty;

  void _save() {
    final all = [stock, waste, ...foundations, ...tableau];
    _undo.add(_Snapshot([for (final p in all) p.map((c) => c.copy()).toList()], score, passes));
    if (_undo.length > 200) _undo.removeAt(0);
  }

  void undo() {
    if (_undo.isEmpty) return;
    final s = _undo.removeLast();
    stock = s.piles[0];
    waste = s.piles[1];
    foundations = s.piles.sublist(2, 6);
    tableau = s.piles.sublist(6, 13);
    score = s.score;
    passes = s.passes;
    moves++;
  }

  void _addScore(int n) => score = math.max(0, score + n);

  /// Clicking the stock: turn over 1 or 3 cards, or put the waste back.
  void drawFromStock() {
    _save();
    if (stock.isEmpty) {
      if (waste.isEmpty) {
        _undo.removeLast();
        return;
      }
      stock = waste.reversed.map((c) => c..faceUp = false).toList();
      waste = [];
      passes++;
      _addScore(drawThree ? (passes > 3 ? -20 : 0) : -100);
    } else {
      final n = math.min(drawThree ? 3 : 1, stock.length);
      for (var i = 0; i < n; i++) {
        waste.add(stock.removeLast()..faceUp = true);
      }
    }
    moves++;
  }

  /// Turning over the face-down top card of a tableau pile.
  bool flip(int t) {
    final p = tableau[t];
    if (p.isEmpty || p.last.faceUp) return false;
    _save();
    p.last.faceUp = true;
    _addScore(5);
    moves++;
    return true;
  }

  /// Can the cards from [from] starting at [index] be picked up?
  bool canPick(PileRef from, int index) {
    final p = pile(from);
    if (index < 0 || index >= p.length || !p[index].faceUp) return false;
    switch (from.kind) {
      case PileKind.stock:
        return false;
      case PileKind.waste:
      case PileKind.foundation:
        return index == p.length - 1;
      case PileKind.tableau:
        return true;
    }
  }

  bool canDrop(List<PlayingCard> cards, PileRef to) {
    if (cards.isEmpty) return false;
    final first = cards.first;
    final target = pile(to);
    switch (to.kind) {
      case PileKind.foundation:
        if (cards.length != 1) return false;
        if (target.isEmpty) return first.rank == 1;
        return target.last.suit == first.suit && target.last.rank + 1 == first.rank;
      case PileKind.tableau:
        if (target.isEmpty) return first.rank == 13;
        final top = target.last;
        return top.faceUp && top.suit.red != first.suit.red && top.rank == first.rank + 1;
      default:
        return false;
    }
  }

  /// Moves the cards from [from] (starting at [index]) to [to]. False if not allowed.
  bool move(PileRef from, int index, PileRef to) {
    if (from == to || !canPick(from, index)) return false;
    final src = pile(from);
    final cards = src.sublist(index);
    if (!canDrop(cards, to)) return false;
    _save();
    src.removeRange(index, src.length);
    pile(to).addAll(cards);
    // Standard scoring.
    if (to.kind == PileKind.foundation && from.kind != PileKind.foundation) _addScore(10);
    if (from.kind == PileKind.waste && to.kind == PileKind.tableau) _addScore(5);
    if (from.kind == PileKind.foundation && to.kind == PileKind.tableau) _addScore(-15);
    moves++;
    return true;
  }

  /// Double-click: send the top card of [from] to a foundation if it fits.
  bool sendHome(PileRef from) {
    final p = pile(from);
    if (p.isEmpty || from.kind == PileKind.foundation) return false;
    for (var f = 0; f < 4; f++) {
      if (move(from, p.length - 1, PileRef(PileKind.foundation, f))) return true;
    }
    return false;
  }

  /// Right-click: send every card that can go up, until none can.
  int autoPlay() {
    var n = 0;
    var progress = true;
    while (progress) {
      progress = false;
      for (final from in [const PileRef(PileKind.waste), for (var i = 0; i < 7; i++) PileRef(PileKind.tableau, i)]) {
        if (sendHome(from)) {
          n++;
          progress = true;
        }
      }
    }
    return n;
  }
}
