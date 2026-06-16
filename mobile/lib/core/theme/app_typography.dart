import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Typography §3.4 + §11.1.
///
/// - **Be Vietnam Pro**: heading, tên đường (dấu tiếng Việt chuẩn).
/// - **Inter** + tabular figures: body + MỌI con số (khoảng cách, tốc độ, ETA)
///   để số không "nhảy" bề ngang mỗi giây.
///
/// Lưu ý §3.4: production phải bundle .ttf vào assets và đặt
/// `GoogleFonts.config.allowRuntimeFetching = false` để chạy offline.
class AppTypography {
  AppTypography._();

  static const _tabular = [FontFeature.tabularFigures()];

  static TextTheme textTheme(TextTheme base) => base.copyWith(
        displayLarge:
            GoogleFonts.beVietnamPro(textStyle: base.displayLarge, fontWeight: FontWeight.w700),
        headlineSmall:
            GoogleFonts.beVietnamPro(textStyle: base.headlineSmall, fontWeight: FontWeight.w700),
        titleLarge: GoogleFonts.beVietnamPro(
            textStyle: base.titleLarge, fontWeight: FontWeight.w600, fontSize: 20),
        titleMedium:
            GoogleFonts.beVietnamPro(textStyle: base.titleMedium, fontWeight: FontWeight.w600),
        bodyLarge: GoogleFonts.inter(textStyle: base.bodyLarge),
        bodyMedium: GoogleFonts.inter(textStyle: base.bodyMedium, fontSize: 14),
        labelLarge:
            GoogleFonts.inter(textStyle: base.labelLarge, fontWeight: FontWeight.w500),
        labelSmall: GoogleFonts.inter(
            textStyle: base.labelSmall, fontWeight: FontWeight.w500, fontSize: 11),
      );

  // ── Style chuyên dụng cho banner dẫn đường (§11.1) ────────────────

  /// "350 m" trên banner — Inter tabular 40/800.
  static TextStyle navDistance(Color color) => GoogleFonts.inter(
        fontSize: 40,
        fontWeight: FontWeight.w800,
        height: 1.0,
        color: color,
        fontFeatures: _tabular,
      );

  /// "Đường Lê Duẩn" — Be Vietnam Pro 24/600.
  static TextStyle navStreet(Color color) => GoogleFonts.beVietnamPro(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        height: 1.1,
        color: color,
      );

  /// Ô tốc độ hiện tại — Inter tabular 28/700.
  static TextStyle speedValue(Color color) => GoogleFonts.inter(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: color,
        fontFeatures: _tabular,
      );

  /// Số trong biển tốc độ tròn.
  static TextStyle speedSign(Color color) => GoogleFonts.inter(
        fontSize: 22,
        fontWeight: FontWeight.w800,
        color: color,
        fontFeatures: _tabular,
      );
}
