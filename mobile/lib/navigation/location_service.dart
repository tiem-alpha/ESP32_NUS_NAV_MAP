import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../models/geo_point.dart';
import '../models/gps_fix.dart';
import 'i_location_service.dart';

/// Nguồn vị trí thật qua `geolocator` — §4.3.
class LocationService implements ILocationService {
  @override
  Future<bool> ensureReady() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  @override
  Future<LocationPermissionStatus> checkStatus() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationPermissionStatus.serviceDisabled;
    }
    final permission = await Geolocator.checkPermission();
    switch (permission) {
      case LocationPermission.whileInUse:
      case LocationPermission.always:
        return LocationPermissionStatus.granted;
      case LocationPermission.deniedForever:
        return LocationPermissionStatus.deniedForever;
      case LocationPermission.denied:
      case LocationPermission.unableToDetermine:
        return LocationPermissionStatus.denied;
    }
  }

  @override
  Future<void> openAppSettings() => Geolocator.openAppSettings();

  @override
  Future<void> openLocationSettings() => Geolocator.openLocationSettings();

  @override
  Stream<GpsFix> positions() async* {
    if (!await ensureReady()) return;
    yield* Geolocator.getPositionStream(
      locationSettings: _streamSettings(),
    ).map(_toFix);
  }

  @override
  Future<GpsFix?> current() async {
    try {
      // Xin quyền + kiểm tra dịch vụ vị trí trước khi đọc fix.
      if (!await ensureReady()) return null;

      // Vị trí biết lần cuối (gần như tức thì) làm fallback khi GPS yếu.
      Position? lastKnown;
      try {
        lastKnown = await Geolocator.getLastKnownPosition();
      } catch (_) {
        lastKnown = null;
      }

      try {
        const settings = LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        );
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: settings,
        );
        return _toFix(pos);
      } catch (_) {
        // Timeout / trong nhà / GPS yếu → dùng vị trí lần cuối nếu có.
        return lastKnown == null ? null : _toFix(lastKnown, staleSpeed: true);
      }
    } catch (_) {
      return null;
    }
  }

  GpsFix _toFix(Position p, {bool staleSpeed = false}) {
    final speed = staleSpeed ? 0.0 : _nonNegativeFinite(p.speed);
    final speedAccuracy = _nonNegativeFinite(p.speedAccuracy);
    return GpsFix(
      position: GeoPoint(p.latitude, p.longitude),
      bearing: _normalizeBearing(p.heading),
      speedMps: speed,
      speedAccuracyMps: speedAccuracy == 0 ? null : speedAccuracy,
      accuracyM: _nonNegativeFinite(p.accuracy),
      satellites: null,
      timestamp: p.timestamp,
    );
  }

  double _nonNegativeFinite(double value) =>
      value.isFinite && value > 0 ? value : 0;

  LocationSettings _streamSettings() {
    const accuracy = LocationAccuracy.bestForNavigation;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1),
        forceLocationManager: false,
      );
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: accuracy,
        activityType: ActivityType.automotiveNavigation,
        distanceFilter: 0,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    }
    return const LocationSettings(accuracy: accuracy, distanceFilter: 0);
  }

  double _normalizeBearing(double value) {
    if (!value.isFinite || value < 0) return 0;
    return value % 360;
  }
}
