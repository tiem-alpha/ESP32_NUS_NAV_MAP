import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_typography.dart';
import '../../models/ble_device.dart';
import '../../models/geo_point.dart';
import '../../models/maneuver_type.dart';
import '../../models/nav_state.dart';
import '../../models/road_segment.dart';
import '../../navigation/nav_controller.dart';
import '../../navigation/nav_voice.dart';
import '../../providers/app_providers.dart';
import '../../providers/ble_providers.dart';
import '../../services/nav_foreground_task.dart';
import '../format.dart';
import '../map/map_view.dart';
import '../hud_sim/esp_preview_panel.dart';
import '../widgets/ble_chip.dart';
import '../widgets/maneuver_icon.dart';
import '../widgets/speed_sign.dart';

/// S4 — Navigation full-screen (§11.6). Màn hình quan trọng nhất.
/// Watch navControllerProvider; banner xanh turn-by-turn, next strip, BLE chip,
/// biển tốc độ, map heading-up, ô tốc độ, bottom bar ETA + mute + step list.
/// rerouting → banner vàng; arrived → sheet "Đã đến nơi".
class NavigationScreen extends ConsumerStatefulWidget {
  const NavigationScreen({super.key});

  @override
  ConsumerState<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends ConsumerState<NavigationScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _overspeedBlink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..repeat(reverse: true);

  bool _arrivedShown = false;
  bool _ending = false;
  bool _showEspPreview = false;

  // MAP_POSITION: gửi vị trí mỗi 5m; resend map binary mỗi ~300m.
  // Phải nhỏ hơn _kMapWindowM (1.2km, ble_bridge.dart) — nếu không anchor có
  // thể trôi ra ngoài cửa sổ clip trước khi resend, làm hụt route/road gần đó.
  final _mapKey = GlobalKey<MapViewState>();
  GeoPoint? _lastMapPosSent;
  static const _mapPosMoveThresholdM = 5.0; // gửi MAP_POSE mỗi GPS tick (~1 Hz)
  GeoPoint? _lastMapDataCenter;
  static const _mapDataResendThresholdM = 100.0;

