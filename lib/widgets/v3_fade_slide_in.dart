import 'package:flutter/material.dart';

/// Jednokratna entrance animacija (fade + blagi slide) bez AnimationController-a.
///
/// Bazirana na TweenAnimationBuilder — izvrsi se samo pri prvom mount-u
/// widgeta pa je realtime rebuild-ovi ne ponavljaju. Za staggered efekat
/// proslediti [delay] (npr. index * 50ms).
class V3FadeSlideIn extends StatelessWidget {
  const V3FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 350),
    this.beginOffset = const Offset(0, 0.08),
    this.curve = Curves.easeOutCubic,
  });

  final Widget child;
  final Duration delay;
  final Duration duration;

  /// Pocetni offset kao frakcija velicine child-a
  /// (npr. Offset(0, 0.08) = startuje 8% visine ispod konacne pozicije).
  final Offset beginOffset;
  final Curve curve;

  @override
  Widget build(BuildContext context) {
    final totalMicros = delay.inMicroseconds + duration.inMicroseconds;
    final delayFraction =
        totalMicros <= 0 ? 0.0 : (delay.inMicroseconds / totalMicros).clamp(0.0, 0.9);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: Duration(microseconds: totalMicros),
      curve: Interval(delayFraction, 1.0, curve: curve),
      child: child,
      builder: (context, t, child) {
        return FractionalTranslation(
          translation: Offset(
            beginOffset.dx * (1 - t),
            beginOffset.dy * (1 - t),
          ),
          child: Opacity(opacity: t, child: child),
        );
      },
    );
  }
}
