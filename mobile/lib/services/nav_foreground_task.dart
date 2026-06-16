import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Entry-point called in the background isolate by flutter_foreground_task.
/// Must be a top-level function annotated with @pragma('vm:entry-point').
@pragma('vm:entry-point')
void startNavForegroundTask() {
  FlutterForegroundTask.setTaskHandler(_NavTaskHandler());
}

class _NavTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'btn_stop') {
      FlutterForegroundTask.sendDataToMain('stop_nav');
    }
  }
}
