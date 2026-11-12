import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:micromart/services/idle_service.dart';
import 'package:micromart/widgets/idle_return_timer.dart';

void main() {
  test('formatIdleRemaining', () {
    expect(formatIdleRemaining(const Duration(seconds: 120)), '2:00');
    expect(formatIdleRemaining(const Duration(seconds: 65)), '1:05');
    expect(formatIdleRemaining(const Duration(seconds: -3)), '0:00');
  });

  testWidgets('возвращает на первый маршрут через timeout без касаний',
      (tester) async {
    var fake = DateTime(2026, 1, 1);
    IdleService.instance.now = () => fake;
    addTearDown(() => IdleService.instance.now = DateTime.now);
    Future<void> advance(int sec) async {
      for (var i = 0; i < sec; i++) {
        fake = fake.add(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
      }
    }

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (c) => ElevatedButton(
          onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(
            builder: (_) => IdleReturnTimer(
              timeout: const Duration(seconds: 3),
              builder: (_, left) => Text('left ${left.inSeconds}'),
            ),
          )),
          child: const Text('home'),
        ),
      ),
    ));
    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();
    expect(find.textContaining('left'), findsOneWidget);

    await advance(1);
    IdleService.instance.touched(); // касание сбрасывает отсчёт
    await advance(2);
    expect(find.textContaining('left'), findsOneWidget);

    await advance(4);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });
}
