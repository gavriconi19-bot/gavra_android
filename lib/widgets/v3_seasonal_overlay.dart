import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Novogodišnji dekorativni overlay — aktivan od 15. decembra do 15. januara.
/// Ubacuje se kroz MaterialApp.builder i crta se preko svih ekrana,
/// nezavisno od izabrane teme. IgnorePointer — ne blokira dodir.
class V3SeasonalOverlay extends StatefulWidget {
  const V3SeasonalOverlay({required this.child, super.key});

  final Widget child;

  /// Debug/preview prekidač — postavi na true da se overlay prikaže van sezone.
  static bool debugForceActive = false;

  static bool get isActive {
    if (debugForceActive) return true;
    final now = DateTime.now();
    return (now.month == 12 && now.day >= 15) || (now.month == 1 && now.day <= 15);
  }

  @override
  State<V3SeasonalOverlay> createState() => _V3SeasonalOverlayState();
}

class _V3SeasonalOverlayState extends State<V3SeasonalOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<_Flake> _flakes;
  Timer? _greetingTimer;

  /// Čestitka se prikazuje od 1. do 15. januara (sneg/venčić od 15. decembra).
  bool get _showGreeting {
    if (V3SeasonalOverlay.debugForceActive) return true;
    final now = DateTime.now();
    return now.month == 1 && now.day <= 15;
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    );
    // Ticker ne radi van sezone — nula potrošnje ostatak godine.
    if (V3SeasonalOverlay.isActive) {
      _controller.repeat();
      _scheduleGreetingAtMidnight();
    }
    final rng = math.Random(20261215);
    _flakes = List.generate(45, (_) => _Flake(rng));
  }

  /// Okida rebuild tačno u ponoć na Novu godinu ako je app tada otvoren.
  void _scheduleGreetingAtMidnight() {
    final now = DateTime.now();
    if (now.month != 12) return;
    _greetingTimer = Timer(
      DateTime(now.year + 1, 1, 1).difference(now),
      () => setState(() {}),
    );
  }

  @override
  void dispose() {
    _greetingTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!V3SeasonalOverlay.isActive) return widget.child;
    return Stack(
      children: [
        widget.child,
        // Sneg
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(painter: _SnowPainter(_flakes, _controller)),
            ),
          ),
        ),
        // Venčić sa lampicama duž gornje ivice
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 46,
          child: IgnorePointer(
            child: CustomPaint(painter: _GarlandPainter()),
          ),
        ),
        // Čestitka u centru, u "uvaliji" venčića — od 1. do 15. januara
        if (_showGreeting)
          Positioned(
            top: 6,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: Text(
                  _greetingFor(Localizations.localeOf(context).languageCode),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
                  ),
                ),
              ),
            ),
          ),
        // Deda mraz i sneško u donjim uglovima
        const Positioned(
          bottom: 10,
          right: 8,
          child: IgnorePointer(
            child: Opacity(opacity: 0.9, child: Text('🎅', style: TextStyle(fontSize: 36))),
          ),
        ),
        const Positioned(
          bottom: 10,
          left: 8,
          child: IgnorePointer(
            child: Opacity(opacity: 0.9, child: Text('⛄', style: TextStyle(fontSize: 34))),
          ),
        ),
      ],
    );
  }
}

String _greetingFor(String languageCode) => switch (languageCode) {
      'en' => 'Happy New Year',
      'ru' => 'С Новым Годом',
      'de' => 'Frohes neues Jahr',
      'zh' => '\u{65b0}\u{5e74}\u{5feb}\u{4e50}',
      _ => 'Srećna Nova Godina',
    };

class _Flake {
  _Flake(math.Random rng)
      : x = rng.nextDouble(),
        seed = rng.nextDouble(),
        cycles = 0.7 + rng.nextDouble() * 1.6,
        radius = 1.2 + rng.nextDouble() * 2.6,
        sway = 6 + rng.nextDouble() * 22,
        phase = rng.nextDouble() * math.pi * 2,
        opacity = 0.35 + rng.nextDouble() * 0.55;

  final double x; // početna X pozicija (0-1 širine)
  final double seed; // fazni pomak vertikale
  final double cycles; // koliko puta padne za jedan period animacije
  final double radius;
  final double sway; // amplituda lelujanja u px
  final double phase;
  final double opacity;
}

class _SnowPainter extends CustomPainter {
  _SnowPainter(this.flakes, this.animation) : super(repaint: animation);

  final List<_Flake> flakes;
  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value;
    final paint = Paint()..color = Colors.white;
    for (final f in flakes) {
      final progress = (f.seed + t * f.cycles) % 1.0;
      final dx = f.x * size.width + math.sin(progress * math.pi * 2 + f.phase) * f.sway;
      final dy = progress * (size.height + 24) - 12;
      paint.color = Colors.white.withOpacity(f.opacity);
      canvas.drawCircle(Offset(dx, dy), f.radius, paint);
    }
  }

  @override
  bool shouldRepaint(_SnowPainter oldDelegate) => false;
}

class _GarlandPainter extends CustomPainter {
  static const _bulbColors = [
    Color(0xFFE53935), // crvena
    Color(0xFFFDD835), // zlatna
    Color(0xFF43A047), // zelena
    Color(0xFF1E88E5), // plava
  ];

  @override
  void paint(Canvas canvas, Size size) {
    const sag = 34.0;
    const bulbs = 14;
    final line = Paint()
      ..color = const Color(0xFF1B5E20).withOpacity(0.85)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    // Tanka grančica koja visi u obliku U krive
    final path = Path()
      ..moveTo(0, 2)
      ..quadraticBezierTo(size.width / 2, sag * 2.2, size.width, 2);
    canvas.drawPath(path, line);

    // Lampice duž krive — t parametar na kvadratnoj Bezije krivoj
    for (var i = 0; i <= bulbs; i++) {
      final u = i / bulbs;
      final x = _quad(0, size.width / 2, size.width, u);
      final y = _quad(2, sag * 2.2, 2, u) + 5;
      final color = _bulbColors[i % _bulbColors.length];
      canvas.drawCircle(
        Offset(x, y),
        6.5,
        Paint()
          ..color = color.withOpacity(0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      canvas.drawCircle(Offset(x, y), 3.2, Paint()..color = color);
    }
  }

  double _quad(double p0, double p1, double p2, double t) {
    final u = 1 - t;
    return u * u * p0 + 2 * u * t * p1 + t * t * p2;
  }

  @override
  bool shouldRepaint(_GarlandPainter oldDelegate) => false;
}
