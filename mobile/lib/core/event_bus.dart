import 'dart:async';

import '../models/nav_event.dart';

/// Event bus phát [NavEvent] (§2.2). Navigation Engine publish; UI/BLE/TTS
/// subscribe độc lập — thêm subscriber không sửa engine.
class NavEventBus {
  final _controller = StreamController<NavEvent>.broadcast();

  Stream<NavEvent> get stream => _controller.stream;

  /// Lọc theo loại event tiện cho subscriber.
  Stream<T> on<T extends NavEvent>() => stream.where((e) => e is T).cast<T>();

  void emit(NavEvent event) {
    if (!_controller.isClosed) _controller.add(event);
  }

  void dispose() => _controller.close();
}
