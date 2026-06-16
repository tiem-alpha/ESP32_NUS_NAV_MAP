import 'dart:math' as math;

import '../models/geo_point.dart';

/// Kết quả chiếu vị trí GPS lên geometry tuyến (§4.3 bước 1).
class MatchResult {
  final int segmentIndex; // đoạn [i, i+1] gần nhất
  final double alongM; // khoảng cách dọc tuyến từ điểm đầu tới điểm chiếu
  final double offsetM; // khoảng cách vuông góc từ GPS tới tuyến
  final GeoPoint point; // điểm chiếu trên tuyến
  const MatchResult(this.segmentIndex, this.alongM, this.offsetM, this.point);
}

/// Map-matching đơn giản dùng phép chiếu phẳng (đủ tốt ở quy mô đô thị) +
/// hysteresis: chỉ cho phép tiến về phía trước, tránh "nhảy" đoạn khi
/// tuyến gấp khúc hoặc đi gần đường song song.
class MapMatcher {
  final List<GeoPoint> geometry;
  late final List<double> _cum; // cumulative distance tại mỗi vertex

  MapMatcher(this.geometry) {
    _cum = List<double>.filled(geometry.length, 0);
    for (var i = 1; i < geometry.length; i++) {
      _cum[i] = _cum[i - 1] + geometry[i - 1].distanceTo(geometry[i]);
    }
  }

  double get totalLengthM => _cum.isEmpty ? 0 : _cum.last;
  double alongAtVertex(int index) =>
      (index >= 0 && index < _cum.length) ? _cum[index] : 0;

  /// Chiếu [pos]; [minSeg] giới hạn không lùi quá xa (hysteresis).
  MatchResult match(GeoPoint pos, {int minSeg = 0, int window = 60}) {
    var bestSeg = minSeg;
    var bestOff = double.infinity;
    var bestAlong = _cum[minSeg.clamp(0, _cum.length - 1)];
    var bestPoint = geometry[minSeg.clamp(0, geometry.length - 1)];

    final end = math.min(geometry.length - 1, minSeg + window);
    for (var i = minSeg; i < end; i++) {
      final proj = _projectOnSegment(pos, geometry[i], geometry[i + 1]);
      if (proj.offM < bestOff) {
        bestOff = proj.offM;
        bestSeg = i;
        bestAlong = _cum[i] + proj.alongOnSeg;
        bestPoint = proj.point;
      }
    }
    return MatchResult(bestSeg, bestAlong, bestOff, bestPoint);
  }

  _Proj _projectOnSegment(GeoPoint p, GeoPoint a, GeoPoint b) {
    // Quy về mặt phẳng cục bộ quanh a (mét).
    final mPerDegLat = 111320.0;
    final mPerDegLng = 111320.0 * math.cos(a.lat * math.pi / 180);
    double px = (p.lng - a.lng) * mPerDegLng;
    double py = (p.lat - a.lat) * mPerDegLat;
    double bx = (b.lng - a.lng) * mPerDegLng;
    double by = (b.lat - a.lat) * mPerDegLat;
    final segLen2 = bx * bx + by * by;
    double t = segLen2 == 0 ? 0 : ((px * bx + py * by) / segLen2);
    t = t.clamp(0.0, 1.0);
    final cx = bx * t;
    final cy = by * t;
    final dx = px - cx;
    final dy = py - cy;
    final offM = math.sqrt(dx * dx + dy * dy);
    final alongOnSeg = math.sqrt(cx * cx + cy * cy);
    final point = GeoPoint(
      a.lat + (cy / mPerDegLat),
      a.lng + (cx / mPerDegLng),
    );
    return _Proj(offM, alongOnSeg, point);
  }
}

class _Proj {
  final double offM;
  final double alongOnSeg;
  final GeoPoint point;
  _Proj(this.offM, this.alongOnSeg, this.point);
}
