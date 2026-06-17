import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../core/constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/app_settings.dart';
import '../../models/geo_point.dart';
import '../../models/road_segment.dart';
import '../../models/route_model.dart';
import '../../providers/ui_providers.dart';

/// Convert GeoPoint nội bộ → LatLng của maplibre_gl (model độc lập plugin).
LatLng toLatLng(GeoPoint p) => LatLng(p.lat, p.lng);
GeoPoint fromLatLng(LatLng p) => GeoPoint(p.latitude, p.longitude);

/// Nền bản đồ MapLibre cho S1/S3/S4. Vẽ:
/// - marker vị trí người dùng (matchedPosition hoặc [userLocation]);
/// - polyline tuyến chính (primary) + tuyến phụ mờ (routeAlt);
/// - hỗ trợ heading-up (navigationMode) vs north-up;
/// - long-press → [onLongPress] (drop pin).
///
/// Robust: nếu style lỗi vẫn build (chỉ không có annotation).
class MapView extends ConsumerStatefulWidget {
  /// Danh sách tuyến để vẽ (index [selectedIndex] là tuyến đậm).
  final List<RouteModel> routes;
  final int selectedIndex;

  /// Vị trí người dùng (nếu null sẽ thử lấy current ở onMapCreated path ngoài).
  final GeoPoint? userLocation;

  /// Quãng đường đã đi dọc theo route chính, dùng để làm mờ đoạn đã đi qua.
  final double routeProgressM;

  /// Hướng di chuyển (độ) để vẽ heading-up khi navigationMode.
  final double bearing;

  /// Camera bám theo vị trí người dùng.
  final bool follow;

  /// Chế độ dẫn đường: heading-up + pitch 45°.
  final bool navigationMode;

  /// Điểm đến (vẽ marker đích).
  final GeoPoint? destination;

  final void Function(GeoPoint point)? onLongPress;
  final void Function(MapLibreMapController controller)? onMapCreated;

  /// Báo ngược ra ngoài khi camera xoay (để hiện nút la bàn).
  final void Function(double bearing)? onCameraBearingChanged;

  const MapView({
    super.key,
    this.routes = const [],
    this.selectedIndex = 0,
    this.userLocation,
    this.routeProgressM = 0,
    this.bearing = 0,
    this.follow = true,
    this.navigationMode = false,
    this.destination,
    this.onLongPress,
    this.onMapCreated,
    this.onCameraBearingChanged,
  });

  @override
  ConsumerState<MapView> createState() => MapViewState();
}

