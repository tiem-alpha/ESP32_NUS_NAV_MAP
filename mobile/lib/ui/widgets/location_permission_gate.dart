import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/app_localizations.dart';
import '../../navigation/i_location_service.dart';
import '../../providers/app_providers.dart';
import '../../providers/ui_providers.dart';

/// Full-screen gate khi chưa có quyền vị trí / GPS tắt (§11.9 — "Chưa cấp
/// quyền vị trí" → illustration + nút "Cấp quyền", mở app settings nếu bị
/// từ chối vĩnh viễn). Bọc quanh [child] (S1); chỉ hiện [child] khi granted.
class LocationPermissionGate extends ConsumerStatefulWidget {
  final Widget child;

  const LocationPermissionGate({super.key, required this.child});

  @override
  ConsumerState<LocationPermissionGate> createState() =>
      _LocationPermissionGateState();
}

class _LocationPermissionGateState extends ConsumerState<LocationPermissionGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Người dùng có thể vừa bật GPS / cấp quyền trong Settings rồi quay lại.
    if (state == AppLifecycleState.resumed) {
      ref.read(locationPermissionProvider.notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(locationPermissionProvider);
    return status.when(
      data: (s) => s == LocationPermissionStatus.granted
          ? widget.child
          : _Gate(status: s),
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      // Fail-open: không khoá người dùng nếu việc kiểm tra quyền bị lỗi.
      error: (_, _) => widget.child,
    );
  }
}

class _Gate extends ConsumerWidget {
  final LocationPermissionStatus status;

  const _Gate({required this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final serviceDisabled = status == LocationPermissionStatus.serviceDisabled;
    final deniedForever = status == LocationPermissionStatus.deniedForever;
    final message = serviceDisabled
        ? l10n.locationServiceDisabledMessage
        : deniedForever
        ? l10n.locationPermissionDeniedForeverMessage
        : l10n.locationPermissionMessage;
    final buttonLabel = serviceDisabled || deniedForever
        ? l10n.openAppSettings
        : l10n.grantPermission;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.location_off,
                  size: 96,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.locationPermissionTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: FilledButton(
                    onPressed: () => _onPressed(ref, serviceDisabled, deniedForever),
                    child: Text(buttonLabel),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _onPressed(
    WidgetRef ref,
    bool serviceDisabled,
    bool deniedForever,
  ) async {
    final service = ref.read(locationServiceProvider);
    if (serviceDisabled) {
      await service.openLocationSettings();
    } else if (deniedForever) {
      await service.openAppSettings();
    } else {
      await ref.read(locationPermissionProvider.notifier).request();
      return;
    }
    await ref.read(locationPermissionProvider.notifier).refresh();
  }
}
