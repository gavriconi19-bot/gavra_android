import 'package:flutter/material.dart';
import 'package:gavra_android/widgets/v3_seasonal_overlay.dart';

/// Samostalni preview novogodišnjeg overlay-a:
/// flutter run -d web-server -t tools/seasonal_preview.dart --web-port=7399
void main() {
  V3SeasonalOverlay.debugForceActive = true;
  runApp(const _PreviewApp());
}

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const _DemoScreen(),
      builder: (context, child) =>
          V3SeasonalOverlay(child: child ?? const SizedBox.shrink()),
    );
  }
}

class _DemoScreen extends StatelessWidget {
  const _DemoScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0D1B3E), Color(0xFF1E3A6E)],
          ),
        ),
        child: const Center(
          child: Text(
            'Demo ekran — ovako izgleda overlay\npreko bilo kog sadržaja',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 18),
          ),
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Početna'),
          BottomNavigationBarItem(icon: Icon(Icons.directions_bus), label: 'Linije'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Podešavanja'),
        ],
      ),
    );
  }
}
