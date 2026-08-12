import 'package:flutter_test/flutter_test.dart';
import 'package:micromart/models/machine_layout.dart';
import 'package:micromart/models/motor_layout.dart';
import 'package:micromart/models/product.dart';
import 'package:micromart/screens/support_screen.dart';
import 'package:micromart/services/vending_service.dart';

Product _p(int motorId, String name) => Product(
      id: 'id-$motorId',
      motorId: motorId,
      shelfLabel: MotorLayout.motorToLabel(motorId),
      name: name,
      priceTenge: 100,
      stock: 5,
    );

void main() {
  test('Motor layout: shelf label ↔ motor id round-trip', () {
    expect(MotorLayout.labelToMotor('001'), 99);
    expect(MotorLayout.labelToMotor('006'), 94);
    expect(MotorLayout.labelToMotor('011'), 89);
    expect(MotorLayout.labelToMotor('056'), 44);
    expect(MotorLayout.motorToLabel(99), '001');
    expect(MotorLayout.motorToLabel(44), '056');
    expect(MotorLayout.allMotors().length, 36);
  });

  group('VendingService.shelveCatalog', () {
    final layout = MachineLayout(shelves: [
      Shelf(label: '1 — 2', slots: [
        Slot(label: '1', motorIds: [99]),
        Slot(label: '2', motorIds: [98]),
      ]),
      Shelf(label: '3', slots: [
        Slot(label: '3', motorIds: [89]),
      ]),
    ]);

    test('drops products no slot claims', () {
      // 77 is wired to nothing in the layout. The storefront never renders
      // it, so the preview must not either — a card with no slot behind it
      // draws without a slot number and makes the toggle look broken.
      final catalog = [_p(99, 'A'), _p(77, 'orphan'), _p(98, 'B')];
      final shelved = VendingService.shelveCatalog(catalog, layout);
      expect(shelved.map((p) => p.name), ['A', 'B']);
    });

    test('orders by the layout, not by the catalog', () {
      final catalog = [_p(89, 'C'), _p(98, 'B'), _p(99, 'A')];
      final shelved = VendingService.shelveCatalog(catalog, layout);
      expect(shelved.map((p) => p.name), ['A', 'B', 'C']);
    });

    test('every returned product resolves to a slot', () {
      // The property the preview actually depends on: ProductCard looks the
      // number up with slotForMotor, so each product it is handed must map.
      final catalog = [_p(99, 'A'), _p(77, 'orphan'), _p(89, 'C')];
      for (final p in VendingService.shelveCatalog(catalog, layout)) {
        expect(layout.slotForMotor(p.motorId), isNotNull,
            reason: 'motor ${p.motorId} has no slot');
      }
    });

    test('skips slots with no product', () {
      final shelved = VendingService.shelveCatalog([_p(98, 'B')], layout);
      expect(shelved.map((p) => p.name), ['B']);
    });

    test('falls back to the raw catalog when no layout is set', () {
      final catalog = [_p(99, 'A'), _p(77, 'orphan')];
      final shelved =
          VendingService.shelveCatalog(catalog, MachineLayout.empty());
      expect(shelved.map((p) => p.name), ['A', 'orphan']);
    });
  });

  group('whatsappDigits', () {
    test('strips the punctuation operators actually type', () {
      expect(whatsappDigits('+7 (700) 123-45-67'), '77001234567');
      expect(whatsappDigits('+7 700 123 45 67'), '77001234567');
    });

    test('rewrites the KZ/RU trunk prefix 8 to the country code 7', () {
      // Dialled as 8 700… inside the country, but wa.me wants the country
      // code. Left alone this produces a link that goes nowhere.
      expect(whatsappDigits('8 700 123 45 67'), '77001234567');
      expect(whatsappDigits('87001234567'), '77001234567');
    });

    test('leaves other numbers alone', () {
      // Not 11 digits, so the trunk-prefix rule must not fire — guessing
      // further would corrupt numbers we do not recognise.
      expect(whatsappDigits('8 800 555'), '8800555');
      expect(whatsappDigits('+44 20 7946 0958'), '442079460958');
    });

    test('returns null when there is nothing dialable', () {
      expect(whatsappDigits(null), isNull);
      expect(whatsappDigits(''), isNull);
      expect(whatsappDigits('—'), isNull);
    });
  });
}
