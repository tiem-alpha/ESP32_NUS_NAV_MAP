import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/ble_device.dart';
import '../../models/geo_point.dart';
import '../../models/road_segment.dart';

/// Vẽ mô phỏng HUD theo đúng kích thước và tỉ lệ nhận từ SYSTEM_INFO.
class HudPainter extends CustomPainter {
  final HudDisplayConfig displayConfig;
  final GeoPoint user;
  final double headingDeg;
  final List<GeoPoint> routeGeometry;
  final List<RoadSegment> roads;
  final double speedKmh;
  final Color routeColor;
  final Color roadColor;
  final double? pxPerMOverride;

  HudPainter({
    required this.displayConfig,
    required this.user,
    required this.headingDeg,
    required this.routeGeometry,
    required this.roads,
    required this.speedKmh,
    required this.routeColor,
    required this.roadColor,
    this.pxPerMOverride,
  });

  double get _pxPerM {
    if (pxPerMOverride != null) return pxPerMOverride!;
    final t = speedKmh.clamp(0, 80) / 80.0;
    return 0.9 - 0.55 * t;
  }

  double get _shortSide => math.min(
    displayConfig.screenW.toDouble(),
    displayConfig.screenH.toDouble(),
  );

  double _ratio(double value) => _shortSide * value;

  @override
  void paint(Canvas canvas, Size size) {
    final frameWidth = displayConfig.screenW.toDouble();
    final frameHeight = displayConfig.screenH.toDouble();
    final scale = math.min(size.width / frameWidth, size.height / frameHeight);
    canvas.save();
    canvas.scale(scale);

    canvas.drawRect(
      Rect.fromLTWH(0, 0, frameWidth, frameHeight),
      Paint()..color = const Color(0xFF1B1B1F),
    );
    canvas.clipRect(Rect.fromLTWH(0, 0, frameWidth, frameHeight));

    final headingRad = headingDeg * math.pi / 180.0;
    final sinH = math.sin(headingRad);
    final cosH = math.cos(headingRad);
    final cosLat = math.cos(user.lat * math.pi / 180.0);
    final pxPerM = _pxPerM;

    for (final segment in roads) {
      final path = _projectPath(segment.points, sinH, cosH, cosLat, pxPerM);
      if (path == null) continue;
      canvas.drawPath(
        path,
        Paint()
          ..color = roadColor
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = _roadWidth(segment.type),
      );
    }

    if (routeGeometry.length >= 2) {
      final path = _projectPath(routeGeometry, sinH, cosH, cosLat, pxPerM);
      if (path != null) {
        canvas.drawPath(
          path,
          Paint()
            ..color = Colors.black.withValues(alpha: 0.5)
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = _ratio(0.0375),
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = routeColor
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = _ratio(0.025),
        );
      }
    }

    _drawUserArrow(canvas);
    canvas.restore();
  }

  Path? _projectPath(
    List<GeoPoint> points,
    double sinH,
    double cosH,
    double cosLat,
    double pxPerM,
  ) {
    if (points.length < 2) return null;
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final point = _project(points[i], sinH, cosH, cosLat, pxPerM);
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    return path;
  }

  Offset _project(
    GeoPoint point,
    double sinH,
    double cosH,
    double cosLat,
    double pxPerM,
  ) {
    final eastM = (point.lng - user.lng) * cosLat * 111320.0;
    final northM = (point.lat - user.lat) * 111320.0;
    final rotatedX = eastM * cosH - northM * sinH;
    final rotatedY = eastM * sinH + northM * cosH;
    return Offset(
      displayConfig.userX + rotatedX * pxPerM,
      displayConfig.userY - rotatedY * pxPerM,
    );
  }

  double _roadWidth(HighwayType type) {
    return switch (type) {
      HighwayType.motorway || HighwayType.trunk => _ratio(0.021),
      HighwayType.primary => _ratio(0.017),
      HighwayType.secondary => _ratio(0.013),
      HighwayType.tertiary => _ratio(0.0105),
      HighwayType.residential => _ratio(0.0085),
      HighwayType.service => _ratio(0.0065),
    };
  }

  void _drawUserArrow(Canvas canvas) {
    final centerX = displayConfig.userX;
    final centerY = displayConfig.userY;
    final tip = _ratio(0.058);
    final halfWidth = _ratio(0.042);
    final tail = _ratio(0.042);
    final indent = _ratio(0.017);
    final path = Path()
      ..moveTo(centerX, centerY - tip)
      ..lineTo(centerX - halfWidth, centerY + tail)
      ..lineTo(centerX, centerY + indent)
      ..lineTo(centerX + halfWidth, centerY + tail)
      ..close();

    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = _ratio(0.0125)
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(path, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant HudPainter old) {
    return old.displayConfig.screenW != displayConfig.screenW ||
        old.displayConfig.screenH != displayConfig.screenH ||
        old.displayConfig.screenType != displayConfig.screenType ||
        old.user != user ||
        old.headingDeg != headingDeg ||
        old.routeGeometry != routeGeometry ||
        old.roads != roads ||
        old.speedKmh != speedKmh ||
        old.routeColor != routeColor ||
        old.roadColor != roadColor ||
        old.pxPerMOverride != pxPerMOverride;
  }
}
