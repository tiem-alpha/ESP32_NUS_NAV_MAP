import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../core/event_bus.dart';
import '../models/gps_fix.dart';
import '../models/geo_point.dart';
import '../models/app_settings.dart';
import '../models/maneuver_type.dart';
import '../models/nav_event.dart';
import '../models/nav_state.dart';
import '../models/place.dart';
import '../models/route_model.dart';
import '../models/traffic_sign.dart';
import '../models/travel_profile.dart';
import '../providers/app_providers.dart';
import '../providers/ui_providers.dart';
import '../routing/i_route_service.dart';
import 'map_matcher.dart';

/// Navigation Engine (§4.3): state machine IDLE→ROUTING→NAVIGATING↔OFF_ROUTE→ARRIVED.
/// Single source of truth ([NavSnapshot]); phát [NavEvent] lên bus cho
/// UI/BLE/TTS render.
class NavController extends Notifier<NavSnapshot> {
  StreamSubscription<GpsFix>? _gpsSub;
  MapMatcher? _matcher;
  List<TrafficSign> _signs = const [];

  // Bối cảnh để reroute.
  Place? _destination;
  TravelProfile _profile = TravelProfile.auto;
  RouteOptions _options = const RouteOptions();

  int _matchedSeg = 0;
  int _offRouteCount = 0;
  final Set<double> _firedPrompts = {};
  int _lastInstrSeq = 0;
  int _currentSpeedLimit = 0;
  bool _rerouting = false;
  GpsFix? _lastSpeedFix;
  double _smoothedSpeedMps = 0;

  static const double _maxPlausibleSpeedMps = 75; // 270 km/h
  static const double _maxAccelerationMps2 = 8;
  static const double _stoppedSpeedMps = 0.4;
  static const double _bearingLookAheadM = 25;

  NavEventBus get _bus => ref.read(navEventBusProvider);

  @override
  NavSnapshot build() {
    ref.onDispose(() => _gpsSub?.cancel());
    return const NavSnapshot();
  }

  // ── Vòng đời dẫn đường ────────────────────────────────────────────

  Future<void> startNavigation({
    required RouteModel route,
    required Place destination,
    List<TrafficSign>? signs,
    RouteOptions options = const RouteOptions(),
  }) async {
    await _gpsSub?.cancel();
    _gpsSub = null;
    _destination = destination;
    _profile = route.profile;
    _options = options;
    // Biển báo là dữ liệu phụ; không chặn việc vào màn hình dẫn đường.
    _signs = signs ?? const [];
    _matcher = MapMatcher(route.geometry);
    _matchedSeg = 0;
    _offRouteCount = 0;
    _firedPrompts.clear();
    _currentSpeedLimit = 0;
    _lastSpeedFix = null;
    _smoothedSpeedMps = 0;
    final maneuvers = route.allManeuvers;
    final initialPosition = route.geometry.isEmpty
        ? null
        : route.geometry.first;
    final initialBearing = route.geometry.length > 1
        ? route.geometry.first.bearingTo(route.geometry[1])
        : 0.0;
    final initialManeuverIndex = _initialManeuverIndex(maneuvers);
    final initialDistanceToManeuver = _distanceToManeuver(
      _matcher,
      maneuvers,
      initialManeuverIndex,
      0,
    );

    state = NavSnapshot(
      phase: NavPhase.navigating,
      route: route,
      currentManeuverIndex: initialManeuverIndex,
      currentManeuver: _maneuverAt(maneuvers, initialManeuverIndex),
      nextManeuver: _maneuverAt(maneuvers, initialManeuverIndex + 1),
      distanceToManeuverM: initialDistanceToManeuver,
      distanceRemainingM: route.distanceM,
      etaSeconds: route.durationS,
      matchedPosition: initialPosition,
      currentPosition: initialPosition,
      bearing: initialBearing,
    );
    _bus.emit(const PhaseChanged(NavPhase.navigating));
    if (state.currentManeuver != null) {
      _emitInstruction(
        state.currentManeuver!,
        nextManeuver: state.nextManeuver,
      );
    }

    _gpsSub = ref
        .read(locationServiceProvider)
        .positions()
        .listen(_onFix, onError: (_) {});
    if (signs == null) unawaited(_loadSigns(route));
    unawaited(_seedCurrentFix(route));
  }