  // Fallback view_span_dm trước khi MapView layout xong (xem viewSpanMAt).
  static const _defaultViewSpanM = 200.0;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    FlutterForegroundTask.addTaskDataCallback(_onForegroundData);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(navVoiceProvider); // eagerly init TTS
        _startForegroundService();
      }
    });
  }

  void _onForegroundData(Object data) {
    final action = data is String ? data : (data as Map?)?['action'];
    if (action == 'stop_nav' && mounted) {
      _endNavigation();
    }
  }

  Future<void> _startForegroundService() async {
    final l10n = context.l10n;
    final permission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    if (await FlutterForegroundTask.isRunningService) {
      await _updateForegroundNotification(ref.read(navControllerProvider));
      return;
    }

    final result = await FlutterForegroundTask.startService(
      serviceId: 256,
      serviceTypes: [ForegroundServiceTypes.location],
      notificationTitle: l10n.navigationInProgress,
      notificationText: l10n.locating,
      callback: startNavForegroundTask,
      notificationButtons: [NotificationButton(id: 'btn_stop', text: l10n.end)],
    );
    if (result case ServiceRequestFailure(:final error) when mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.notificationError(error))));
    }
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onForegroundData);
    FlutterForegroundTask.stopService();
    WakelockPlus.disable();
    _overspeedBlink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(navControllerProvider);

    // BLE reconnect → xoá cả hai pos-cache để GPS tick kế tiếp gửi lại ngay.
    // _lastMapPosSent phải reset: nếu device đứng yên (<5m) sau reconnect,
    // outer gate không thỏa → cả MAP_POSE lẫn map data đều không được gửi.
    ref.listen<AsyncValue<BleStatus>>(bleStatusProvider, (prev, next) {
      final prevState = prev?.value?.state;
      final nextState = next.value?.state;
      if (prevState != BleConnectionState.connected &&
          nextState == BleConnectionState.connected) {
        _lastMapDataCenter = null;
        _lastMapPosSent = null;
      }
    });

    // Hiện arrival sheet một lần khi tới nơi; cập nhật notification dẫn đường.
    ref.listen<NavSnapshot>(navControllerProvider, (prev, next) {
      // Update foreground service notification with current instruction.
      if (next.phase == NavPhase.navigating) {
        _updateForegroundNotification(next);
      }
      // Arrival sheet (existing logic).
      if (next.phase == NavPhase.arrived && !_arrivedShown) {
        _arrivedShown = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showArrivalSheet();
        });
      }
      // Gửi MAP_POSITION mỗi 15m; resend map data mỗi ~800m.
      final pos = next.matchedPosition ?? next.currentPosition;
      if (pos != null) {
        final lastPos = _lastMapPosSent;
        if (lastPos == null || lastPos.distanceTo(pos) >= _mapPosMoveThresholdM) {
          _lastMapPosSent = pos;
          final viewSpanM =
              _mapKey.currentState?.viewSpanMAt(pos.lat) ?? _defaultViewSpanM;
          ref.read(bleBridgeProvider).sendMapPosition(
            lat: pos.lat,
            lng: pos.lng,
            bearing: next.bearing,
            speedKmh: next.speedKmh.round(),
            viewSpanM: viewSpanM,
          );
          // Chỉ gửi map data khi đang dẫn đường (isActive). Nếu không guard ở
          // đây, _lastMapDataCenter bị update sớm trong phase routing → khi
          // phase chuyển sang navigating không trigger lại vì pos chưa di chuyển
          // đủ 800 m → route/roads không bao giờ được gửi lần đầu.
          if (next.isActive) {
            final lastCenter = _lastMapDataCenter;
            if (lastCenter == null ||
                lastCenter.distanceTo(pos) >= _mapDataResendThresholdM) {
              _lastMapDataCenter = pos;
              _trySendMapData(snap: next, center: pos).then((sent) {
                // Rollback nếu không gửi được (Overpass lỗi + fallback rỗng):
                // giữ lastCenter cũ để GPS tick tiếp theo retry ngay.
                if (!sent && mounted) _lastMapDataCenter = lastCenter;
              });
            }
          }
        }
      }
    });

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: _map(snap)),
          // Banner trên cùng.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(bottom: false, child: _topArea(snap)),
          ),
          // Ô tốc độ góc dưới-trái.
          Positioned(left: 12, bottom: 96, child: _speedBox(snap)),
          // Preview ESP32 (góc dưới-phải, ẩn/hiện theo nút toggle).
          if (_showEspPreview)
            Positioned(
              right: 10,
              bottom: 136,
              child: EspPreviewPanel(
                onClose: () => setState(() => _showEspPreview = false),
              ),
            ),
          // Nút toggle ESP32 preview (góc dưới-phải, ngay trên bottom bar).
          Positioned(
            right: 10,
            bottom: 92,
            child: _EspToggleButton(
              active: _showEspPreview,
              onTap: () => setState(() => _showEspPreview = !_showEspPreview),
            ),
          ),
          // GPS yếu chip.
          if (snap.gpsWeak)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(child: _gpsWeakChip()),
            ),
          // Bottom bar.
          Positioned(left: 0, right: 0, bottom: 0, child: _bottomBar(snap)),
        ],
      ),
    );
  }

  Widget _map(NavSnapshot snap) {
    return MapView(
      key: _mapKey,
      routes: snap.route == null ? const [] : [snap.route!],
      selectedIndex: 0,
      userLocation: snap.matchedPosition ?? snap.currentPosition,
      routeProgressM: snap.routeProgressM,
      bearing: snap.bearing,
      follow: true,
      navigationMode: true,
      destination: snap.route?.destination,
    );
  }

  Widget _topArea(NavSnapshot snap) {
    return Column(
      children: [
        if (snap.phase == NavPhase.rerouting)
          _reroutingBanner()
        else
          _instructionBanner(snap),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const BleChip(),
              SpeedSign(limit: snap.speedLimitKmh, isOver: snap.isOverSpeed),
            ],
          ),
        ),
      ],
    );
  }

  Widget _instructionBanner(NavSnapshot snap) {
    final man = snap.currentManeuver;
    final navBanner = context.semantic.navBanner;
    return Material(
      color: navBanner,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ManeuverIcon(
                  man?.type ?? ManeuverType.straight,
                  size: 48,
                  color: Colors.white,
                ),
                const SizedBox(width: 12),
                Text(
                  UiFormat.distance(snap.distanceToManeuverM),
                  style: AppTypography.navDistance(Colors.white),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              man?.instructionText ?? context.l10n.navigating,
              style: AppTypography.navStreet(
                Colors.white,
              ).copyWith(fontSize: 18, fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if ((man?.streetName ?? '').isNotEmpty)
              Text(
                man!.streetName,
                style: AppTypography.navStreet(Colors.white),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            // "Sau đó" next-maneuver strip khi < 500 m.
            if (snap.nextManeuver != null && snap.distanceToManeuverM < 500)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Text(
                      context.l10n.then,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                    ManeuverIcon(
                      snap.nextManeuver!.type,
                      size: 20,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        snap.nextManeuver!.streetName.isEmpty
                            ? snap.nextManeuver!.instructionText
                            : snap.nextManeuver!.streetName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _reroutingBanner() {
    return Material(
      color: context.semantic.warning,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Row(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: Colors.black87,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              context.l10n.rerouting,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: Colors.black87),
            ),
          ],
        ),
      ),
    );
  }

  Widget _gpsWeakChip() {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 140),
        child: Material(
          color: context.semantic.warning,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.gps_off, size: 16, color: Colors.black87),
                const SizedBox(width: 6),
                Text(
                  context.l10n.gpsWeak,
                  style: TextStyle(color: Colors.black87),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _speedBox(NavSnapshot snap) {
    final danger = context.semantic.danger;
    final box = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: snap.isOverSpeed ? danger : context.scheme.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 6)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${snap.speedKmh.round()}',
            style: AppTypography.speedValue(
              snap.isOverSpeed ? Colors.white : context.scheme.onSurface,
            ),
          ),
          Text(
            'km/h',
            style: TextStyle(
              fontSize: 11,
              color: snap.isOverSpeed
                  ? Colors.white
                  : context.scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
    if (snap.isOverSpeed) {
      return FadeTransition(opacity: _overspeedBlink, child: box);
    }
    return box;
  }

  Widget _bottomBar(NavSnapshot snap) {
    final voice = ref.read(navVoiceProvider);
    final l10n = context.l10n;
    return Material(
      color: context.scheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              _endButton(),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      UiFormat.eta(snap.etaSeconds),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      '${UiFormat.distance(snap.distanceRemainingM)} · '
                      '${UiFormat.duration(snap.etaSeconds)}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: context.scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                iconSize: 28,
                tooltip: voice.muted ? l10n.unmuteVoice : l10n.muteVoice,
                icon: Icon(voice.muted ? Icons.volume_off : Icons.volume_up),
                onPressed: () => setState(voice.toggleMute),
              ),
              IconButton(
                iconSize: 28,
                tooltip: l10n.steps,
                icon: const Icon(Icons.list),
                onPressed: () => _showStepList(snap),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Nút ✕: giữ 1s HOẶC xác nhận dialog → stop + pop.
  Widget _endButton() {
    return GestureDetector(
      onLongPress: _endNavigation,
      child: SizedBox(
        width: 56,
        height: 56,
        child: IconButton.filled(
          style: IconButton.styleFrom(
            backgroundColor: context.semantic.danger,
            foregroundColor: Colors.white,
          ),
          icon: const Icon(Icons.close),
          tooltip: context.l10n.endHold,
          onPressed: _confirmEnd,
        ),
      ),
    );
  }

  Future<void> _confirmEnd() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.endNavigationTitle),
        content: Text(context.l10n.endNavigationMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.l10n.continueNavigation),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(context.l10n.end),
          ),
        ],
      ),
    );
    if (ok == true) _endNavigation();
  }

  /// Trả true nếu đã gửi (dù roads rỗng vẫn tính là gửi).
  /// Trả false nếu điều kiện không thỏa (route null / phase sai / unmounted).
  Future<bool> _trySendMapData({
    required NavSnapshot snap,
    required GeoPoint center,
  }) async {
    final route = snap.route;
    if (route == null || !snap.isActive) return false;

    debugPrint('[MapData] _trySendMapData: center=${center.lat.toStringAsFixed(5)},${center.lng.toStringAsFixed(5)} route=${route.geometry.length}pts progress=${snap.routeProgressM.round()}m');

    // Ưu tiên Overpass (bán kính 1.5 km, đầy đủ hơn). Nếu Overpass trả rỗng
    // (lỗi mạng / timeout), dùng vector tiles của MapLibre làm fallback (~450 m
    // viewport, không cần network thêm vì tiles đã được tải sẵn).
    List<RoadSegment> roads;
    try {
      roads = await ref
          .read(overpassRoadServiceProvider)
          .queryRoadsAround(lat: center.lat, lng: center.lng, radiusM: 1500.0);
      debugPrint('[MapData] Overpass → ${roads.length} roads');
    } catch (e) {
      debugPrint('[MapData] Overpass ERROR: $e');
      roads = const [];
    }

    if (roads.isEmpty) {
      final mapState = _mapKey.currentState;
      final fallback = mapState != null
          ? await mapState.queryRoadsForMiniMap(center.lat, center.lng)
          : const <RoadSegment>[];
      debugPrint('[MapData] MapLibre fallback → ${fallback.length} roads');
      roads = fallback;
    }

    if (!mounted) return false;
    debugPrint('[MapData] sendMapData: ${roads.length} roads total');
    await ref.read(bleBridgeProvider).sendMapData(
      routeGeometry: route.geometry,
      roads: roads,
      routeProgressM: snap.routeProgressM,
    );
    return true;
  }

  void _endNavigation() {
    if (_ending) return;
    _ending = true;
    ref.read(navControllerProvider.notifier).stop();
    if (mounted && Navigator.canPop(context)) Navigator.pop(context);
  }

  Future<void> _updateForegroundNotification(NavSnapshot snap) async {
    if (!mounted) return;
    final man = snap.currentManeuver;
    final endText = context.l10n.end;
    if (man == null) return;
    if (!await FlutterForegroundTask.isRunningService) return;
    if (!mounted) return;
    await FlutterForegroundTask.updateService(
      notificationTitle:
          'NavHUD · ${UiFormat.distance(snap.distanceToManeuverM)}',
      notificationText: man.instructionText,
      notificationButtons: [NotificationButton(id: 'btn_stop', text: endText)],
    );
  }

  void _showStepList(NavSnapshot snap) {
    final route = snap.route;
    if (route == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => ListView(
        children: [
          for (final m in route.allManeuvers)
            ListTile(
              leading: ManeuverIcon(m.type, size: 28),
              title: Text(m.instructionText),
              subtitle: m.streetName.isEmpty ? null : Text(m.streetName),
              trailing: Text(UiFormat.distance(m.distanceToNextM)),
            ),
        ],
      ),
    );
  }

  void _showArrivalSheet() {
    showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.flag, size: 56, color: context.semantic.navBanner),
              const SizedBox(height: 12),
              Text(
                context.l10n.arrived,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton(
                  onPressed: () {
                    Navigator.pop(ctx); // đóng sheet
                    _endNavigation();
                  },
                  child: Text(context.l10n.close),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Nút nhỏ toggle ESP32 preview (góc dưới-phải màn hình dẫn đường).
class _EspToggleButton extends StatelessWidget {
  final bool active;
  final VoidCallback onTap;

  const _EspToggleButton({required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: active ? const Color(0xFF1A73E8) : Colors.black54,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white30, width: 1),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
        ),
        child: const Icon(Icons.monitor, color: Colors.white, size: 18),
      ),
    );
  }
}
