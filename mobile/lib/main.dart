import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'providers/app_providers.dart';

void _initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'navhud_nav',
      channelName: 'NavHUD Dẫn đường',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
      allowWifiLock: false,
      allowWakeLock: true,
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // §3.4: app dẫn đường phải chạy offline. Production nên bundle .ttf vào
  // assets/fonts và đặt allowRuntimeFetching=false. Hiện chưa bundle nên để
  // true để google_fonts tải lần đầu (cần mạng lần chạy đầu).
  GoogleFonts.config.allowRuntimeFetching = true;

  _initForegroundTask();
  FlutterForegroundTask.initCommunicationPort();

  final prefs = await SharedPreferences.getInstance();

  runApp(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
      ],
      child: const NavHudApp(),
    ),
  );
}