  void stop() {
    _gpsSub?.cancel();
    _gpsSub = null;
    _matcher = null;
    _lastSpeedFix = null;
    _smoothedSpeedMps = 0;
    state = const NavSnapshot(phase: NavPhase.idle);
    _bus.emit(const PhaseChanged(NavPhase.idle));
  }

  // ── Vòng lặp mỗi GPS fix (1 Hz) ───────────────────────────────────

  Future<void> _onFix(GpsFix fix) async {
    final route = state.route;
    final matcher = _matcher;
    if (route == null || matcher == null) return;
    final speedMps = _filteredSpeedMps(fix);
    final speedKmh = speedMps * 3.6;
    if (_rerouting) {
      state = state.copyWith(
        currentPosition: fix.position,
        bearing: fix.bearing,
        speedKmh: speedKmh,
        gpsWeak: fix.isWeak,
      );
      return;
    }

    final m = matcher.match(fix.position, minSeg: _matchedSeg);
    final routeBearing = _routeBearing(matcher, m, state.bearing);

    // Off-route detection (§4.3 bước 3).
    if (m.offsetM > _profile.offRouteThresholdM) {
      _offRouteCount++;
      if (_offRouteCount >= AppConfig.offRouteConsecutiveFixes) {
        state = state.copyWith(
          currentPosition: fix.position,
          routeProgressM: m.alongM,
          bearing: routeBearing,
          speedKmh: speedKmh,
          gpsWeak: fix.isWeak,
        );
        await _reroute(fix.position);
        return;
      }
    } else {
      _offRouteCount = 0;
      _matchedSeg = m.segmentIndex;
    }

    final maneuvers = route.allManeuvers;
    var idx = state.currentManeuverIndex;

    // Advance maneuver khi đã đi qua điểm rẽ hiện đang hiển thị.
    while (idx < maneuvers.length - 1) {
      final curAlong = matcher.alongAtVertex(maneuvers[idx].beginShapeIndex);
      if (m.alongM < curAlong + 5) break;
      idx++;
    }

    if (idx != state.currentManeuverIndex) {
      _firedPrompts.clear();
      final changedMan = _maneuverAt(maneuvers, idx);
      if (changedMan != null) {
        _emitInstruction(
          changedMan,
          nextManeuver: _maneuverAt(maneuvers, idx + 1),
        );
      }
    }

    final curMan = _maneuverAt(maneuvers, idx);
    final distToMan = _distanceToManeuver(matcher, maneuvers, idx, m.alongM);
    final distRemain = (matcher.totalLengthM - m.alongM)
        .clamp(0, double.infinity)
        .toDouble();

    // ETA: ước lượng theo tỉ lệ quãng đường còn lại + tốc độ tức thời.
    final frac = matcher.totalLengthM == 0
        ? 0
        : distRemain / matcher.totalLengthM;
    final etaByDuration = route.durationS * frac;
    final etaBySpeed = speedMps > 1.5 ? distRemain / speedMps : etaByDuration;
    final eta = (etaByDuration * 0.6 + etaBySpeed * 0.4);

    // Cập nhật biển báo & tốc độ giới hạn.
    final signUpdate = _updateSigns(m.alongM, speedKmh);

    final reachedDest =
        distRemain <= AppConfig.arriveRadiusM && idx >= maneuvers.length - 1;

    state = state.copyWith(
      phase: reachedDest ? NavPhase.arrived : NavPhase.navigating,
      currentManeuverIndex: idx,
      currentManeuver: curMan,
      nextManeuver: _maneuverAt(maneuvers, idx + 1),
      distanceToManeuverM: distToMan,
      distanceRemainingM: distRemain,
      etaSeconds: eta,
      matchedPosition: m.point,
      currentPosition: fix.position,
      routeProgressM: m.alongM,
      bearing: routeBearing,
      speedKmh: speedKmh,
      speedLimitKmh: signUpdate.limit,
      isOverSpeed: signUpdate.isOver,
      gpsWeak: fix.isWeak,
      approachingSign: signUpdate.sign,
      clearSign: signUpdate.sign == null,
    );

    // DistanceTick mỗi fix (§4.3 bước 4).
    _bus.emit(
      DistanceTick(
        distanceToManeuverM: distToMan,
        distanceRemainingM: distRemain,
        etaSeconds: eta,
        speedKmh: speedKmh,
      ),
    );

    if (curMan != null) {
      _maybeVoicePrompt(distToMan, curMan.type, curMan.instructionText);
    }

    if (reachedDest) {
      _bus.emit(const PhaseChanged(NavPhase.arrived));
      _bus.emit(const Arrived());
      _gpsSub?.cancel();
    }
  }

