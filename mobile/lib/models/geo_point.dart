import 'dart:math' as math;

/// Toạ độ địa lý thuần — **không** phụ thuộc plugin bản đồ nào.
///
/// Giữ model độc lập với `maplibre_gl` (nguyên tắc interface-driven §2.2):
/// lớp map adapter sẽ convert sang `LatLng` của plugin khi render.
class GeoPoint {
  final double lat;
  final double lng;

  const GeoPoint(this.lat, this.lng);

  /// Khoảng cách Haversine (mét) tới điểm khác.
  double distanceTo(GeoPoint other) {
    const earthR = 6371000.0; // m
    final dLat = _rad(other.lat - lat);
    final dLng = _rad(other.lng - lng);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(lat)) *
            math.cos(_rad(other.lat)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return earthR * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// Bearing (độ, 0..360, bắc = 0) từ điểm này tới [other].
  double bearingTo(GeoPoint other) {
    final lat1 = _rad(lat);
    final lat2 = _rad(other.lat);
    final dLng = _rad(other.lng - lng);
    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    final brng = math.atan2(y, x) * 180 / math.pi;
    return (brng + 360) % 360;
  }

  static double _rad(double deg) => deg * math.pi / 180;

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);

  @override
  String toString() =>
      'GeoPoint(${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)})';
}
