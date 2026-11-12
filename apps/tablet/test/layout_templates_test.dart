import 'package:flutter_test/flutter_test.dart';
import 'package:micromart/models/machine_layout.dart';

List<int> _motors(Shelf s) => [for (final sl in s.slots) sl.primaryMotorId];
List<String> _labels(Shelf s) => [for (final sl in s.slots) sl.label];

void main() {
  group('factory6x6Twin3', () {
    final l = LayoutTemplate.factory6x6Twin3.build();

    test('6 полок, на 1–2 по 3 слота, на 3–6 по 6', () {
      expect(l.shelves.map((s) => s.slots.length), [3, 3, 6, 6, 6, 6]);
    });

    test('моторы и подписи', () {
      expect(_motors(l.shelves[0]), [99, 98, 97]);
      expect(_motors(l.shelves[1]), [89, 88, 87]);
      expect(_motors(l.shelves[2]), [79, 78, 77, 76, 75, 74]);
      expect(_motors(l.shelves[5]), [49, 48, 47, 46, 45, 44]);
      expect(_labels(l.shelves[0]), ['001', '002', '003']);
      expect(_labels(l.shelves[1]), ['011', '012', '013']);
      expect(l.shelves[1].label, '011 — 013');
    });

    test('нижние полки совпадают с заводской', () {
      final f = LayoutTemplate.factory6x6.build();
      for (var i = 2; i < 6; i++) {
        expect(_motors(l.shelves[i]), _motors(f.shelves[i]));
        expect(_labels(l.shelves[i]), _labels(f.shelves[i]));
      }
    });
  });

  group('factory3x5Twin3x10', () {
    final l = LayoutTemplate.factory3x5Twin3x10.build();

    test('3 полки по 5 и 3 по 10', () {
      expect(l.shelves.map((s) => s.slots.length), [5, 5, 5, 10, 10, 10]);
    });

    test('моторы и подписи', () {
      expect(_motors(l.shelves[0]), [99, 98, 97, 96, 95]);
      expect(_motors(l.shelves[2]), [79, 78, 77, 76, 75]);
      expect(_motors(l.shelves[3]),
          [69, 68, 67, 66, 65, 64, 63, 62, 61, 60]);
      expect(_motors(l.shelves[5]).last, 40);
      expect(_labels(l.shelves[2]).first, '021');
      expect(l.shelves[3].label, '031 — 040');
      expect(l.shelves[5].label, '051 — 060');
    });

    test('моторы и подписи не повторяются', () {
      final m = l.allUsedMotorIds;
      expect(m.length, 45);
      final labels = {for (final s in l.shelves) ..._labels(s)};
      expect(labels.length, 45);
    });
  });

  test('id шаблонов уникальны', () {
    final ids = LayoutTemplate.all.map((t) => t.id).toList();
    expect(ids.toSet().length, ids.length);
  });
}
