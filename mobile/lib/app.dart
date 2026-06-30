import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/l10n/app_localizations.dart';
import 'core/theme/app_theme.dart';
import 'models/app_settings.dart';
import 'providers/ble_providers.dart';
import 'providers/ui_providers.dart';
import 'ui/map_home/map_home_screen.dart';
import 'ui/widgets/location_permission_gate.dart';

/// Root app — map-first (§11.2). Theme Sáng/Tối/Tự động (§11.6).
class NavHudApp extends ConsumerWidget {
  const NavHudApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    // Khởi tạo BLE bridge sớm để auto-reconnect + lắng NavEvent ngay từ đầu.
    ref.watch(bleBridgeProvider);

    return MaterialApp(
      title: 'NavHUD',
      debugShowCheckedModeBanner: false,
      locale: settings.language.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _themeMode(settings.themeMode),
      home: const LocationPermissionGate(child: MapHomeScreen()),
    );
  }

  ThemeMode _themeMode(AppThemeMode m) => switch (m) {
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark => ThemeMode.dark,
    // "Tự động theo giờ mặt trời" — MVP map sang theo hệ thống;
    // S4 tự ép dark ban đêm dựa trên sunset/sunrise.
    AppThemeMode.auto => ThemeMode.system,
  };
}
