import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/config_storage.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = await ConfigStorage.open();
  runApp(ProvisionApp(storage: storage));
}

class ProvisionApp extends StatelessWidget {
  const ProvisionApp({super.key, required this.storage});

  final ConfigStorage storage;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smartvend Provision QR',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0088FF),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F6FA),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black87,
          elevation: 0,
          centerTitle: false,
        ),
      ),
      home: HomeScreen(storage: storage),
    );
  }
}
