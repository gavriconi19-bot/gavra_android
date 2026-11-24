import 'package:flutter/material.dart';

/// Smooth slide+fade route — umesto default MaterialPageRoute tranzicije.
/// Deli se kroz [V3NavigationUtils] i push deep-linkove koji nemaju context.
class V3SmoothPageRoute<T> extends PageRouteBuilder<T> {
  V3SmoothPageRoute({
    required Widget screen,
    super.fullscreenDialog,
  }) : super(
          pageBuilder: (context, animation, secondaryAnimation) => screen,
          transitionDuration: const Duration(milliseconds: 320),
          reverseTransitionDuration: const Duration(milliseconds: 260),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0.05, 0),
                  end: Offset.zero,
                ).animate(curved),
                child: child,
              ),
            );
          },
        );
}

/// Centralizovane navigation utility funkcije za konzistentan UX.
/// Eliminiše duplikate Navigator.push, showDialog, pushReplacement poziva.
class V3NavigationUtils {
  V3NavigationUtils._();

  // ─── SCREEN NAVIGATION ─────────────────────────────────────────────────

  /// Standardni push sa smooth slide+fade tranzicijom
  static Future<T?> pushScreen<T extends Object?>(
    BuildContext context,
    Widget screen, {
    bool fullscreenDialog = false,
  }) async {
    if (!context.mounted) return null;
    return Navigator.push<T>(
      context,
      V3SmoothPageRoute<T>(
        screen: screen,
        fullscreenDialog: fullscreenDialog,
      ),
    );
  }

  /// Push and remove until - zamenjuje sve prethodne ekrane
  static Future<T?> pushAndRemoveUntil<T extends Object?>(
    BuildContext context,
    Widget screen, {
    bool Function(Route<dynamic>)? predicate,
  }) async {
    if (!context.mounted) return null;
    return Navigator.pushAndRemoveUntil<T>(
      context,
      V3SmoothPageRoute<T>(screen: screen),
      predicate ?? (route) => false,
    );
  }

  /// Push replacement - zamenjuje trenutni ekran
  static Future<T?> pushReplacement<T extends Object?, TO extends Object?>(
    BuildContext context,
    Widget screen, {
    TO? result,
  }) async {
    if (!context.mounted) return null;
    return Navigator.pushReplacement<T, TO>(
      context,
      V3SmoothPageRoute<T>(screen: screen),
      result: result,
    );
  }

  /// Pop sa rezultatom
  static void pop<T extends Object?>(
    BuildContext context, [
    T? result,
    bool useRootNavigator = false,
  ]) {
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: useRootNavigator).pop<T>(result);
  }
}
