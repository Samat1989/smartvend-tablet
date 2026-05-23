import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'board/board_client.dart';
import 'screens/home_screen.dart';
import 'screens/pairing_screen.dart';
import 'services/climate_controller.dart';
import 'services/device_storage.dart';
import 'services/media_service.dart';
import 'services/strings.dart';
import 'services/vending_service.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock orientation — the kiosk is a wall-mounted vertical tablet.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  // Sticky immersive: hide system bars; a swipe shows them transiently and
  // they re-hide on their own. The native MainActivity also enforces this,
  // we set it here too so the very first frame already comes up clean.
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.immersiveSticky,
    overlays: [],
  );
  final storage = DeviceStorage();
  await storage.init();
  runApp(VendingApp(storage: storage));
}

class VendingApp extends StatelessWidget {
  const VendingApp({super.key, required this.storage});

  final DeviceStorage storage;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<DeviceStorage>.value(value: storage),
        ChangeNotifierProvider<Strings>(create: (_) => Strings(storage)),
        ChangeNotifierProvider<MediaService>(create: (_) => MediaService()),
        ChangeNotifierProvider<BoardClient>(
          create: (_) => BoardClient(storage: storage)..autoConnect(),
        ),
        ChangeNotifierProxyProvider<BoardClient, VendingService>(
          create: (ctx) => VendingService(
            board: ctx.read<BoardClient>(),
            storage: storage,
          ),
          update: (_, board, prev) =>
              prev ?? VendingService(board: board, storage: storage),
        ),
        ChangeNotifierProxyProvider<BoardClient, ClimateController>(
          // lazy:false — without this the climate controller isn't
          // constructed until the climate service screen reads it,
          // which means the cooling/heating cycle never starts at
          // app launch. We want the cooler running from the moment
          // the tablet boots.
          lazy: false,
          create: (ctx) =>
              ClimateController(ctx.read<BoardClient>(), storage)..start(),
          update: (_, board, prev) =>
              prev ?? (ClimateController(board, storage)..start()),
        ),
      ],
      child: MaterialApp(
        title: 'M109E Вендинг',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('ru'),
          Locale('kk'),
          Locale('en'),
        ],
        home: const _Router(),
      ),
    );
  }
}

class _Router extends StatelessWidget {
  const _Router();

  @override
  Widget build(BuildContext context) {
    final paired = context.watch<DeviceStorage>().isPaired;
    // Root-level PopScope: the system back button must NEVER close the app
    // at the customer-facing root. Service-mode screens are pushed on top
    // and have their own AppBar back button + can pop normally — only the
    // bottom of the stack (Home / Pairing) is locked.
    return PopScope(
      canPop: false,
      child: paired ? const HomeScreen() : const PairingScreen(),
    );
  }
}
