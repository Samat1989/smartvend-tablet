import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:micromart/screens/pairing_screen.dart';
import 'package:micromart/services/device_storage.dart';
import 'package:micromart/services/strings.dart';

/// The pairing screen with [notice] already stored, as it would be after the
/// tablet unpaired itself and restarted.
Future<DeviceStorage> _pump(WidgetTester tester, {String? notice}) async {
  SharedPreferences.setMockInitialValues({'unpair_notice': ?notice});
  // Without it DeviceStorage.init() waits forever on the Keystore channel —
  // there is no platform under `flutter test` to answer it.
  FlutterSecureStorage.setMockInitialValues({});
  final storage = DeviceStorage();
  await storage.init();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: storage),
        ChangeNotifierProvider(create: (_) => Strings(storage)),
      ],
      child: const MaterialApp(
        localizationsDelegates: [DefaultMaterialLocalizations.delegate],
        home: PairingScreen(),
      ),
    ),
  );
  await tester.pump();
  return storage;
}

void main() {
  testWidgets('a tablet unbound from the panel says so', (tester) async {
    await _pump(tester, notice: 'unpair_released');
    expect(
      find.textContaining('отвязали', findRichText: true),
      findsOneWidget,
      reason: 'the installer must be told the machine was taken away on '
          'purpose, not left to hunt for a fault',
    );
  });

  testWidgets('a tablet replaced by another says something else',
      (tester) async {
    await _pump(tester, notice: 'unpair_taken');
    expect(find.textContaining('другому планшету'), findsOneWidget);
  });

  testWidgets('an operator who signed out is told nothing', (tester) async {
    await _pump(tester);
    expect(find.byIcon(Icons.link_off), findsNothing);
  });

  testWidgets('the notice can be put down and stays down', (tester) async {
    final storage = await _pump(tester, notice: 'unpair_released');
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.byIcon(Icons.link_off), findsNothing);
    expect(storage.unpairNotice, isNull);
  });
}