  // ── Biển báo + tốc độ (§4.4) ──────────────────────────────────────

  ({int limit, bool isOver, TrafficSign? sign}) _updateSigns(
    double alongM,
    double speedKmh,
  ) {
    // Tốc độ giới hạn = biển speedLimit gần nhất đã đi qua.
    var limit = _currentSpeedLimit;
    for (final s in _signs) {
      if (s.type == SignType.speedLimit && s.offsetM <= alongM) {
        limit = s.value;
      }
    }
    if (limit != _currentSpeedLimit) {
      _currentSpeedLimit = limit;
      final over = _isOver(speedKmh, limit);
      _bus.emit(SpeedLimitChanged(limit, over));
    }

    // Cảnh báo sớm: theo ~10 s di chuyển (§4.4).
    final warnDist = (speedKmh / 3.6) * 10;
    TrafficSign? approaching;
    for (final s in _signs) {
      final ahead = s.offsetM - alongM;
      if (ahead > 0 && ahead <= warnDist.clamp(60, 400)) {
        approaching = s;
        _bus.emit(SignApproaching(s, ahead));
        break;
      }
    }

    final over = _isOver(speedKmh, limit);
    return (limit: limit, isOver: over, sign: approaching);
  }

  bool _isOver(double speedKmh, int limit) {
    if (limit <= 0) return false;
    final thr = ref.read(settingsProvider).overspeedThreshold.kmh;
    return speedKmh > limit + thr;
  }

  double _filteredSpeedMps(GpsFix fix) {
    final previous = _lastSpeedFix;
    final raw = _validRawSpeedMps(fix);
    final derived = _derivedSpeedMps(previous, fix);
    final measured = _pickSpeedMps(raw, derived);
    final smoothed = _smoothSpeedMps(previous, fix, measured);
    _lastSpeedFix = fix;
    _smoothedSpeedMps = smoothed;
    return smoothed;
  }

  double? _validRawSpeedMps(GpsFix fix) {
    final speed = fix.safeSpeedMps;
    if (speed <= 0 || speed > _maxPlausibleSpeedMps) return null;
    final accuracy = fix.speedAccuracyMps;
    if (accuracy != null && accuracy > math.max(3, speed * 1.5)) return null;
    return speed;
  }

  double? _derivedSpeedMps(GpsFix? previous, GpsFix fix) {
    if (previous == null) return null;
    final dt =
        fix.timestamp.difference(previous.timestamp).inMilliseconds / 1000;
    if (dt <= 0.25 || dt > 10) return null;
    final distance = previous.position.distanceTo(fix.position);
    if (!distance.isFinite) return null;
    final noiseM = math.max(
      3.0,
      math.min(15.0, (previous.accuracyM + fix.accuracyM) * 0.5),
    );
    if (distance <= noiseM) return 0;
    final speed = distance / dt;
    if (speed > _maxPlausibleSpeedMps) return null;
    return speed;
  }

  double _pickSpeedMps(double? raw, double? derived) {
    if (derived == 0) return 0;
    if (raw != null && derived != null && derived > 0) {
      final disagree = raw > derived * 2.5 + 8 || derived > raw * 2.5 + 8;
      return disagree ? derived : raw;
    }
    return raw ?? derived ?? 0;
  }

