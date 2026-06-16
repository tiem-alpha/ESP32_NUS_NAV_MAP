import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/geo_point.dart';
import '../../models/maneuver_type.dart';
import '../../models/nav_state.dart';
import '../../models/road_segment.dart';
import '../../navigation/nav_controller.dart';
import '../../providers/app_providers.dart';
import '../format.dart';
import '../widgets/maneuver_icon.dart';
import 'hud_painter.dart';

/// S — Mô phỏng HUD (dev/preview). Render **giống hệt** view full-screen của
/// HUD ESP32 (DESIGN §6–§8) từ chính dữ liệu app gửi qua BLE, không cần phần
/// cứng. Ưu tiên NavSnapshot thật (đang dẫn đường); nếu không có → chế độ Demo
/// với tuyến + xe chạy mô phỏng.
class HudSimScreen extends ConsumerStatefulWidget {
  const HudSimScreen({super.key});

  @override
  ConsumerState<HudSimScreen> createState() => _HudSimScreenState();
}

class _HudSimScreenState extends ConsumerState<HudSimScreen> {
  /// Bật demo (mặc định bật để dùng được ngay khi chưa dẫn đường).
  bool _demo = true;

  // --- Trạng thái demo ---
  Timer? _demoTimer;
  int _demoIndex = 0; // đoạn polyline hiện tại
  double _demoT = 0; // tiến độ trong đoạn (0..1)
  late final List<GeoPoint> _demoRoute = _buildDemoRoute();

  // --- Cache roads quanh user (READ ONLY service) ---
  List<RoadSegment> _roads = const [];
  GeoPoint? _roadsAnchor; // điểm đã fetch roads gần nhất
  bool _roadsLoading = false;

  @override
  void initState() {
    super.initState();
    _startDemo();
    // Nạp roads cho vị trí ban đầu.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeFetchRoads());
  }

  @override
  void dispose() {
    _demoTimer?.cancel();
    super.dispose();
  }

