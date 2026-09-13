import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:webview_cef/webview_cef.dart';

import 'services/local_server_service.dart';
import 'screens/dashboard_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await WebviewManager().initialize(
      userAgent: 'NetOutpostDesktop/1.0 NetOutpostSecure/${LocalServerService().secureToken}',
    );
  }

  runApp(const NetOutpostApp());
}

class NetOutpostApp extends StatelessWidget {
  const NetOutpostApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NetOutpost Companion',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
          surface: const Color(0xFF1E293B), // Slate 800
        ),
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E293B),
          elevation: 0,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
          iconTheme: IconThemeData(color: Colors.white),
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}
