import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:micromart/models/product.dart';
import 'package:micromart/screens/screensaver_screen.dart';
import 'package:micromart/services/device_storage.dart';
import 'package:micromart/services/strings.dart';

Future<void> _pumpShelf(WidgetTester tester, {required int columns}) async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  final storage = DeviceStorage();
  await storage.init();
  await tester.binding.setSurfaceSize(const Size(533, 853)); // 800x1280 @ 240 dpi
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: storage),
        ChangeNotifierProvider(create: (_) => Strings(storage)),
      ],
      child: MaterialApp(
        localizationsDelegates: const [DefaultMaterialLocalizations.delegate],
        home: Scaffold(
          body: ShelfSlideView(
            shelf: ShelfData(label: '1 — 6', products: [
              for (var i = 1; i <= 6; i++)
                Product(motorId: 100 - i, shelfLabel: '$i', name: 'Т$i', priceTenge: 100),
            ]),
            index: 0,
            total: 1,
            columns: columns,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final cols in [2, 3]) {
    testWidgets('полка скринсейвера рисуется в $cols колонки на узком экране',
        (tester) async {
      await _pumpShelf(tester, columns: cols);
      final grid = tester.widget<GridView>(find.byType(GridView));
      final d = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(d.crossAxisCount, cols);
    });
  }

  group('clipHasEnded', () {
    const d = Duration(seconds: 10);
    test('в конце при остановке — да', () {
      expect(clipHasEnded(position: d, duration: d, isPlaying: false), isTrue);
      expect(
          clipHasEnded(
              position: const Duration(milliseconds: 9800),
              duration: d,
              isPlaying: false),
          isTrue);
    });
    test('играет или не дошло — нет', () {
      expect(clipHasEnded(position: d, duration: d, isPlaying: true), isFalse);
      expect(
          clipHasEnded(
              position: const Duration(seconds: 5),
              duration: d,
              isPlaying: false),
          isFalse);
    });
    test('длительность неизвестна — нет', () {
      expect(
          clipHasEnded(
              position: Duration.zero, duration: Duration.zero, isPlaying: false),
          isFalse);
    });
  });
}
