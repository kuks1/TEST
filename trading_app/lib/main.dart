import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'core/app_theme.dart';
import 'core/config.dart';
import 'core/database.dart';
import 'core/qt_monitor.dart';
import 'screens/home_screen.dart';
import 'screens/trade_log_screen.dart';

/// 전역 테마 버전 — increment하면 MaterialApp이 새 ThemeData로 재빌드됨
final themeNotifier = ValueNotifier<int>(0);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  await AppDatabase.init();
  await Config.load();
  QTMonitor.start();

  ErrorWidget.builder = (FlutterErrorDetails details) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF0D1117),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(
            details.toString(),
            style: const TextStyle(
              color: Color(0xFFF85149),
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ),
    );
  };

  runApp(const TradingApp());
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  // 탭 순서: 홈(0) → 기록(1)
  int _index = 0;
  final _keys = [UniqueKey(), UniqueKey()];

  void _onTap(int i) {
    setState(() {
      _keys[i] = UniqueKey();
      _index = i;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          HomeScreen(key: _keys[0]),
          TradeLogScreen(key: _keys[1]),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: _onTap,
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined),
              activeIcon: Icon(Icons.home),
              label: '홈'),
          BottomNavigationBarItem(
              icon: Icon(Icons.history_outlined),
              activeIcon: Icon(Icons.history),
              label: '기록'),
        ],
      ),
    );
  }
}

class TradingApp extends StatelessWidget {
  const TradingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: themeNotifier,
      builder: (_, __, ___) => MaterialApp(
        title: 'Gold Mine',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.buildTheme(),
        home: const AppShell(),
      ),
    );
  }
}
