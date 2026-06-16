import 'package:flutter/material.dart';

/// Bảng màu §11.1 (Material 3 tokens, seed-based) cho Light + Night.
class AppColors {
  AppColors._();

  // Brand / route
  static const primaryLight = Color(0xFF1A73E8);
  static const primaryDark = Color(0xFF8AB4F8);
  static const routeAltLight = Color(0xFF9AA0A6);
  static const routeAltDark = Color(0xFF5F6368);

  // Banner turn-by-turn — giữ nguyên 2 theme (nhận diện như biển chỉ dẫn).
  static const navBanner = Color(0xFF0B8043);

  // Surface
  static const surfaceLight = Color(0xFFFFFFFF);
  static const surfaceDark = Color(0xFF121212);

  // Semantic
  static const warningLight = Color(0xFFF9AB00);
  static const warningDark = Color(0xFFFDD663);
  static const dangerLight = Color(0xFFD93025);
  static const dangerDark = Color(0xFFF28B82);
  static const bleConnectedLight = Color(0xFF188038);
  static const bleConnectedDark = Color(0xFF81C995);

  // Biển tốc độ kiểu VN: viền đỏ, nền trắng.
  static const speedSignBorder = Color(0xFFD93025);
  static const speedSignFill = Color(0xFFFFFFFF);
}

/// Extension màu ngoài ColorScheme (banner, warning, danger, ble) —
/// truy cập qua `Theme.of(context).extension<AppSemanticColors>()`.
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  final Color navBanner;
  final Color warning;
  final Color danger;
  final Color bleConnected;
  final Color routeAlt;

  const AppSemanticColors({
    required this.navBanner,
    required this.warning,
    required this.danger,
    required this.bleConnected,
    required this.routeAlt,
  });

  static const light = AppSemanticColors(
    navBanner: AppColors.navBanner,
    warning: AppColors.warningLight,
    danger: AppColors.dangerLight,
    bleConnected: AppColors.bleConnectedLight,
    routeAlt: AppColors.routeAltLight,
  );

  static const dark = AppSemanticColors(
    navBanner: AppColors.navBanner,
    warning: AppColors.warningDark,
    danger: AppColors.dangerDark,
    bleConnected: AppColors.bleConnectedDark,
    routeAlt: AppColors.routeAltDark,
  );

  @override
  AppSemanticColors copyWith({
    Color? navBanner,
    Color? warning,
    Color? danger,
    Color? bleConnected,
    Color? routeAlt,
  }) =>
      AppSemanticColors(
        navBanner: navBanner ?? this.navBanner,
        warning: warning ?? this.warning,
        danger: danger ?? this.danger,
        bleConnected: bleConnected ?? this.bleConnected,
        routeAlt: routeAlt ?? this.routeAlt,
      );

  @override
  AppSemanticColors lerp(AppSemanticColors? other, double t) {
    if (other == null) return this;
    return AppSemanticColors(
      navBanner: Color.lerp(navBanner, other.navBanner, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      bleConnected: Color.lerp(bleConnected, other.bleConnected, t)!,
      routeAlt: Color.lerp(routeAlt, other.routeAlt, t)!,
    );
  }
}