  double _smoothSpeedMps(GpsFix? previous, GpsFix fix, double measured) {
    if (measured <= _stoppedSpeedMps) return 0;
    if (previous == null) return measured;
    final dt =
        fix.timestamp.difference(previous.timestamp).inMilliseconds / 1000;
    if (dt <= 0 || dt > 10) return measured;
    if (_smoothedSpeedMps == 0) return measured;

    final maxIncrease = _maxAccelerationMps2 * dt + 2;
    final capped = measured > _smoothedSpeedMps + maxIncrease
        ? _smoothedSpeedMps + maxIncrease
        : measured;
    final alpha = capped <= 0 ? 0.55 : 0.45;
    final value = _smoothedSpeedMps * (1 - alpha) + capped * alpha;
    return value < 0.4 ? 0 : value;
  }

  // ── Voice prompts (§4.3 bước 5) ───────────────────────────────────

  void _maybeVoicePrompt(double distToMan, ManeuverType type, String text) {
    final settings = ref.read(settingsProvider);
    if (!settings.ttsEnabled) return;
    for (final th in AppConfig.voicePromptThresholdsM) {
      if (!_firedPrompts.contains(th) && distToMan <= th) {
        _firedPrompts.add(th);
        final prefix = _voicePromptPrefix(th, settings.language);
        _bus.emit(VoicePrompt('$prefix$text', type));
      }
    }
  }

  String _voicePromptPrefix(double thresholdM, AppLanguage language) {
    if (language == AppLanguage.en) {
      return thresholdM >= 1000
          ? 'In 1 kilometer, '
          : thresholdM >= 300
          ? 'In ${thresholdM.round()} meters, '
          : thresholdM >= 100
          ? 'In ${thresholdM.round()} meters, '
          : '';
    }
    return thresholdM >= 1000
        ? 'Sau 1 ki lô mét, '
        : thresholdM >= 300
        ? 'Sau ${thresholdM.round()} mét, '
        : thresholdM >= 100
        ? 'Còn ${thresholdM.round()} mét, '
        : '';
  }

  void _emitInstruction(Maneuver maneuver, {Maneuver? nextManeuver}) {
    _lastInstrSeq = (_lastInstrSeq + 1) & 0xFF;
    _bus.emit(
      InstructionChanged(maneuver, _lastInstrSeq, nextManeuver: nextManeuver),
    );
  }

  Future<void> _seedCurrentFix(RouteModel route) async {
    try {
      final fix = await ref.read(locationServiceProvider).current();
      if (fix == null || state.route != route || !state.isActive) return;
      await _onFix(fix);
    } catch (_) {
      // Best-effort seed only; the live GPS stream remains authoritative.
    }
  }

  Future<void> _loadSigns(RouteModel route) async {
    try {
      final signs = await ref.read(signServiceProvider).signsAlongRoute(route);
      if (state.route != route || !state.isActive) return;
      _signs = signs;
    } catch (_) {
      if (state.route == route && state.isActive) _signs = const [];
    }
  }

  // ── Reroute (§4.3) ────────────────────────────────────────────────

