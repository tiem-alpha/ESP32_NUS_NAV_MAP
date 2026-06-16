import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/app_providers.dart';
import '../../providers/ble_providers.dart';

/// Banner vàng "Bluetooth tắt" + nút bật nhanh (Android) — §11.9.
/// Dùng ở S1 (map home) và S5 (BLE device manager). Tự ẩn (kích thước 0,
/// không chừa khoảng trống) khi adapter bật.
class BluetoothOffBanner extends ConsumerWidget {
  /// Khoảng trống chừa dưới banner khi đang hiện (0 khi ẩn).
  final double marginBottom;

  const BluetoothOffBanner({super.key, this.marginBottom = 0});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adapterOn = ref.watch(bleAdapterProvider).value ?? true;
    if (adapterOn) return const SizedBox.shrink();

    final l10n = context.l10n;
    return Padding(
      padding: EdgeInsets.only(bottom: marginBottom),
      child: Material(
        color: context.semantic.warning,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.bluetooth_disabled, color: Colors.black87),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.bluetoothOffBanner,
                  style: const TextStyle(color: Colors.black87),
                ),
              ),
              if (Platform.isAndroid)
                TextButton(
                  onPressed: () =>
                      ref.read(bleTransportProvider).turnOnAdapter(),
                  child: Text(
                    l10n.turnOnBluetooth,
                    style: const TextStyle(
                      color: Colors.black87,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
