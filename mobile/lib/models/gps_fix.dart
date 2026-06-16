import 'geo_point.dart';

/// Một GPS fix (1 Hz) từ LocationService → NavEngine (§4.3).
class GpsFix {
  final GeoPoint position;
  final double bearing; // độ, 0..360
  final double speedMps; // m/s
  final double? speedAccuracyMps; // m/s, null = không rõ
  final double accuracyM; // bán kính sai số ngang
  final int? satellites; // số vệ tinh (nếu nền cung cấp)
  final DateTime timestamp;

  GpsFix({
    required this.position,
    required this.bearing,
    required this.speedMps,
    this.speedAccuracyMps,
    required this.accuracyM,
    this.satellites,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  double get safeSpeedMps => speedMps.isFinite && speedMps > 0 ? speedMps : 0;
  double get speedKmh => safeSpeedMps * 3.6;

  /// GPS yếu: accuracy > 30 m hoặc < 4 vệ tinh (§11.6).
  bool get isWeak => accuracyM > 30 || (satellites != null && satellites! < 4);
}
