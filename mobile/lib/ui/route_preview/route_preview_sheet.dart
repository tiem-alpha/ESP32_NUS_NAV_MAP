import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../models/route_model.dart';
import '../../models/route_preview_state.dart';
import '../../providers/nav_providers.dart';
import '../format.dart';
import '../widgets/maneuver_icon.dart';

/// S3 — Route Preview bottom sheet (§11.5).
/// Hiển thị tuyến đang chọn (thời gian · km, summary), cảnh báo theo profile,
/// alternatives, checkbox tránh phí/cao tốc, nút BẮT ĐẦU 56dp, và (khi kéo lên)
/// danh sách maneuver. Xử lý AsyncLoading / AsyncError.
///
/// Đặt trong một DraggableScrollableSheet ở MapHomeScreen; nội dung nhận
/// [scrollController] để cuộn được khi snap 90%.
class RoutePreviewSheet extends ConsumerWidget {
  final ScrollController? scrollController;

  const RoutePreviewSheet({super.key, this.scrollController});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(routePreviewProvider);

    return async.when(
      loading: () => _wrap(
        context,
        const SizedBox(
          height: 180,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (e, _) => _wrap(context, _errorCard(context, ref, e)),
      data: (state) {
        if (state == null) return const SizedBox.shrink();
        return _wrap(context, _content(context, ref, state));
      },
    );
  }

  Widget _wrap(BuildContext context, Widget child) {
    return Container(
      decoration: BoxDecoration(
        color: context.scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: child,
    );
  }

  Widget _errorCard(BuildContext context, WidgetRef ref, Object error) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 48, color: context.semantic.danger),
          const SizedBox(height: 12),
          Text(
            l10n.routeErrorTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            '$error',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              final dest = ref.read(routePreviewProvider).value?.destination;
              // Re-request: dùng lại destination nếu state cũ còn; nếu không thì
              // không làm gì (sheet sẽ đóng từ home).
              if (dest != null) {
                ref.read(routePreviewProvider.notifier).request(dest);
              }
            },
            icon: const Icon(Icons.refresh),
            label: Text(l10n.retry),
          ),
        ],
      ),
    );
  }

  Widget _content(
    BuildContext context,
    WidgetRef ref,
    RoutePreviewState state,
  ) {
    final selected = state.selected;
    final children = <Widget>[
      _header(context, selected),
      if (selected.warnings.isNotEmpty) _warnings(context, selected),
      const SizedBox(height: 8),
      _alternatives(context, ref, state),
      const Divider(height: 24),
      _avoidRow(context, ref, state),
      const SizedBox(height: 12),
      _startButton(context, ref),
      const SizedBox(height: 8),
      _stepListHeader(context),
      ..._stepList(context, selected),
      const SizedBox(height: 24),
    ];

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      children: children,
    );
  }

  Widget _header(BuildContext context, RouteModel route) {
    final tt = Theme.of(context).textTheme;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${UiFormat.duration(route.durationS)} · '
          '${UiFormat.distance(route.distanceM)}',
          style: tt.headlineSmall,
        ),
        if (route.summary.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              l10n.via(route.summary),
              style: tt.bodyMedium?.copyWith(
                color: context.scheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  Widget _warnings(BuildContext context, RouteModel route) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final w in route.warnings)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: context.semantic.warning,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      w,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: context.semantic.warning,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _alternatives(
    BuildContext context,
    WidgetRef ref,
    RoutePreviewState state,
  ) {
    if (state.routes.length <= 1) return const SizedBox.shrink();
    return Column(
      children: [
        for (var i = 0; i < state.routes.length; i++)
          if (i != state.selectedIndex)
            _altTile(context, ref, state.routes[i], i),
      ],
    );
  }

  Widget _altTile(
    BuildContext context,
    WidgetRef ref,
    RouteModel route,
    int index,
  ) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.alt_route),
      title: Text(
        '${UiFormat.duration(route.durationS)} · '
        '${UiFormat.distance(route.distanceM)}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      subtitle: route.summary.isEmpty
          ? null
          : Text(context.l10n.via(route.summary)),
      onTap: () => ref.read(routePreviewProvider.notifier).selectRoute(index),
    );
  }

  Widget _avoidRow(
    BuildContext context,
    WidgetRef ref,
    RoutePreviewState state,
  ) {
    final notifier = ref.read(routePreviewProvider.notifier);
    return Row(
      children: [
        Expanded(
          child: CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            value: state.avoidTolls,
            onChanged: (_) => notifier.toggleTolls(),
            title: Text(context.l10n.avoidTolls),
          ),
        ),
        Expanded(
          child: CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            value: state.avoidHighways,
            onChanged: (_) => notifier.toggleHighways(),
            title: Text(context.l10n.avoidHighways),
          ),
        ),
      ],
    );
  }

  Widget _startButton(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 56,
      child: FilledButton.icon(
        icon: const Icon(Icons.play_arrow),
        label: Text(context.l10n.start),
        onPressed: () async {
          await ref.read(routePreviewProvider.notifier).begin();
        },
      ),
    );
  }

  Widget _stepListHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Row(
        children: [
          Icon(Icons.list, size: 18, color: context.scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            context.l10n.steps,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }

  List<Widget> _stepList(BuildContext context, RouteModel route) {
    return [
      for (final m in route.allManeuvers)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: ManeuverIcon(m.type, size: 28),
          title: Text(
            m.instructionText,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          subtitle: m.streetName.isEmpty ? null : Text(m.streetName),
          trailing: Text(UiFormat.distance(m.distanceToNextM)),
        ),
    ];
  }
}
