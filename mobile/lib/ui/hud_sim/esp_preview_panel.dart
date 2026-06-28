import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/ble_providers.dart';
import 'hud_painter.dart';

/// Panel nhỏ hiển thị chính xác những gì ESP32 đang vẽ. Kích thước và tỉ lệ
/// lấy từ SYSTEM_INFO của thiết bị đã pair.
///
/// Đặt vào Stack của NavigationScreen để xem live preview bên cạnh bản đồ chính.
class EspPreviewPanel extends ConsumerWidget {
  final VoidCallback onClose;

  const EspPreviewPanel({super.key, required this.onClose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(bleMapSnapshotProvider);
    final routeColor = Theme.of(context).colorScheme.primary;
    final displayConfig = ref.watch(hudDisplayConfigProvider);
    final panelWidth = MediaQuery.sizeOf(context).shortestSide * 0.32;

    return Container(
      width: panelWidth,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24, width: 1),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(hasData: snap.hasValue, onClose: onClose),
          AspectRatio(
            aspectRatio: displayConfig.aspectRatio,
            child: snap.when(
              data: (s) => Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    painter: HudPainter(
                      displayConfig: displayConfig,
                      user: s.user,
                      headingDeg: s.headingDeg,
                      routeGeometry: s.route,
                      roads: s.roads,
                      speedKmh: s.speedKmh.toDouble(),
                      routeColor: routeColor,
                      roadColor: const Color(0xFF8A8A8E),
                      // Dùng đúng zoom ESP32: px_per_m = SCR_W / viewSpanM.
                      pxPerMOverride:
                          displayConfig.screenW / s.viewSpanM.clamp(10, 5000),
                    ),
                  ),
                  if (s.route.length < 2 && s.roads.isEmpty)
                    const _MapWaitingOverlay(),
                ],
              ),
              loading: () => const _Placeholder(label: 'Chờ BLE...'),
              error: (e, st) =>
                  const _Placeholder(label: 'Lỗi BLE', isError: true),
            ),
          ),
          snap.maybeWhen(
            data: (s) =>
                _Footer(speedKmh: s.speedKmh, navigating: s.navigating),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _MapWaitingOverlay extends StatelessWidget {
  const _MapWaitingOverlay();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(8),
        child: Text(
          'Đang chờ dữ liệu bản đồ…',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54, fontSize: 9),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final bool hasData;
  final VoidCallback onClose;

  const _Header({required this.hasData, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF111111),
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: hasData
                  ? const Color(0xFF34A853)
                  : const Color(0xFF5F6368),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          const Text(
            'ESP32',
            style: TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: onClose,
            behavior: HitTestBehavior.opaque,
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.close, color: Colors.white54, size: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final int speedKmh;
  final bool navigating;

  const _Footer({required this.speedKmh, required this.navigating});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF111111),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Row(
        children: [
          Text(
            '$speedKmh km/h',
            style: const TextStyle(color: Colors.white70, fontSize: 10),
          ),
          const Spacer(),
          if (navigating)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFF1A73E8),
                borderRadius: BorderRadius.circular(3),
              ),
              child: const Text(
                'NAV',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  final String label;
  final bool isError;

  const _Placeholder({required this.label, this.isError = false});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF1B1B1F),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isError ? Icons.bluetooth_disabled : Icons.bluetooth_searching,
              color: isError ? Colors.red.shade400 : Colors.white24,
              size: 20,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                color: isError ? Colors.red.shade300 : Colors.white38,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
