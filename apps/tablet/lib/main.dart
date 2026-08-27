import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'board/board_client.dart';
import 'screens/home_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/splash_screen.dart';
import 'services/climate_controller.dart';
import 'services/device_storage.dart';
import 'services/supabase_api.dart';
import 'services/idle_service.dart';
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
  // Resolve once and hand it to the API layer: every machine-scoped RPC ships
  // it as x-device-id so _assert_machine can refuse writes from a tablet that
  // no longer holds this machine — without a parameter on eight signatures.
  SupabaseApi.deviceId = await storage.deviceId();
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
        // Global activity tracker — every pointer event on any route
        // updates [IdleService.lastTouchAt]. Lets the catalog screen
        // detect "customer walked away with stuff in the cart" even
        // when the user is on a deeper screen.
        builder: (context, child) {
          return Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => IdleService.instance.touched(),
            onPointerMove: (_) => IdleService.instance.touched(),
            child: child!,
          );
        },
        home: const _Boot(),
      ),
    );
  }
}

/// Holds the branded [SplashScreen] while its bar fills, then cross-fades
/// into the app.
///
/// A brand moment, not a loading gate: DeviceStorage.init() already finished
/// before runApp(), so nothing here is actually being waited on and the bar
/// simply paces [_hold]. That is deliberate rather than decorative — the OS
/// splash cannot carry the wordmark, so this screen exists to show it, and a
/// bar that fills tells the operator the tablet is starting rather than
/// stuck. If a genuine async startup step ever appears, drive [_bar] from it
/// instead of from a fixed duration.
class _Boot extends StatefulWidget {
  const _Boot();

  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> with SingleTickerProviderStateMixin {
  static const _hold = Duration(milliseconds: 1800);
  static const _fade = Duration(milliseconds: 350);

  late final AnimationController _bar =
      AnimationController(vsync: this, duration: _hold)
        ..addStatusListener((s) {
          if (s == AnimationStatus.completed && mounted) {
            setState(() => _handedOver = true);
          }
        })
        ..forward();

  bool _handedOver = false;

  @override
  void dispose() {
    _bar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: _fade,
      child: _handedOver
          ? const _Router()
          // Rebuilt on every tick rather than wrapped in AnimatedBuilder
          // inside SplashScreen: the splash is three static widgets and one
          // bar, and keeping it a plain StatelessWidget taking a double is
          // simpler than threading a Listenable through it.
          : AnimatedBuilder(
              animation: _bar,
              builder: (_, _) => SplashScreen(progress: _bar.value),
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
