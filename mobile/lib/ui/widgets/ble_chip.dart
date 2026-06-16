import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../models/ble_device.dart';
import '../../providers/ble_providers.dart';
import '../ble_manager/ble_device_manager_screen.dart';

/// Chip trạng thái BLE 4 trạng thái (§11.3). Luôn hiển thị ở S1 và S4.
/// - unpaired: xám "Chưa ghép"
/// - connecting: vàng nhấp nháy "Đang kết nối…"
/// - connected: xanh "HUD ✓ {name}"
/// - disconnected: đỏ "Mất kết nối · {reconnectInSeconds}s"
///
/// Chạm → mở S5 (BLE Device Manager).
class BleChip extends ConsumerStatefulWidget {
  const BleChip({super.key});

  @override
  ConsumerState<BleChip> createState() => _BleChipState();
}

class _BleChipState extends ConsumerState<BleChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(bleStatusValueProvider);
    final scheme = context.scheme;
    final sem = context.semantic;

    final (Color bg, IconData icon, String label) = switch (status.state) {
      BleConnectionState.unpaired => (
          scheme.surfaceContainerHighest,
          Icons.bluetooth_disabled,
          'Chưa ghép',
        ),
      BleConnectionState.connecting => (
          sem.warning,
          Icons.bluetooth_searching,
          'Đang kết nối…',
        ),
      BleConnectionState.connected => (
          sem.bleConnected,
          Icons.bluetooth_connected,
          'HUD ✓ ${status.device?.name ?? ''}'.trim(),
        ),
      BleConnectionState.disconnected => (
          sem.danger,
          Icons.bluetooth_disabled,
          'Mất kết nối · ${status.reconnectInSeconds}s',
        ),
    };

    final onBg = status.state == BleConnectionState.unpaired
        ? scheme.onSurfaceVariant
        : Colors.white;

    final chip = Material(
      color: bg,
      borderRadius: BorderRadius.circular(20),
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const BleDeviceManagerScreen(),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: onBg),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(color: onBg),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (status.state == BleConnectionState.connecting) {
      return FadeTransition(opacity: _blink, child: chip);
    }
    return chip;
  }
}