  void _startDemo() {
    _demoTimer?.cancel();
    if (!_demo) return;
    // ~20 fps để xe di chuyển mượt.
    _demoTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted) return;
      setState(_advanceDemo);
    });
  }

  /// Đẩy xe demo tiến dọc polyline; vòng lại khi tới đích.
  void _advanceDemo() {
    if (_demoRoute.length < 2) return;
    final a = _demoRoute[_demoIndex];
    final b = _demoRoute[(_demoIndex + 1) % _demoRoute.length];
    final segLen = a.distanceTo(b).clamp(1.0, double.infinity);
    // ~12 m/s (~43 km/h) * 0,05 s = 0,6 m mỗi tick.
    _demoT += 0.6 / segLen;
    if (_demoT >= 1.0) {
      _demoT = 0;
      _demoIndex = (_demoIndex + 1) % (_demoRoute.length - 1);
    }
    _maybeFetchRoads();
  }

  /// Vị trí + heading demo nội suy trên polyline.
  ({GeoPoint pos, double heading, double speed}) _demoPose() {
    final a = _demoRoute[_demoIndex];
    final b = _demoRoute[(_demoIndex + 1) % _demoRoute.length];
    final pos = GeoPoint(
      a.lat + (b.lat - a.lat) * _demoT,
      a.lng + (b.lng - a.lng) * _demoT,
    );
    return (pos: pos, heading: a.bearingTo(b), speed: 43);
  }

  /// Lấy dữ liệu thực tế từ NavSnapshot khi đang dẫn đường, ngược lại demo.
  _HudData _resolveData(NavSnapshot snap) {
    final realActive = !_demo &&
        snap.phase == NavPhase.navigating &&
        snap.route != null &&
        (snap.matchedPosition ?? snap.currentPosition) != null;

    if (realActive) {
      final user = snap.matchedPosition ?? snap.currentPosition!;
      return _HudData(
        user: user,
        heading: snap.bearing,
        speedKmh: snap.speedKmh,
        route: snap.route!.geometry,
        maneuver: snap.currentManeuverType,
        distanceToManeuverM: snap.distanceToManeuverM,
        distanceRemainingM: snap.distanceRemainingM,
        etaSeconds: snap.etaSeconds,
        speedLimitKmh: snap.speedLimitKmh,
        isOverSpeed: snap.isOverSpeed,
        gpsWeak: snap.gpsWeak,
        isDemo: false,
      );
    }

    // Demo: dựng các trường overlay tổng hợp.
    final pose = _demoPose();
    final remaining = _demoRemainingM(pose.pos);
    return _HudData(
      user: pose.pos,
      heading: pose.heading,
      speedKmh: pose.speed,
      route: _demoRoute,
      maneuver: ManeuverType.turnRight,
      distanceToManeuverM: _demoDistToTurn(),
      distanceRemainingM: remaining,
      etaSeconds: remaining / 11.0, // ~40 km/h
      speedLimitKmh: 40,
      isOverSpeed: pose.speed > 40,
      gpsWeak: false,
      isDemo: true,
    );
  }

  double _demoDistToTurn() {
    // Khoảng cách tới điểm gấp khúc kế tiếp trên polyline demo.
    final pose = _demoPose();
    final turn = _demoRoute[(_demoIndex + 1) % _demoRoute.length];
    return pose.pos.distanceTo(turn);
  }

  double _demoRemainingM(GeoPoint from) {
    var total = from.distanceTo(_demoRoute[(_demoIndex + 1) % _demoRoute.length]);
    for (var i = _demoIndex + 1; i < _demoRoute.length - 1; i++) {
      total += _demoRoute[i].distanceTo(_demoRoute[i + 1]);
    }
    return total;
  }

  /// Tải roads quanh user khi di chuyển xa anchor cũ (>300 m). Best-effort.
  Future<void> _maybeFetchRoads() async {
    final NavSnapshot snap = ref.read(navControllerProvider);
    final data = _resolveData(snap);
    final user = data.user;
    if (_roadsLoading) return;
    final anchor = _roadsAnchor;
    if (anchor != null && anchor.distanceTo(user) < 300) return;

    _roadsLoading = true;
    try {
      final roads = await ref.read(overpassRoadServiceProvider).queryRoadsAround(
            lat: user.lat,
            lng: user.lng,
            radiusM: 1500,
          );
      if (!mounted) return;
      setState(() {
        _roads = roads;
        _roadsAnchor = user;
      });
    } catch (_) {
      // Bỏ qua: bản đồ nền là phụ trợ, vẫn vẽ được route + user.
    } finally {
      _roadsLoading = false;
    }
  }

  /// Tuyến demo: vài điểm quanh Hà Nội (Hồ Hoàn Kiếm → quanh phố cổ).
  List<GeoPoint> _buildDemoRoute() => const [
        GeoPoint(21.0285, 105.8542),
        GeoPoint(21.0312, 105.8540),
        GeoPoint(21.0330, 105.8525),
        GeoPoint(21.0335, 105.8495),
        GeoPoint(21.0360, 105.8480),
        GeoPoint(21.0388, 105.8472),
        GeoPoint(21.0405, 105.8450),
      ];

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(navControllerProvider);
    final data = _resolveData(snap);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Mô phỏng HUD')),
      body: Column(
        children: [
          // Thanh chuyển chế độ.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Chế độ Demo'),
                    subtitle: Text(
                      data.isDemo
                          ? 'Đang dùng tuyến & xe mô phỏng'
                          : 'Đang dùng dữ liệu dẫn đường thật',
                    ),
                    value: _demo,
                    onChanged: (v) {
                      setState(() => _demo = v);
                      _startDemo();
                      _maybeFetchRoads();
                    },
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: _DeviceBezel(
                child: _HudView(
                  data: data,
                  roads: _roads,
                  routeColor: theme.colorScheme.primary,
                  roadColor: const Color(0xFF8A8A8E),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Khung 240×320 — chiếu heading-up, user neo giữa-dưới (giống HUD ESP32).',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// Gói dữ liệu đã chuẩn hoá cho HUD (từ NavSnapshot thật hoặc demo).
class _HudData {
  final GeoPoint user;
  final double heading;
  final double speedKmh;
  final List<GeoPoint> route;
  final ManeuverType maneuver;
  final double distanceToManeuverM;
  final double distanceRemainingM;
  final double etaSeconds;
  final int speedLimitKmh;
  final bool isOverSpeed;
  final bool gpsWeak;
  final bool isDemo;

  const _HudData({
    required this.user,
    required this.heading,
    required this.speedKmh,
    required this.route,
    required this.maneuver,
    required this.distanceToManeuverM,
    required this.distanceRemainingM,
    required this.etaSeconds,
    required this.speedLimitKmh,
    required this.isOverSpeed,
    required this.gpsWeak,
    required this.isDemo,
  });
}

/// Vỏ thiết bị (bezel) giữ đúng tỉ lệ 240×320.
class _DeviceBezel extends StatelessWidget {
  final Widget child;
  const _DeviceBezel({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0A),
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 12, offset: Offset(0, 6)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AspectRatio(
          aspectRatio: HudFrame.width / HudFrame.height,
          child: SizedBox(
            width: HudFrame.width,
            height: HudFrame.height,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Layer map (CustomPaint) + overlay (widget Flutter đè lên) — overlay dạng
/// widget cho text/icon sắc nét hơn vẽ trong painter (DESIGN §8).
class _HudView extends StatelessWidget {
  final _HudData data;
  final List<RoadSegment> roads;
  final Color routeColor;
  final Color roadColor;

  const _HudView({
    required this.data,
    required this.roads,
    required this.routeColor,
    required this.roadColor,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // --- Map layer ---
        CustomPaint(
          painter: HudPainter(
            user: data.user,
            headingDeg: data.heading,
            routeGeometry: data.route,
            roads: roads,
            speedKmh: data.speedKmh,
            routeColor: routeColor,
            roadColor: roadColor,
          ),
        ),

        // --- Overlay trên-trái: mũi tên rẽ + khoảng cách tới điểm rẽ ---
        Positioned(
          top: 6,
          left: 6,
          child: _Panel(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ManeuverIcon(data.maneuver, size: 26, color: Colors.white),
                const SizedBox(width: 6),
                Text(
                  UiFormat.distance(data.distanceToManeuverM),
                  style: _overlayText(16, FontWeight.w700),
                ),
              ],
            ),
          ),
        ),

        // --- Overlay trên-phải: biển tốc độ giới hạn ---
        if (data.speedLimitKmh > 0)
          Positioned(
            top: 6,
            right: 6,
            child: _SpeedLimitBadge(
              limit: data.speedLimitKmh,
              over: data.isOverSpeed,
            ),
          ),

        // --- Overlay dưới-trái: tốc độ hiện tại ---
        Positioned(
          bottom: 6,
          left: 6,
          child: _Panel(
            child: Text(
              '${data.speedKmh.round()} km/h',
              style: _overlayText(16, FontWeight.w700),
            ),
          ),
        ),

        // --- Overlay dưới-phải: ETA · còn lại ---
        Positioned(
          bottom: 6,
          right: 6,
          child: _Panel(
            child: Text(
              '${UiFormat.eta(data.etaSeconds)} · '
              '${UiFormat.distance(data.distanceRemainingM)}',
              style: _overlayText(14, FontWeight.w600),
            ),
          ),
        ),

        // --- Chấm trạng thái BLE/GPS (giữa-trên) ---
        Positioned(
          top: 8,
          left: 0,
          right: 0,
          child: Center(
            child: _StatusDot(
              ok: !data.gpsWeak,
              label: data.isDemo ? 'DEMO' : (data.gpsWeak ? 'GPS yếu' : 'GPS OK'),
            ),
          ),
        ),
      ],
    );
  }

  static TextStyle _overlayText(double size, FontWeight weight) => TextStyle(
        color: Colors.white,
        fontSize: size,
        fontWeight: weight,
        shadows: const [Shadow(color: Colors.black, blurRadius: 2)],
      );
}

/// Panel bán trong suốt (giống widget LVGL nền mờ — §6).
class _Panel extends StatelessWidget {
  final Widget child;
  const _Panel({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }
}

/// Biển tốc độ kiểu VN: viền đỏ, nền trắng. Đỏ rực khi vượt tốc.
class _SpeedLimitBadge extends StatelessWidget {
  final int limit;
  final bool over;
  const _SpeedLimitBadge({required this.limit, required this.over});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: over ? const Color(0xFFD93025) : Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFD93025), width: 4),
      ),
      child: Text(
        '$limit',
        style: TextStyle(
          color: over ? Colors.white : Colors.black,
          fontSize: 16,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// Chấm trạng thái BLE/GPS.
class _StatusDot extends StatelessWidget {
  final bool ok;
  final String label;
  const _StatusDot({required this.ok, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: ok ? const Color(0xFF34A853) : const Color(0xFFF9AB00),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