class MapViewState extends ConsumerState<MapView>
    with SingleTickerProviderStateMixin {
  MapLibreMapController? _controller;
  late final AnimationController _navigationMotion;
  bool _styleReady = false;
  Circle? _userDot;
  Circle? _userHalo;
  Symbol? _destSymbol;
  final List<Line> _altRouteLines = [];
  Line? _selectedRouteLine;
  Line? _traveledRouteLine;
  GeoPoint? _lastCameraTarget;
  double? _lastCameraBearing;
  GeoPoint? _displayLocation;
  double? _displayRouteProgressM;
  double? _displayBearing;
  GeoPoint? _motionStartLocation;
  GeoPoint? _motionEndLocation;
  double _motionStartRouteProgressM = 0;
  double _motionEndRouteProgressM = 0;
  double _motionStartBearing = 0;
  double _motionEndBearing = 0;
  bool _motionFrameInFlight = false;
  bool _motionFrameQueued = false;
  DateTime? _lastMotionFrameAt;
  DateTime? _lastRouteProgressFrameAt;

  // Màu theme cache (đọc ngoài async gap để tránh dùng context sau await).
  String _primaryHex = '#1A73E8';
  String _routeAltHex = '#9AA0A6';
  String _dangerHex = '#D93025';

  static const _fallbackCenter = GeoPoint(21.0278, 105.8342); // Hà Nội
  static const _navigationMotionDuration = Duration(milliseconds: 950);
  static const _navigationMotionFrameGap = Duration(milliseconds: 33);
  static const _routeProgressFrameGap = Duration(milliseconds: 120);
  static const _maxSmoothJumpM = 120.0;
  static const _navigationZoom = 18.0;
  static const _navigationViewportOffsetFraction = 0;
  static const _minNavigationLookAheadM = 35.0;
  static const _maxNavigationLookAheadM = 140.0;

  @override
  void initState() {
    super.initState();
    _navigationMotion = AnimationController(
      vsync: this,
      duration: _navigationMotionDuration,
    )..addListener(_onNavigationMotionTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _primaryHex = _hex(context.scheme.primary);
    _routeAltHex = _hex(context.semantic.routeAlt);
    _dangerHex = _hex(context.semantic.danger);
  }

  @override
  void didUpdateWidget(covariant MapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_styleReady) return;
    final routesChanged = _routesChanged(oldWidget);
    final motionChanged = _motionTargetChanged(oldWidget);
    if (routesChanged) {
      _syncDisplayedMotionToWidget();
      _drawRoutes();
      _updateUserMarker();
      if (widget.follow) _followCamera();
    } else if (motionChanged) {
      if (widget.navigationMode) {
        _startNavigationMotion(oldWidget);
      } else {
        _syncDisplayedMotionToWidget();
        _updateSelectedRouteProgress();
        _updateUserMarker();
        if (widget.follow) _followCamera();
      }
    }
    if (oldWidget.destination != widget.destination) {
      _updateDestination();
    }
  }

  bool _routesChanged(MapView oldWidget) {
    if (oldWidget.selectedIndex != widget.selectedIndex ||
        oldWidget.navigationMode != widget.navigationMode ||
        oldWidget.routes.length != widget.routes.length) {
      return true;
    }
    for (var i = 0; i < widget.routes.length; i++) {
      if (!identical(oldWidget.routes[i], widget.routes[i])) return true;
    }
    return false;
  }

  bool _motionTargetChanged(MapView oldWidget) {
    return oldWidget.userLocation != widget.userLocation ||
        oldWidget.bearing != widget.bearing ||
        oldWidget.routeProgressM != widget.routeProgressM;
  }

  GeoPoint? get _effectiveUserLocation =>
      _displayLocation ?? widget.userLocation;
  double get _effectiveRouteProgressM =>
      _displayRouteProgressM ?? widget.routeProgressM;
  double get _effectiveBearing => _displayBearing ?? widget.bearing;

  void _syncDisplayedMotionToWidget() {
    _navigationMotion.stop();
    _motionFrameQueued = false;
    _lastRouteProgressFrameAt = null;
    _displayLocation = widget.userLocation;
    _displayRouteProgressM = widget.routeProgressM;
    _displayBearing = widget.bearing;
  }

  void _startNavigationMotion(MapView oldWidget) {
    final target = widget.userLocation;
    if (target == null) {
      _syncDisplayedMotionToWidget();
      return;
    }

    final start = _displayLocation ?? oldWidget.userLocation ?? target;
    final startProgress = _displayRouteProgressM ?? oldWidget.routeProgressM;
    final shouldSnap =
        start.distanceTo(target) > _maxSmoothJumpM ||
        widget.routeProgressM + 5 < startProgress;
    if (shouldSnap) {
      _syncDisplayedMotionToWidget();
      _updateUserMarker();
      _updateSelectedRouteProgress();
      if (widget.follow) _followCamera();
      return;
    }

    _motionStartLocation = start;
    _motionEndLocation = target;
    _motionStartRouteProgressM = startProgress;
    _motionEndRouteProgressM = widget.routeProgressM;
    _motionStartBearing = _displayBearing ?? oldWidget.bearing;
    _motionEndBearing = widget.bearing;
    _lastMotionFrameAt = null;
    _lastRouteProgressFrameAt = null;
    _navigationMotion.forward(from: 0);
  }

  void _onNavigationMotionTick() {
    final start = _motionStartLocation;
    final end = _motionEndLocation;
    if (start == null || end == null) return;

    final now = DateTime.now();
    final value = _navigationMotion.value;
    if (value < 1 &&
        _lastMotionFrameAt != null &&
        now.difference(_lastMotionFrameAt!) < _navigationMotionFrameGap) {
      return;
    }
    _lastMotionFrameAt = now;

    final t = Curves.linear.transform(value);
    _displayLocation = _lerpGeoPoint(start, end, t);
    _displayRouteProgressM = _lerpDouble(
      _motionStartRouteProgressM,
      _motionEndRouteProgressM,
      t,
    );
    _displayBearing = _lerpBearing(_motionStartBearing, _motionEndBearing, t);

    if (_motionFrameInFlight) {
      _motionFrameQueued = true;
      return;
    }
    _motionFrameInFlight = true;
    unawaited(_applyNavigationMotionFrame());
  }

  Future<void> _applyNavigationMotionFrame() async {
    try {
      await _updateUserMarker();
      if (_shouldUpdateAnimatedRouteProgress()) {
        await _updateSelectedRouteProgress();
      }
      if (widget.follow) await _moveCameraToDisplayed();
    } finally {
      _motionFrameInFlight = false;
      if (_motionFrameQueued && mounted) {
        _motionFrameQueued = false;
        _motionFrameInFlight = true;
        unawaited(_applyNavigationMotionFrame());
      }
    }
  }

  bool _shouldUpdateAnimatedRouteProgress() {
    final now = DateTime.now();
    final isFinalFrame = _navigationMotion.value >= 1;
    if (!isFinalFrame &&
        _lastRouteProgressFrameAt != null &&
        now.difference(_lastRouteProgressFrameAt!) < _routeProgressFrameGap) {
      return false;
    }
    _lastRouteProgressFrameAt = now;
    return true;
  }

  GeoPoint _lerpGeoPoint(GeoPoint a, GeoPoint b, double t) {
    return GeoPoint(_lerpDouble(a.lat, b.lat, t), _lerpDouble(a.lng, b.lng, t));
  }

  double _lerpDouble(double a, double b, double t) => a + (b - a) * t;

  double _lerpBearing(double a, double b, double t) {
    final delta = ((b - a + 540) % 360) - 180;
    return _normalizeBearing(a + delta * t);
  }

  double _normalizeBearing(double value) {
    final normalized = value % 360;
    return normalized < 0 ? normalized + 360 : normalized;
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  String get _styleUrl {
    final mode = ref.read(settingsProvider).themeMode;
    final dark =
        mode == AppThemeMode.dark || (mode == AppThemeMode.auto && _isDark);
    return dark ? AppConfig.mapStyleDarkUrl : AppConfig.mapStyleUrl;
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.userLocation ?? _fallbackCenter;
    return MapLibreMap(
      styleString: _styleUrl,
      initialCameraPosition: CameraPosition(
        target: toLatLng(initial),
        zoom: 15,
      ),
      myLocationEnabled: false,
      trackCameraPosition: true,
      compassEnabled: false,
      rotateGesturesEnabled: true,
      tiltGesturesEnabled: true,
      onMapCreated: (c) {
        _controller = c;
        c.addListener(_onCameraMove);
        widget.onMapCreated?.call(c);
      },
      onStyleLoadedCallback: _onStyleLoaded,
      onMapLongClick: (point, latLng) {
        widget.onLongPress?.call(fromLatLng(latLng));
      },
    );
  }

  void _onCameraMove() {
    final b = _controller?.cameraPosition?.bearing ?? 0;
    widget.onCameraBearingChanged?.call(b);
  }

  /// Query road geometry from loaded vector tiles as [RoadSegment] list.
  ///
  /// No external API call — uses tiles already loaded by MapLibre, so this is
  /// fast and works offline. Covers ~450 m around user (camera viewport).
  /// Uses querySourceFeatures (camera-angle independent) with fallback to
  /// queryRenderedFeaturesInRect.
  Future<List<RoadSegment>> queryRoadsForMiniMap(
    double userLat,
    double userLng,
  ) async {
    final c = _controller;
    if (c == null || !_styleReady) return const [];

    // Bounding box ~450 m around user (covers mini-map diagonal at 3 m/px × 300 px).
    const radiusM = 450.0;
    const latPerM = 1.0 / 111320.0;
    final cosLat = math.cos(userLat * math.pi / 180);
    final lngPerM = cosLat > 0 ? 1.0 / (111320.0 * cosLat) : 0.0;
    final bN = userLat + radiusM * latPerM;
    final bS = userLat - radiusM * latPerM;
    final bE = userLng + radiusM * lngPerM;
    final bW = userLng - radiusM * lngPerM;

    bool anyInBounds(List<GeoPoint> pts) =>
        pts.any((p) => p.lat >= bS && p.lat <= bN && p.lng >= bW && p.lng <= bE);

    // Classes to skip (non-vehicle ways). 'service' được giữ lại vì ở VN
    // hẻm/ngõ nhỏ thường được gán highway=service trong OSM.
    const skipClasses = {
      'track', 'path', 'footway', 'cycleway', 'steps',
    };

    List<dynamic> raw = const [];

    // querySourceFeatures reads vector tile data directly → no camera-angle bias.
    for (final srcId in const [
      'openmaptiles',
      'maptiler_planet',
      'tiles',
      'vectorTiles',
    ]) {
      try {
        final r = await c.querySourceFeatures(srcId, 'transportation', null);
        if (r.isNotEmpty) {
          raw = r;
          break;
        }
      } catch (_) {}
    }

    // Fallback: rendered features (misses roads outside camera FOV but better than nothing).
    if (raw.isEmpty) {
      final size = (context as Element).size;
      if (size != null) {
        try {
          raw = await c.queryRenderedFeaturesInRect(
            Rect.fromLTWH(0, 0, size.width, size.height),
            [],
            null,
          );
        } catch (_) {}
      }
    }

    final seen = <String>{};
    final roads = <RoadSegment>[];

    for (final feat in raw) {
      if (roads.length >= 80) break;
      final geom = feat['geometry'];
      if (geom == null) continue;
      final type = geom['type'] as String?;
      if (type != 'LineString' && type != 'MultiLineString') continue;

      final props = feat['properties'] as Map?;
      final cls = props?['class'] as String?;
      if (cls != null && skipClasses.contains(cls)) continue;

      final hwType = HighwayType.fromOsmTag(cls ?? 'residential');

      void addLine(List<dynamic> coords) {
        if (coords.length < 2) return;
        final pts = <GeoPoint>[];
        for (final coord in coords) {
          if (coord is! List || coord.length < 2) continue;
          pts.add(GeoPoint(
            (coord[1] as num).toDouble(),
            (coord[0] as num).toDouble(),
          ));
        }
        if (pts.length < 2) return;
        if (!anyInBounds(pts)) return;
        final key =
            '${pts.first.lat.toStringAsFixed(5)},${pts.first.lng.toStringAsFixed(5)},'
            '${pts.last.lat.toStringAsFixed(5)},${pts.last.lng.toStringAsFixed(5)}';
        if (seen.add(key)) roads.add(RoadSegment(type: hwType, points: pts));
      }

      if (type == 'LineString') {
        addLine(geom['coordinates'] as List<dynamic>? ?? const []);
      } else {
        for (final line in (geom['coordinates'] as List<dynamic>? ?? const [])) {
          if (roads.length >= 30) break;
          addLine(line as List<dynamic>);
        }
      }
    }

    return roads;
  }

  Future<void> _onStyleLoaded() async {
    _styleReady = true;
    _syncDisplayedMotionToWidget();
    try {
      await _drawRoutes();
      await _updateUserMarker();
      await _updateDestination();
      if (widget.follow) await _followCamera();
    } catch (_) {
      // style/annotation lỗi → vẫn giữ map nền.
    }
  }

  Future<void> _drawRoutes() async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.clearLines();
    } catch (_) {}
    _altRouteLines.clear();
    _selectedRouteLine = null;
    _traveledRouteLine = null;
    if (widget.routes.isEmpty) return;

    final altColor = _routeAltHex;
    final primaryColor = _primaryHex;

    // Vẽ tuyến phụ trước (nằm dưới), tuyến chính sau (nằm trên).
    for (var i = 0; i < widget.routes.length; i++) {
      if (i == widget.selectedIndex) continue;
      final line = await _addRouteLine(widget.routes[i].geometry, altColor, 4);
      if (line != null) _altRouteLines.add(line);
    }
    if (widget.selectedIndex >= 0 &&
        widget.selectedIndex < widget.routes.length) {
      final route = widget.routes[widget.selectedIndex];
      if (widget.navigationMode) {
        final split = _splitRoute(route, _effectiveRouteProgressM);
        _traveledRouteLine = await _addRouteLine(
          split.traveled,
          altColor,
          5,
          opacity: 0.45,
        );
        _selectedRouteLine = await _addRouteLine(
          split.remaining,
          primaryColor,
          7,
        );
      } else {
        _selectedRouteLine = await _addRouteLine(
          route.geometry,
          primaryColor,
          7,
        );
      }
    }
  }

  Future<Line?> _addRouteLine(
    List<GeoPoint> geometry,
    String color,
    double width, {
    double? opacity,
  }) async {
    final c = _controller;
    if (c == null || geometry.length < 2) return null;
    return c.addLine(
      LineOptions(
        geometry: geometry.map(toLatLng).toList(),
        lineColor: color,
        lineOpacity: opacity,
        lineWidth: width,
        lineJoin: 'round',
      ),
    );
  }

  Future<void> _updateSelectedRouteProgress() async {
    if (widget.selectedIndex < 0 ||
        widget.selectedIndex >= widget.routes.length ||
        !widget.navigationMode) {
      return;
    }
    final route = widget.routes[widget.selectedIndex];
    final split = _splitRoute(route, _effectiveRouteProgressM);
    _traveledRouteLine = await _upsertRouteLine(
      _traveledRouteLine,
      split.traveled,
      _routeAltHex,
      5,
      opacity: 0.45,
    );
    _selectedRouteLine = await _upsertRouteLine(
      _selectedRouteLine,
      split.remaining,
      _primaryHex,
      7,
    );
  }

  Future<Line?> _upsertRouteLine(
    Line? line,
    List<GeoPoint> geometry,
    String color,
    double width, {
    double? opacity,
  }) async {
    final c = _controller;
    if (c == null) return line;
    if (geometry.length < 2) {
      if (line != null) {
        try {
          await c.removeLine(line);
        } catch (_) {}
      }
      return null;
    }
    final options = LineOptions(
      geometry: geometry.map(toLatLng).toList(),
      lineColor: color,
      lineOpacity: opacity,
      lineWidth: width,
      lineJoin: 'round',
    );
    try {
      if (line == null) return c.addLine(options);
      await c.updateLine(line, options);
      return line;
    } catch (_) {
      return line;
    }
  }

  _RouteSplit _splitRoute(RouteModel route, double progressM) {
    final geometry = route.geometry;
    if (geometry.length < 2) return _RouteSplit(const [], geometry);

    final total = _routeGeometryLengthM(geometry);
    final progress = progressM.clamp(0, total).toDouble();
    if (progress <= 0) return _RouteSplit(const [], geometry);
    if (progress >= total) return _RouteSplit(geometry, const []);

    final traveled = <GeoPoint>[geometry.first];
    var along = 0.0;
    for (var i = 0; i < geometry.length - 1; i++) {
      final a = geometry[i];
      final b = geometry[i + 1];
      final segmentLength = a.distanceTo(b);
      if (segmentLength <= 0) continue;
      final nextAlong = along + segmentLength;
      if (progress >= nextAlong) {
        traveled.add(b);
        along = nextAlong;
        continue;
      }

      final t = ((progress - along) / segmentLength).clamp(0.0, 1.0);
      final split = GeoPoint(
        a.lat + (b.lat - a.lat) * t,
        a.lng + (b.lng - a.lng) * t,
      );
      if (traveled.last != split) traveled.add(split);
      final remaining = <GeoPoint>[split, b, ...geometry.skip(i + 2)];
      return _RouteSplit(traveled, remaining);
    }

    return _RouteSplit(geometry, const []);
  }

  double _routeGeometryLengthM(List<GeoPoint> geometry) {
    var total = 0.0;
    for (var i = 0; i < geometry.length - 1; i++) {
      total += geometry[i].distanceTo(geometry[i + 1]);
    }
    return total;
  }

  Future<void> _updateUserMarker() async {
    final c = _controller;
    if (c == null) return;
    final loc = _effectiveUserLocation;
    if (loc == null) return;
    final latLng = toLatLng(loc);
    try {
      if (_userHalo == null) {
        _userHalo = await c.addCircle(
          CircleOptions(
            geometry: latLng,
            circleRadius: 14,
            circleColor: _primaryHex,
            circleOpacity: 0.2,
          ),
        );
        _userDot = await c.addCircle(
          CircleOptions(
            geometry: latLng,
            circleRadius: 7,
            circleColor: _primaryHex,
            circleStrokeColor: '#FFFFFF',
            circleStrokeWidth: 2,
          ),
        );
      } else {
        await c.updateCircle(_userHalo!, CircleOptions(geometry: latLng));
        await c.updateCircle(_userDot!, CircleOptions(geometry: latLng));
      }
    } catch (_) {}
  }

  Future<void> _updateDestination() async {
    final c = _controller;
    if (c == null) return;
    final dest = widget.destination;
    try {
      if (dest == null) {
        if (_destSymbol != null) {
          await c.removeSymbol(_destSymbol!);
          _destSymbol = null;
        }
        return;
      }
      final latLng = toLatLng(dest);
      if (_destSymbol == null) {
        // iconImage có thể không có trong style → fallback dùng circle.
        try {
          _destSymbol = await c.addSymbol(
            SymbolOptions(
              geometry: latLng,
              iconImage: 'marker-15',
              iconSize: 1.6,
            ),
          );
        } catch (_) {
          await c.addCircle(
            CircleOptions(
              geometry: latLng,
              circleRadius: 8,
              circleColor: _dangerHex,
              circleStrokeColor: '#FFFFFF',
              circleStrokeWidth: 2,
            ),
          );
        }
      } else {
        await c.updateSymbol(_destSymbol!, SymbolOptions(geometry: latLng));
      }
    } catch (_) {}
  }

  Future<void> _followCamera() async {
    final c = _controller;
    final loc = _effectiveUserLocation;
    if (c == null || loc == null) return;
    final bearing = _effectiveBearing;
    if (widget.navigationMode &&
        _lastCameraTarget != null &&
        _lastCameraTarget!.distanceTo(loc) < 0.8 &&
        _bearingDelta(_lastCameraBearing ?? 0, bearing) < 1) {
      return;
    }
    final pos = CameraPosition(
      target: toLatLng(_cameraTargetFor(loc, bearing)),
      zoom: widget.navigationMode ? _navigationZoom : 15.5,
      bearing: widget.navigationMode ? bearing : 0,
      tilt: widget.navigationMode ? 45 : 0,
    );
    try {
      await c.animateCamera(
        CameraUpdate.newCameraPosition(pos),
        duration: widget.navigationMode
            ? const Duration(milliseconds: 700)
            : null,
      );
      _lastCameraTarget = loc;
      _lastCameraBearing = widget.navigationMode ? bearing : 0;
    } catch (_) {}
  }

  Future<void> _moveCameraToDisplayed() async {
    final c = _controller;
    final loc = _effectiveUserLocation;
    if (c == null || loc == null) return;
    final bearing = _effectiveBearing;
    final pos = CameraPosition(
      target: toLatLng(_cameraTargetFor(loc, bearing)),
      zoom: widget.navigationMode ? _navigationZoom : 15.5,
      bearing: widget.navigationMode ? bearing : 0,
      tilt: widget.navigationMode ? 45 : 0,
    );
    try {
      await c.moveCamera(CameraUpdate.newCameraPosition(pos));
      _lastCameraTarget = loc;
      _lastCameraBearing = widget.navigationMode ? bearing : 0;
    } catch (_) {}
  }

  double _bearingDelta(double a, double b) {
    final diff = ((a - b).abs()) % 360;
    return diff > 180 ? 360 - diff : diff;
  }

  GeoPoint _cameraTargetFor(GeoPoint location, double bearing) {
    if (!widget.navigationMode) return location;
    final size = context.size;
    if (size == null || size.height <= 0) return location;
    final metersPerPixel = _metersPerPixel(location.lat, _navigationZoom);
    final lookAheadM =
        (size.height * _navigationViewportOffsetFraction * metersPerPixel)
            .clamp(_minNavigationLookAheadM, _maxNavigationLookAheadM)
            .toDouble();
    return _offsetPoint(location, bearing, lookAheadM);
  }

  double _metersPerPixel(double lat, double zoom) {
    return 156543.03392 * math.cos(lat * math.pi / 180) / math.pow(2, zoom);
  }

  /// Mét hiển thị trên toàn chiều rộng widget bản đồ ở zoom dẫn đường hiện
  /// tại — dùng để báo ESP32 đặt scale HUD khớp đúng tỷ lệ zoom điện thoại
  /// (MAP_POSE.view_span_dm, §6.2.1). Null nếu widget chưa layout xong.
  double? viewSpanMAt(double lat) {
    final width = context.size?.width;
    if (width == null || width <= 0) return null;
    return width * _metersPerPixel(lat, _navigationZoom);
  }

  GeoPoint _offsetPoint(GeoPoint point, double bearingDeg, double distanceM) {
    const earthRadiusM = 6371000.0;
    final angularDistance = distanceM / earthRadiusM;
    final bearing = bearingDeg * math.pi / 180;
    final lat1 = point.lat * math.pi / 180;
    final lng1 = point.lng * math.pi / 180;

    final lat2 = math.asin(
      math.sin(lat1) * math.cos(angularDistance) +
          math.cos(lat1) * math.sin(angularDistance) * math.cos(bearing),
    );
    final lng2 =
        lng1 +
        math.atan2(
          math.sin(bearing) * math.sin(angularDistance) * math.cos(lat1),
          math.cos(angularDistance) - math.sin(lat1) * math.sin(lat2),
        );

    return GeoPoint(lat2 * 180 / math.pi, lng2 * 180 / math.pi);
  }

  /// Reset về north-up (gọi từ nút la bàn).
  Future<void> resetNorth() async {
    final c = _controller;
    if (c == null) return;
    final cur = c.cameraPosition;
    if (cur == null) return;
    await c.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: cur.target, zoom: cur.zoom, bearing: 0, tilt: 0),
      ),
    );
  }

  /// Bay tới 1 điểm (vd camera bay tới điểm đến khi mở S3).
  Future<void> flyTo(GeoPoint point, {double zoom = 15}) async {
    await _controller?.animateCamera(
      CameraUpdate.newLatLngZoom(toLatLng(point), zoom),
    );
  }

  /// Fit bounds toàn tuyến (S3 auto-fit).
  Future<void> fitRoute(RouteModel route) async {
    final c = _controller;
    if (c == null || route.geometry.isEmpty) return;
    var minLat = route.geometry.first.lat, maxLat = route.geometry.first.lat;
    var minLng = route.geometry.first.lng, maxLng = route.geometry.first.lng;
    for (final p in route.geometry) {
      minLat = p.lat < minLat ? p.lat : minLat;
      maxLat = p.lat > maxLat ? p.lat : maxLat;
      minLng = p.lng < minLng ? p.lng : minLng;
      maxLng = p.lng > maxLng ? p.lng : maxLng;
    }
    try {
      await c.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(minLat, minLng),
            northeast: LatLng(maxLat, maxLng),
          ),
          left: 40,
          right: 40,
          top: 120,
          bottom: 280,
        ),
      );
    } catch (_) {}
  }

  String _hex(Color c) {
    final argb = c.toARGB32();
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    return '#${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _navigationMotion.dispose();
    _controller?.removeListener(_onCameraMove);
    super.dispose();
  }
}

class _RouteSplit {
  final List<GeoPoint> traveled;
  final List<GeoPoint> remaining;

  const _RouteSplit(this.traveled, this.remaining);
}