  Future<void> _reroute(GeoPoint from) async {
    if (_destination == null || _rerouting) return;
    _rerouting = true;
    state = state.copyWith(phase: NavPhase.rerouting, currentPosition: from);
    _bus.emit(const Rerouting());
    try {
      final routes = await ref
          .read(routeServiceProvider)
          .route(
            origin: from,
            destination: _destination!.location,
            profile: _profile,
            options: _options,
            alternatives: false,
          );
      if (routes.isNotEmpty) {
        final r = routes.first;
        _matcher = MapMatcher(r.geometry);
        _matchedSeg = 0;
        _offRouteCount = 0;
        _firedPrompts.clear();
        final maneuvers = r.allManeuvers;
        final initialManeuverIndex = _initialManeuverIndex(maneuvers);
        final distanceToManeuver = _distanceToManeuver(
          _matcher,
          maneuvers,
          initialManeuverIndex,
          0,
        );
        final initialBearing = r.geometry.length > 1
            ? r.geometry.first.bearingTo(r.geometry[1])
            : state.bearing;
        state = state.copyWith(
          phase: NavPhase.navigating,
          route: r,
          currentManeuverIndex: initialManeuverIndex,
          currentManeuver: _maneuverAt(maneuvers, initialManeuverIndex),
          nextManeuver: _maneuverAt(maneuvers, initialManeuverIndex + 1),
          distanceToManeuverM: distanceToManeuver,
          distanceRemainingM: r.distanceM,
          matchedPosition: r.geometry.isEmpty ? from : r.geometry.first,
          currentPosition: from,
          routeProgressM: 0,
          bearing: initialBearing,
        );
        _bus.emit(const PhaseChanged(NavPhase.navigating));
        final initialManeuver = _maneuverAt(maneuvers, initialManeuverIndex);
        if (initialManeuver != null) {
          _emitInstruction(
            initialManeuver,
            nextManeuver: _maneuverAt(maneuvers, initialManeuverIndex + 1),
          );
        }
      }
    } catch (_) {
      // Giữ route cũ, báo không reroute được (§11.9). Quay lại navigating.
      state = state.copyWith(phase: NavPhase.navigating);
    } finally {
      _rerouting = false;
    }
  }

  int _initialManeuverIndex(List<Maneuver> maneuvers) {
    if (maneuvers.isEmpty) return 0;
    if (maneuvers.length > 1 && maneuvers.first.type == ManeuverType.depart) {
      return 1;
    }
    return 0;
  }

  Maneuver? _maneuverAt(List<Maneuver> maneuvers, int index) {
    return index >= 0 && index < maneuvers.length ? maneuvers[index] : null;
  }

  double _distanceToManeuver(
    MapMatcher? matcher,
    List<Maneuver> maneuvers,
    int index,
    double alongM,
  ) {
    final maneuver = _maneuverAt(maneuvers, index);
    if (matcher == null || maneuver == null) return 0;
    final maneuverAlong = matcher.alongAtVertex(maneuver.beginShapeIndex);
    return (maneuverAlong - alongM).clamp(0, double.infinity).toDouble();
  }

  double _routeBearing(MapMatcher matcher, MatchResult match, double fallback) {
    final geometry = matcher.geometry;
    if (geometry.length < 2) return _normalizeBearing(fallback);

    final from = match.point;
    final targetAlong = (match.alongM + _bearingLookAheadM)
        .clamp(0, matcher.totalLengthM)
        .toDouble();
    final ahead = _pointAtAlong(matcher, targetAlong);
    if (ahead != null && from.distanceTo(ahead) >= 1) {
      return from.bearingTo(ahead);
    }

    final seg = match.segmentIndex.clamp(0, geometry.length - 2);
    return geometry[seg].bearingTo(geometry[seg + 1]);
  }

  GeoPoint? _pointAtAlong(MapMatcher matcher, double alongM) {
    final geometry = matcher.geometry;
    if (geometry.isEmpty) return null;
    if (geometry.length == 1 || alongM <= 0) return geometry.first;

    for (var i = 0; i < geometry.length - 1; i++) {
      final start = matcher.alongAtVertex(i);
      final end = matcher.alongAtVertex(i + 1);
      if (alongM > end) continue;

      final length = end - start;
      if (length <= 0) return geometry[i + 1];

      final t = ((alongM - start) / length).clamp(0.0, 1.0);
      final a = geometry[i];
      final b = geometry[i + 1];
      return GeoPoint(a.lat + (b.lat - a.lat) * t, a.lng + (b.lng - a.lng) * t);
    }
    return geometry.last;
  }

  double _normalizeBearing(double value) {
    if (!value.isFinite) return 0;
    final normalized = value % 360;
    return normalized < 0 ? normalized + 360 : normalized;
  }
}

final navControllerProvider = NotifierProvider<NavController, NavSnapshot>(
  NavController.new,
);
