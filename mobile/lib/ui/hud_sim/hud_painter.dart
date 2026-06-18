import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/geo_point.dart';
import '../../models/road_segment.dart';

/// Khung tham chiếu của HUD ESP32 (240×320, §6–§7 DESIGN.md).
class HudFrame {
  HudFrame._();

  /// Kích thước logic của màn HUD (px thiết bị).
  static const double width = 240;
  static const double height = 320;

  /// User neo giữa-dưới (§7): nhìn xa phía trước khi heading-up.
  static const double userX = 120;
  static const double userY = 230;
}

/// `CustomPainter` mô phỏng **chính xác** view full-screen của HUD ESP32:
/// chiếu route/roads từ GeoPoint sang pixel theo đúng phép toán firmware
/// (`projection.h` / DESIGN §7), heading-up, user neo giữa-dưới.
///
/// Toạ độ vẽ luôn quy về khung 240×320 rồi scale ([scale]) ra kích thước widget.
class HudPainter extends CustomPainter {
  /// Vị trí user hiện tại — dùng làm **anchor** cho phép chiếu.
  final GeoPoint user;

  /// Hướng đầu xe (độ, bắc = 0) — heading-up sẽ quay -heading.
  final double headingDeg;

  /// Hình học tuyến (polyline) — vẽ xanh, đậm.
  final List<GeoPoint> routeGeometry;

  /// Đường xung quanh — vẽ xám, độ dày theo HighwayType.
  final List<RoadSegment> roads;

  /// Tốc độ (km/h) — dùng auto-zoom (đi nhanh → nhìn xa hơn).
  final double speedKmh;

  /// Màu route (theo theme primary).
  final Color routeColor;

  /// Màu đường nền (theo theme).
  final Color roadColor;

  /// Override px/m thay vì tính từ speed — dùng khi có viewSpanM từ MAP_POSE
  /// để khớp chính xác zoom ESP32 (`HudFrame.width / viewSpanM`).
  final double? pxPerMOverride;

  HudPainter({
    required this.user,
    required this.headingDeg,
    required this.routeGeometry,
    required this.roads,
    required this.speedKmh,
    required this.routeColor,
    required this.roadColor,
    this.pxPerMOverride,
  });

  /// px/mét tại khung 240×320. Nếu có override (từ viewSpanM của MAP_POSE) dùng
  /// đúng zoom ESP32; ngược lại tính từ speed (đứng yên gần, chạy nhanh xa).
  double get _pxPerM {
    if (pxPerMOverride != null) return pxPerMOverride!;
    // 0..80 km/h → 0,9..0,35 px/m (nội suy tuyến tính, kẹp biên).
    final t = (speedKmh.clamp(0, 80)) / 80.0;
    return 0.9 - 0.55 * t;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Scale từ khung 240×320 ra kích thước widget (giữ tỉ lệ).
    final scale = math.min(size.width / HudFrame.width, size.height / HudFrame.height);
    canvas.save();
    canvas.scale(scale);

    // Nền bản đồ (tối, giống canvas LVGL).
    final bg = Paint()..color = const Color(0xFF1B1B1F);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, HudFrame.width, HudFrame.height),
      bg,
    );
    // Clip mọi nét vẽ vào đúng khung HUD.
    canvas.clipRect(
      const Rect.fromLTWH(0, 0, HudFrame.width, HudFrame.height),
    );

    final h = headingDeg * math.pi / 180.0;
    final sinH = math.sin(h);
    final cosH = math.cos(h);
    final cosLat = math.cos(user.lat * math.pi / 180.0);
    final pxPerM = _pxPerM;

    // --- Roads (xám, độ dày theo class) ---
    for (final seg in roads) {
      final paint = Paint()
        ..color = roadColor
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = _roadWidth(seg.type);
      final path = _projectPath(seg.points, sinH, cosH, cosLat, pxPerM);
      if (path != null) canvas.drawPath(path, paint);
    }

    // --- Route (xanh, dày ~6 px) ---
    if (routeGeometry.length >= 2) {
      // Viền tối phía sau cho dễ phân biệt với roads.
      final outline = Paint()
        ..color = Colors.black.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = 9;
      final routePaint = Paint()
        ..color = routeColor
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = 6;
      final path = _projectPath(routeGeometry, sinH, cosH, cosLat, pxPerM);
      if (path != null) {
        canvas.drawPath(path, outline);
        canvas.drawPath(path, routePaint);
      }
    }

    // --- User: mũi tên trắng tại (USER_X, USER_Y) hướng lên (heading-up) ---
    _drawUserArrow(canvas);

    canvas.restore();
  }

  /// Chiếu danh sách GeoPoint → Path pixel (khung 240×320). Trả null nếu < 2 điểm.
  Path? _projectPath(
    List<GeoPoint> pts,
    double sinH,
    double cosH,
    double cosLat,
    double pxPerM,
  ) {
    if (pts.length < 2) return null;
    final path = Path();
    var started = false;
    for (final p in pts) {
      final o = _project(p, sinH, cosH, cosLat, pxPerM);
      if (!started) {
        path.moveTo(o.dx, o.dy);
        started = true;
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }
    return path;
  }

  /// Phép chiếu lõi — khớp CHÍNH XÁC firmware projection.c:
  ///   xr = east·cosH - north·sinH   (giống: de*cos_h - dn*sin_h)
  ///   yr = east·sinH + north·cosH   (giống: de*sin_h + dn*cos_h)
  ///   x = USER_X + xr·pxPerM ; y = USER_Y - yr·pxPerM
  Offset _project(
    GeoPoint p,
    double sinH,
    double cosH,
    double cosLat,
    double pxPerM,
  ) {
    final eastM = (p.lng - user.lng) * cosLat * 111320.0;
    final northM = (p.lat - user.lat) * 111320.0;
    final xr = eastM * cosH - northM * sinH;
    final yr = eastM * sinH + northM * cosH;
    final x = HudFrame.userX + xr * pxPerM;
    final y = HudFrame.userY - yr * pxPerM;
    return Offset(x, y);
  }

  /// Độ dày road theo class (đường lớn dày hơn — §8).
  double _roadWidth(HighwayType type) {
    switch (type) {
      case HighwayType.motorway:
      case HighwayType.trunk:
        return 5;
      case HighwayType.primary:
        return 4;
      case HighwayType.secondary:
        return 3;
      case HighwayType.tertiary:
        return 2.5;
      case HighwayType.residential:
        return 2;
      case HighwayType.service:
        return 1.5;
    }
  }

  /// Mũi tên user trắng, viền tối, đỉnh hướng lên (heading-up).
  void _drawUserArrow(Canvas canvas) {
    const cx = HudFrame.userX;
    const cy = HudFrame.userY;
    final path = Path()
      ..moveTo(cx, cy - 14) // đỉnh
      ..lineTo(cx - 10, cy + 10) // đáy trái
      ..lineTo(cx, cy + 4) // hõm giữa
      ..lineTo(cx + 10, cy + 10) // đáy phải
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(path, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant HudPainter old) {
    return old.user != user ||
        old.headingDeg != headingDeg ||
        old.routeGeometry != routeGeometry ||
        old.roads != roads ||
        old.speedKmh != speedKmh ||
        old.routeColor != routeColor ||
        old.roadColor != roadColor ||
        old.pxPerMOverride != pxPerMOverride;
  }
}
