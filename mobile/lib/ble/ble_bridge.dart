// BLE Bridge — subscriber NavEvent, encode + Tx queue, deframe RX (§4.5, §5–6).
//
// Bridge KHÔNG biết plugin BLE nào: nó chỉ nói chuyện qua [IBleTransport].
// Navigation Engine phát [NavEvent] lên [NavEventBus]; bridge subscribe, dựng
// frame tương ứng và đẩy xuống thiết bị. UI và HUD cùng render từ một nguồn.
//
// ── KHUNG (frame) — §6.1 ────────────────────────────────────────────────
//   SOF(0xA5) | TYPE(u8) | LEN(u16 LE, 0..500) | PAYLOAD | CRC16(u16 LE)
//   CRC16/MCRF4XX tính trên TYPE + LEN16 + PAYLOAD. Mọi số multi-byte = LE.
//
// ── BẢNG MESSAGE chuẩn (§6.2) ───────────────────────────────────────────
//   0x01 HELLO          App→Dev  proto_ver u8
//   0x02 DEVICE_INFO    Dev→App  fw_ver u16, cap_bitmap u16, max_text u8
//   0x03 SYSTEM_INFO    2 chiều  static product/display info; cache once per pair
//   0x04 DEVICE_STATUS  2 chiều  battery/screen/pin/uptime/free heap snapshot
//   0x10 NAV_INSTRUCTION App→Dev seq u8, maneuver u8, distance_m u16,
//                                exit_number u8, name_len u8, street_name[]
//   0x11 DISTANCE_TICK  App→Dev  dist_to_man u16(m), dist_remain u32(m),
//                                eta u16(min), speed u8(km/h)
//   0x12 SPEED_LIMIT    App→Dev  limit u8, is_over u8
//   0x13 TRAFFIC_SIGN   App→Dev  sign_type u8, dist u16, value u8
//   0x14 NAV_STATE      App→Dev  state u8 (0 idle/1 nav/2 reroute/3 arrived)
//   0x20 ACK            Dev→App  acked_type u8, seq u8, frame_crc u16
//   0x21 BTN_EVENT      Dev→App  btn u8, action u8
//   0x7E HEARTBEAT      2 chiều  uptime u32
//
// ── MỞ RỘNG MAP DATA cho HUD đồ hoạ full-screen (TFT 240×320) — §6.2.1 ──
//   Mô hình v0.3: ESP32 vẽ map full-screen, TỰ chiếu toạ độ (dịch theo
//   live_pose − anchor, xoay −heading heading-up, scale theo zoom). App chỉ
//   gửi hình học ở hệ MÉT ĐỊA LÝ north-up quanh một điểm anchor tuyệt đối.
//   Đổi heading KHÔNG cần gửi lại route/roads — chỉ MAP_POSE đổi.
//
//   Reliability: mọi frame ACK-gated (stop-and-wait, retry tới khi ACK hoặc
//   kết nối bị ngắt).
//   ESP32 ACK mọi frame nhận được (MSG_ACK 0x20). Coalesce = dedup only (đè
//   frame cùng type chưa gửi). Frame > MTU−3 cắt qua _writeChunks — parser
//   byte-stream ráp lại. Write Request tuần tự hóa ATT; app-level ACK xác nhận
//   ESP32 đã nhận đủ frame và kiểm CRC thành công.
//
//   0x30 MAP_POSE  App→Dev  lat i32(deg×1e7), lng i32(deg×1e7),
//                           heading u16(0.1°, 0..3599), speed u8(km/h),
//                           flags u8 (bit0 gps_fix, bit1 off_route,
//                           bit2 navigating), view_span_dm u16 (mét quy
//                           đổi sang dm mà TOÀN CHIỀU RỘNG màn hình điện
//                           thoại đang hiển thị ở zoom dẫn đường hiện tại —
//                           ESP32 suy ra px_per_dm = SCR_W/view_span_dm để
//                           khớp đúng tỷ lệ zoom điện thoại)           [14B]
//   0x31 MAP_ROUTE App→Dev  header: anchor_lat i32, anchor_lng i32, seq u8,
//                           frag_idx u8, frag_total u8, n u16; rồi n×{east
//                           i16, north i16} (dm so với anchor, north-up).
//                           Fragment nhiều frame cùng seq khi vượt payload 1 BLE write.
//   0x32 MAP_ROADS App→Dev  header: anchor_lat i32, anchor_lng i32, seq u8,
//                           frag_idx u8, frag_total u8, road_count u8; rồi mỗi road: class u8
//                           (HighwayType.value), pt_count u8, pt_count×{east
//                           i16, north i16} (dm). Ưu tiên class nhỏ trước;
//                           bỏ road kém quan trọng / ngoài cửa sổ.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/event_bus.dart';
import '../core/map_debug.dart';
import '../models/ble_device.dart';
import '../models/geo_point.dart';
import '../models/nav_event.dart';
import '../models/nav_state.dart';
import '../models/road_segment.dart';
import 'crc16_mcrf4xx.dart';
import 'i_ble_transport.dart';

/// Snapshot dữ liệu cuối cùng đã gửi cho ESP32 — dùng để HUD sim mobile render
/// chính xác cùng hình học mà ESP32 đang hiển thị (post DP-simplify + clip).
class BleMapSnapshot {
  final GeoPoint user;
  final double headingDeg;
  final int speedKmh;
  final bool navigating;
  final bool offRoute;
  final bool gpsFix;

  /// Mét toàn-chiều-rộng màn hình phone → ESP32 dùng suy px_per_dm (MAP_POSE §0x30).
  final double viewSpanM;

  /// Anchor của bộ hình học route/roads (điểm gốc đã gửi qua MAP_ROUTE/MAP_ROADS).
  final GeoPoint? anchor;

  /// Tuyến sau Douglas–Peucker + clip cửa sổ 1.2 km — chính xác với ESP32.
  final List<GeoPoint> route;

  /// Đường xung quanh đã lọc (tham số roads truyền vào sendMapData).
  final List<RoadSegment> roads;

  const BleMapSnapshot({
    required this.user,
    required this.headingDeg,
    required this.speedKmh,
    required this.navigating,
    required this.offRoute,
    required this.gpsFix,
    required this.viewSpanM,
    this.anchor,
    this.route = const [],
    this.roads = const [],
  });

  BleMapSnapshot copyWith({
    GeoPoint? user,
    double? headingDeg,
    int? speedKmh,
    bool? navigating,
    bool? offRoute,
    bool? gpsFix,
    double? viewSpanM,
    GeoPoint? anchor,
    List<GeoPoint>? route,
    List<RoadSegment>? roads,
  }) => BleMapSnapshot(
    user: user ?? this.user,
    headingDeg: headingDeg ?? this.headingDeg,
    speedKmh: speedKmh ?? this.speedKmh,
    navigating: navigating ?? this.navigating,
    offRoute: offRoute ?? this.offRoute,
    gpsFix: gpsFix ?? this.gpsFix,
    viewSpanM: viewSpanM ?? this.viewSpanM,
    anchor: anchor ?? this.anchor,
    route: route ?? this.route,
    roads: roads ?? this.roads,
  );
}

// ── Mã message ─────────────────────────────────────────────────────────
const int _kSof = 0xA5;
const int _kMaxPayload = 500;
const int _kFrameOverhead = 6; // SOF + TYPE + LEN16 + CRC16
const int _kPreferredMtu = 247;
const int _kPreferredWriteMax = _kPreferredMtu - 3; // ATT header = 3 bytes
const int _kMaxSingleWritePayload = _kPreferredWriteMax - _kFrameOverhead;

const int _typeHello = 0x01;
const int _typeDeviceInfo = 0x02;
const int _typeSystemInfo = 0x03;
const int _typeDeviceStatus = 0x04;
const int _typeNavInstruction = 0x10;
const int _typeDistanceTick = 0x11;
const int _typeSpeedLimit = 0x12;
const int _typeTrafficSign = 0x13;
const int _typeNavState = 0x14;
const int _typeAck = 0x20;
const int _typeBtnEvent = 0x21;
const int _typeHeartbeat = 0x7E;

// MAP_* — mở rộng HUD đồ hoạ full-screen (§6.2.1, v0.3).
const int _typeMapPose = 0x30;
const int _typeMapRoute = 0x31;
const int _typeMapRoads = 0x32;
const int _typeMapClock = 0x33;

// Cửa sổ clip ~1.2 km quanh anchor (bán kính) — chỉ phần HUD nhìn thấy.
const double _kMapWindowM = 600.0;

// Lead-in giữ lại trước vị trí hiện tại khi trim route đã đi (mượt khi vẽ).
const double _kRouteLeadInM = 50.0;

// Khớp MAP_MAX_ROADS phía firmware (map_model.h) — road vượt ngưỡng này bị
// firmware âm thầm bỏ theo thứ tự đến, nên phải tự cắt + ưu tiên ở mobile.
const int _kMapMaxRoads = 128;

// Firmware H2 dùng point-pool phẳng: nhiều road ngắn dùng chung ngân sách thay vì
// mỗi road chiếm cứng 30 điểm. 1536 điểm + metadata vẫn xấp xỉ RAM bản 64×30 cũ.
const int _kMapMaxRoadPoints = 1536;

// Số điểm tối đa mỗi road gửi xuống — khớp MAP_MAX_ROAD_PTS firmware. Gửi
// nhiều hơn chỉ lãng phí băng thông vì firmware sẽ bỏ phần thừa.
const int _kMapMaxRoadPts = 16;

// Payload tối đa mỗi MAP_ROADS frame để full frame vừa một ATT write MTU 247.
const int _kMapRoadsMaxPayload = _kMaxSingleWritePayload;

// Epsilon Douglas–Peucker (mét) — đơn giản hoá hình học route.
const double _kSimplifyEpsM = 2.5;
const int _kMapMaxRoutePts = 200; // khớp ESP32-H2 MAP_MAX_ROUTE_PTS

const int _protoVer = 1;
const int _systemInfoSchema = 1;
const int _deviceStatusSchema = 1;
const List<int> _kReconnectBackoffSec = [3, 6, 12, 24, 30];

// Stop-and-wait ACK. Không giới hạn số lần retry khi link vẫn còn connected:
// write thành công chỉ xác nhận GATT, ACK mới xác nhận ESP32 đã parse đủ frame.
const Duration _kAckTimeout = Duration(seconds: 1);
const Duration _kRetryDelayMin = Duration(milliseconds: 100);
const Duration _kRetryDelayMax = Duration(seconds: 2);

/// Sự kiện nút bấm vật lý trên HUD (BTN_EVENT 0x21) → app xử lý (mute/repeat…).
class ButtonEvent {
  /// Tên dễ đọc (vd "mute", "repeat", "zoom_in") — dùng cho log/UI.
  final String name;

  /// Mã raw `action` nhận từ thiết bị (để debug console hex).
  final int value;

  const ButtonEvent(this.name, this.value);
}

abstract interface class BleSystemInfoStore {
  DeviceSystemInfo? read(String deviceId);
  Future<void> write(String deviceId, DeviceSystemInfo info);
  Future<void> remove(String deviceId);
}

/// Cầu nối BLE: encode NavEvent → frame, deframe RX, quản trạng thái/reconnect.
class BleBridge {
  final IBleTransport _transport;
  final NavEventBus _bus;
  final BleSystemInfoStore? systemInfoStore;

  // ── Cấu hình runtime (đồng bộ từ settings qua provider) ──────────────
  /// Gửi tên đường đầy đủ; false → rút gọn/để trống cho màn nhỏ (§11.8).
  bool sendFullContent = true;

  /// Ép bỏ dấu tiếng Việt trước khi UTF-8 encode (hoặc khi device báo no-diacritics).
  bool forceStripDiacritics = false;

  /// Tự reconnect (backoff 1/2/4/8 s) khi rớt kết nối (§5.3).
  bool autoReconnect = true;

  // ── Trạng thái ───────────────────────────────────────────────────────
  BleStatus _status = const BleStatus();
  final _statusCtrl = StreamController<BleStatus>.broadcast();
  final _btnCtrl = StreamController<ButtonEvent>.broadcast();

  StreamSubscription<NavEvent>? _busSub;
  StreamSubscription<Uint8List>? _incomingSub;
  StreamSubscription<BleConnectionState>? _connSub;

  // ── Tx queue — dedup + ACK-gated drain (§5.3) ────────────────────────
  final List<_TxItem> _queue = [];
  bool _sending = false;

  // ── Timer ────────────────────────────────────────────────────────────
  Timer? _heartbeat;
  Timer? _clockSync;
  Timer? _statusPoll;
  Timer? _reconnect;
  int _reconnectAttempt = 0;
  bool _disposed = false;
  bool _intentionalDisconnect = false;
  bool _connectInFlight = false;
  DateTime? _connectedAt;

  // ── ACK-gated send state ─────────────────────────────────────────────
  Completer<void>? _ackCompleter;
  int _ackExpectedType = 0;
  int _ackExpectedCrc = 0;

  // ── Snapshot để resend sau reconnect (§5.3) ──────────────────────────
  int _instructionSeq = 0;
  Uint8List? _lastInstructionFrame;
  Uint8List? _lastDistanceTickFrame;
  Uint8List? _lastSpeedLimitFrame;
  Uint8List? _lastNavStateFrame;
  Uint8List? _lastMapPoseFrame;

  // ── Dedup mũi tên rẽ — chỉ gửi NAV_INSTRUCTION khi thực sự đổi ──────
  int _lastSentManeuverWire = -1;
  int _lastSentExitNumber = -1;
  String _lastSentManeuverStreet = '';

  // ── BLE map snapshot — dữ liệu cuối gửi cho ESP32 (cho HUD sim mobile) ──
  BleMapSnapshot? _mapSnapshot;
  final _mapCtrl = StreamController<BleMapSnapshot>.broadcast();

  // Pose gần nhất gửi qua sendMapPosition → nguồn anchor cho sendMapData.
  GeoPoint? _lastPose;

  // seq tăng dần mỗi lần gửi bộ ROUTE / ROADS mới (ESP32 giữ bộ mới nhất).
  int _routeSeq = 0;
  int _roadsSeq = 0;

  // Cờ điều hướng suy ra từ NavEvent gần nhất → đóng vào MAP_POSE.flags.
  bool _navigating = false;
  bool _offRoute = false;

  BleBridge(this._transport, this._bus, {this.systemInfoStore}) {
    _busSub = _bus.stream.listen(_onNavEvent);
  }

  // ── API công khai ────────────────────────────────────────────────────

  BleStatus get currentStatus => _status;
  Stream<BleStatus> get status => _statusCtrl.stream;
  Stream<ButtonEvent> get buttonEvents => _btnCtrl.stream;

  /// Snapshot dữ liệu map cuối cùng đã gửi cho ESP32 (null nếu chưa gửi lần nào).
  BleMapSnapshot? get currentMapSnapshot => _mapSnapshot;

  /// Stream phát mỗi khi MAP_POSE hoặc MAP_ROUTE/ROADS được gửi.
  Stream<BleMapSnapshot> get mapSnapshots => _mapCtrl.stream;

  Future<void> connectTo(DiscoveredDevice device) async {
    if (_disposed) return;
    if (_connectInFlight) {
      debugPrint('[BleBridge] connect ignored: another attempt is in flight');
      return;
    }
    _connectInFlight = true;

    try {
      _intentionalDisconnect = false;
      _cancelReconnect();
      final cachedSystemInfo = systemInfoStore?.read(device.id);
      _setStatus(
        BleStatus(
          state: BleConnectionState.connecting,
          device: device,
          systemInfo: cachedSystemInfo,
          reconnectInSeconds: 0,
        ),
      );

      try {
        _listenIncoming();
        _listenConnState();
        await _transport.connect(device.id);
      } catch (e, st) {
        debugPrint('[BleBridge] connect FAILED: $e\n$st');
        try {
          await _transport.disconnect();
        } catch (_) {}
        _onConnectionLost();
        return;
      }

      if (_intentionalDisconnect || _disposed) {
        await _transport.disconnect();
        return;
      }

      _connectedAt = DateTime.now();
      _setStatus(
        _status.copyWith(
          state: BleConnectionState.connected,
          mtu: _transport.mtu,
        ),
      );

      // Ưu tiên kết nối HIGH khi đang dùng (§5.2).
      unawaited(_transport.setHighPriority(true));

      // Handshake: gửi HELLO, chờ DEVICE_INFO (dispatch sẽ cập nhật status.info).
      _enqueue(_typeHello, [_protoVer], withResponse: true, coalesce: false);
      if (cachedSystemInfo == null) {
        _requestSystemInfo();
      }
      _requestDeviceStatus();

      _startHeartbeat();
      _startClockSync();
      _startStatusPoll();
      unawaited(_refreshRssi());

      // Nối lại → bắn full snapshot để HUD đồng bộ ngay (§5.3).
      _resendSnapshot();
    } finally {
      _connectInFlight = false;
    }
  }

  void disconnect() {
    _intentionalDisconnect = true;
    _connectedAt = null;
    _cancelReconnect();
    _stopHeartbeat();
    _stopClockSync();
    _stopStatusPoll();
    _queue.clear();
    unawaited(_transport.disconnect());
    _setStatus(
      _status.copyWith(
        state: BleConnectionState.disconnected,
        reconnectInSeconds: 0,
      ),
    );
  }

  void forget() {
    final deviceId = _status.device?.id;
    disconnect();
    if (deviceId != null) {
      unawaited(systemInfoStore?.remove(deviceId));
    }
    _lastInstructionFrame = null;
    _lastDistanceTickFrame = null;
    _lastSpeedLimitFrame = null;
    _lastNavStateFrame = null;
    _lastMapPoseFrame = null;
    _mapSnapshot = null;
    _lastPose = null;
    _routeSeq = 0;
    _roadsSeq = 0;
    _navigating = false;
    _offRoute = false;
    _instructionSeq = 0;
    _resetManeuverDedup();
    _status = const BleStatus(); // về unpaired, xoá device/info.
    _setStatus(_status);
  }

  void _resetManeuverDedup() {
    _lastSentManeuverWire = -1;
    _lastSentExitNumber = -1;
    _lastSentManeuverStreet = '';
  }

  /// Gửi NAV_INSTRUCTION mẫu cho nút [Gửi thử] ở S5 (§11.7).
  void sendTestInstruction() {
    final frame = _encodeNavInstruction(
      maneuverWire: 3, // turnLeft
      distanceM: 100,
      exitNumber: 0,
      streetName: 'Rẽ trái',
    );
    _lastInstructionFrame = frame;
    _enqueueFrame(frame, _typeNavInstruction, withResponse: true);
  }

  /// MAP_POSE (0x30) — vị trí + heading + cờ, gói thường xuyên (coalesced).
  /// Cũng nhớ pose làm nguồn anchor cho lần sendMapData kế tiếp.
  ///
  /// [viewSpanM]: mét hiển thị trên TOÀN CHIỀU RỘNG màn hình điện thoại ở
  /// zoom dẫn đường hiện tại (vd ~200 m) — ESP32 dùng để đặt scale của nó
  /// sao cho toàn màn hình HUD cũng hiển thị đúng số mét đó, tương đương
  /// tỷ lệ zoom trên điện thoại.
  void sendMapPosition({
    required double lat,
    required double lng,
    required double bearing,
    required int speedKmh,
    required double viewSpanM,
  }) {
    if (!_supportsGraphicalMap) return;
    _lastPose = GeoPoint(lat, lng);
    final flags = _poseFlags();
    final b = BytesBuilder();
    _putI32(b, (lat * 1e7).round()); // lat i32 deg×1e7
    _putI32(b, (lng * 1e7).round()); // lng i32 deg×1e7
    // heading u16: độ → deci-độ (0.1°), 0..3599.
    final headingDeci = (bearing * 10).round() % 3600;
    _putU16(b, (headingDeci + 3600) % 3600);
    b.addByte(speedKmh.clamp(0, 255)); // speed u8 (km/h)
    b.addByte(flags); // flags u8
    _putU16(b, (viewSpanM * 10).round().clamp(1, 65535)); // view_span_dm
    final poseFrame = _frame(_typeMapPose, b.toBytes());
    _lastMapPoseFrame = poseFrame;
    _enqueueFrame(poseFrame, _typeMapPose, coalesce: true);

    // Emit snapshot cho HUD sim mobile.
    final prev = _mapSnapshot;
    _mapSnapshot = prev == null
        ? BleMapSnapshot(
            user: GeoPoint(lat, lng),
            headingDeg: bearing,
            speedKmh: speedKmh,
            navigating: _navigating,
            offRoute: _offRoute,
            gpsFix: (flags & 0x01) != 0,
            viewSpanM: viewSpanM,
          )
        : prev.copyWith(
            user: GeoPoint(lat, lng),
            headingDeg: bearing,
            speedKmh: speedKmh,
            navigating: _navigating,
            offRoute: _offRoute,
            gpsFix: (flags & 0x01) != 0,
            viewSpanM: viewSpanM,
          );
    if (prev == null) {
      debugPrint(
        '[BleBridge] MAP_POSE first send: ${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)} heading=${bearing.round()} viewSpan=${viewSpanM.round()}m',
      );
    }
    if (!_mapCtrl.isClosed) _mapCtrl.add(_mapSnapshot!);
  }

  /// flags MAP_POSE: bit0 gps_fix (mặc định 1), bit1 off_route, bit2 navigating.
  int _poseFlags() {
    var f = 0x01; // gps_fix = 1 (chưa có nguồn tốt hơn).
    if (_offRoute) f |= 0x02;
    if (_navigating) f |= 0x04;
    return f;
  }

  /// MAP_ROUTE (0x31) + MAP_ROADS (0x32) — gửi hiếm theo ngưỡng resend.
  ///
  /// anchor = pose gần nhất (fallback: điểm đầu route). Trước khi encode:
  /// (1) bỏ phần route đã đi theo [routeProgressM] (giữ từ vị trí hiện tại +
  /// lead-in), (2) simplify Douglas–Peucker, (3) clip cửa sổ ~1.2 km quanh
  /// anchor. Tăng seq riêng cho ROUTE và ROADS.
  Future<void> sendMapData({
    required List<GeoPoint> routeGeometry,
    required List<RoadSegment> roads,
    required double routeProgressM,
    bool includeRoute = true,
    bool includeRoads = true,
  }) async {
    if (!_supportsGraphicalMap) return;
    final prev = _mapSnapshot;
    final shouldSendRoute = includeRoute || prev == null;
    final previousAnchor = prev?.anchor;
    // Roads-only phải dùng đúng anchor của route gần nhất. Nếu lấy _lastPose mới
    // hơn vài mét, firmware đổi anchor nhưng route vẫn ở hệ cũ và biến khỏi màn.
    final anchor = !shouldSendRoute && previousAnchor != null
        ? previousAnchor
        : (_lastPose ??
              (routeGeometry.isNotEmpty ? routeGeometry.first : null));
    if (anchor == null) {
      debugPrint(
        '[BleBridge] sendMapData: anchor=null (lastPose=$_lastPose, routeLen=${routeGeometry.length}) → abort',
      );
      return;
    }

    // (1) Bỏ phần đã đi, (2) clip cửa sổ quanh anchor, (3) simplify.
    // Thứ tự clip-trước-DP quan trọng: DP trên geometry dài có thể xoá hết
    // điểm gần user (đường thẳng dài), rồi clip trả rỗng → route đơ.
    // Clip trước đảm bảo luôn giữ điểm gần user; DP chỉ giản lược vùng hiển thị.
    final trimmed = shouldSendRoute
        ? _trimTravelled(routeGeometry, routeProgressM)
        : const <GeoPoint>[];
    final clipped = shouldSendRoute
        ? _clipToWindow(trimmed, anchor)
        : const <GeoPoint>[];
    var simplified = shouldSendRoute
        ? _douglasPeucker(clipped, _kSimplifyEpsM)
        : prev.route;

    // routeProgress có thể chậm hơn route geometry mới sau reroute. Khi đó phép trim
    // hợp lệ về số học nhưng chọn một đoạn ở xa anchor và clip thành rỗng. Cửa sổ
    // trượt theo vị trí thật là lớp cứu hộ: tìm đoạn gần xe rồi lấy lead-in + phần trước.
    if (shouldSendRoute && routeGeometry.length >= 2 && simplified.length < 2) {
      final spatialWindow = _routeWindowNearAnchor(routeGeometry, anchor);
      simplified = _douglasPeucker(spatialWindow, _kSimplifyEpsM);
      MapDebug.log(
        'ROUTE_WINDOW',
        'progress window empty; spatial=${spatialWindow.length} '
            'dp=${simplified.length}',
      );
    }

    // Không bao giờ thay một route đang hiển thị bằng route rỗng do GPS/progress tạm
    // lệch. Route chỉ được clear khi navigation kết thúc qua NAV_STATE.
    if (shouldSendRoute &&
        simplified.length < 2 &&
        (prev?.route.length ?? 0) >= 2) {
      simplified = prev!.route;
      MapDebug.log(
        'ROUTE_WINDOW',
        'kept previous route=${simplified.length}pts',
      );
    }
    if (simplified.length > _kMapMaxRoutePts) {
      simplified = _limitRoadPoints(simplified, _kMapMaxRoutePts);
      MapDebug.log('ROUTE_WINDOW', 'budgeted route=${simplified.length}pts');
    }

    debugPrint(
      '[BleBridge] sendMapData: anchor=${anchor.lat.toStringAsFixed(5)},${anchor.lng.toStringAsFixed(5)}'
      ' route: ${shouldSendRoute ? "raw=${routeGeometry.length}→trimmed=${trimmed.length}→clip=${clipped.length}→dp=${simplified.length}" : "keep=${simplified.length}"}'
      ' roads_in=${roads.length}',
    );

    // Giữ roads cũ khi Overpass lỗi mạng (lỗi tạm thời bên ngoài) — re-encode
    // với anchor mới vẫn đúng vì GeoPoint là tọa độ tuyệt đối.
    // Route KHÔNG fallback: clipped rỗng nghĩa là route ngoài cửa sổ 1200m —
    // đây là trạng thái hợp lệ, không phải lỗi; gửi rỗng để ESP32 không vẽ.
    final effectiveRoads = roads.isNotEmpty ? roads : (prev?.roads ?? const []);

    if (roads.isEmpty && (prev?.roads.isNotEmpty ?? false)) {
      debugPrint(
        '[BleBridge] sendMapData: roads empty (Overpass failure?) — keeping ${effectiveRoads.length} previous roads',
      );
    }

    // withResponse: true — một fragment rớt là hỏng cả lần reassembly trên
    // ESP32 (route/roads không bao giờ hiện); Write-No-Response không đảm
    // bảo gửi tới khi burst nhiều frame liên tiếp như khi fragment route dài.
    List<Uint8List> routeFrames = const [];
    if (shouldSendRoute) {
      // Ưu tiên batch map mới nhất; không để road frames của anchor cũ nằm trước
      // route mới trong queue và làm hình học tạm thời lệch/mất khỏi màn hình.
      final queuedBefore = _queue.length;
      _queue.removeWhere(
        (item) => item.type == _typeMapRoute || item.type == _typeMapRoads,
      );
      MapDebug.log(
        'QUEUE',
        'route-priority dropped=${queuedBefore - _queue.length} '
            'remaining=${_queue.length}',
      );
      _routeSeq = (_routeSeq + 1) & 0xFF;
      routeFrames = _encodeMapRoute(simplified, anchor, _routeSeq);
      debugPrint(
        '[BleBridge] MAP_ROUTE seq=$_routeSeq → ${routeFrames.length} frames (${simplified.length} pts)',
      );
      for (final frame in routeFrames) {
        _enqueueFrame(
          frame,
          _typeMapRoute,
          withResponse: true,
          coalesce: false,
        );
      }
    }

    final roadBatch = includeRoads
        ? _encodeMapRoads(effectiveRoads, anchor, (_roadsSeq + 1) & 0xFF)
        : null;

    // Preview dùng đúng subset sau cửa sổ + point budget mà firmware sẽ nhận.
    // Nhờ vậy "preview có nhưng ESP thiếu" không còn bị che bởi 400 road nguồn.
    if (prev != null) {
      _mapSnapshot = prev.copyWith(
        anchor: anchor,
        route: simplified,
        roads: roadBatch?.roads ?? prev.roads,
      );
      if (!_mapCtrl.isClosed) _mapCtrl.add(_mapSnapshot!);
    } else {
      debugPrint(
        '[BleBridge] sendMapData: _mapSnapshot=null, snapshot NOT updated (no MAP_POSE sent yet?)',
      );
    }

    // Cho phép gửi route ngay trong khi nguồn road nền (MapLibre/Overpass) còn
    // đang tải. Firmware swap MAP_ROUTE độc lập nên HUD có thể vẽ tuyến và mũi
    // tên tức thì; roads cũ vẫn được giữ cho tới lần cập nhật đầy đủ kế tiếp.
    if (!includeRoads) {
      debugPrint('[BleBridge] MAP_ROADS deferred');
      return;
    }

    // Roads-only thay thế batch roads cũ chưa gửi, nhưng không xoá MAP_ROUTE mới
    // đang chờ phía trước queue.
    final queuedBefore = _queue.length;
    _queue.removeWhere((item) => item.type == _typeMapRoads);
    MapDebug.log(
      'QUEUE',
      'roads-replace dropped=${queuedBefore - _queue.length} '
          'remaining=${_queue.length}',
    );
    _roadsSeq = (_roadsSeq + 1) & 0xFF;
    final roadsFrames = roadBatch!.frames;
    debugPrint(
      '[BleBridge] MAP_ROADS seq=$_roadsSeq → ${roadsFrames.length} frames',
    );
    for (final frame in roadsFrames) {
      _enqueueFrame(frame, _typeMapRoads, withResponse: true, coalesce: false);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _intentionalDisconnect = true;
    _busSub?.cancel();
    _incomingSub?.cancel();
    _connSub?.cancel();
    _stopHeartbeat();
    _stopClockSync();
    _stopStatusPoll();
    _cancelReconnect();
    _statusCtrl.close();
    _btnCtrl.close();
    _mapCtrl.close();
    _transport.dispose();
  }

  // ── Subscribe NavEvent → encode frame ────────────────────────────────

  void _onNavEvent(NavEvent e) {
    switch (e) {
      case InstructionChanged():
        _instructionSeq = e.seq & 0xFF;
        final m = e.maneuver;
        final mWire = m.type.wire;
        final exitNum = m.exitNumber ?? 0;
        final frame = _encodeNavInstruction(
          maneuverWire: mWire,
          distanceM: m.distanceToNextM.round(),
          exitNumber: exitNum,
          streetName: m.streetName,
        );
        // Luôn cập nhật snapshot để resend đúng sau reconnect.
        _lastInstructionFrame = frame;
        // Chỉ gửi khi mũi tên / tên đường thực sự đổi; distance_to_man
        // thay đổi liên tục nhưng đã có DISTANCE_TICK riêng — không cần resend.
        final sameArrow =
            mWire == _lastSentManeuverWire &&
            exitNum == _lastSentExitNumber &&
            m.streetName == _lastSentManeuverStreet;
        if (!sameArrow) {
          _lastSentManeuverWire = mWire;
          _lastSentExitNumber = exitNum;
          _lastSentManeuverStreet = m.streetName;
          _enqueueFrame(frame, _typeNavInstruction, withResponse: true);
        }

      case DistanceTick():
        final b = BytesBuilder();
        _putU16(b, e.distanceToManeuverM.round());
        _putU32(b, e.distanceRemainingM.round());
        _putU16(b, (e.etaSeconds / 60).round()); // giây → phút
        b.addByte(e.speedKmh.round().clamp(0, 255));
        final frame = _frame(_typeDistanceTick, b.toBytes());
        _lastDistanceTickFrame = frame;
        // Periodic → write no-response, coalesce (gói mới đè gói cũ chưa gửi).
        _enqueueFrame(frame, _typeDistanceTick, coalesce: true);

      case SpeedLimitChanged():
        final frame = _frame(_typeSpeedLimit, [
          e.limitKmh.clamp(0, 255),
          e.isOver ? 1 : 0,
        ]);
        _lastSpeedLimitFrame = frame;
        _enqueueFrame(frame, _typeSpeedLimit, coalesce: true);

      case SignApproaching():
        final b = BytesBuilder();
        b.addByte(e.sign.type.wire);
        _putU16(b, e.distanceM.round());
        b.addByte(e.sign.value.clamp(0, 255));
        _enqueue(_typeTrafficSign, b.toBytes());

      case PhaseChanged():
        // Cập nhật cờ điều hướng cho MAP_POSE.flags.
        _navigating =
            e.phase == NavPhase.navigating || e.phase == NavPhase.rerouting;
        _offRoute = e.phase == NavPhase.rerouting;
        // Thoát nav → reset dedup mũi tên để lần nav kế tiếp gửi ngay.
        if (!_navigating) _resetManeuverDedup();
        final frame = _frame(_typeNavState, [_navStateWire(e.phase.wire)]);
        _lastNavStateFrame = frame;
        // NAV_STATE quan trọng → withResponse.
        _enqueueFrame(frame, _typeNavState, withResponse: true);

      case Rerouting():
        _navigating = true;
        _offRoute = true;
        final frame = _frame(_typeNavState, [2]);
        _lastNavStateFrame = frame;
        _enqueueFrame(frame, _typeNavState, withResponse: true);

      case Arrived():
        _navigating = false;
        _offRoute = false;
        _resetManeuverDedup();
        final frame = _frame(_typeNavState, [3]);
        _lastNavStateFrame = frame;
        _enqueueFrame(frame, _typeNavState, withResponse: true);

      case VoicePrompt():
        // TTS xử lý ở subscriber khác — bridge bỏ qua.
        break;
    }
  }

  /// Map NavPhase.wire (idle0/routing1/navigating2/rerouting3/arrived4) → wire
  /// NAV_STATE của firmware (0 idle/1 navigating/2 rerouting/3 arrived).
  int _navStateWire(int phaseWire) {
    switch (phaseWire) {
      case 0: // idle
      case 1: // routing → coi như idle phía HUD
        return 0;
      case 2: // navigating
        return 1;
      case 3: // rerouting
        return 2;
      case 4: // arrived
        return 3;
      default:
        return 0;
    }
  }

  // ── Encode NAV_INSTRUCTION (§6.3) ────────────────────────────────────

  Uint8List _encodeNavInstruction({
    required int maneuverWire,
    required int distanceM,
    required int exitNumber,
    required String streetName,
  }) {
    final nameBytes = _encodeStreetName(streetName);
    final b = BytesBuilder();
    b.addByte(_instructionSeq & 0xFF);
    b.addByte(maneuverWire & 0xFF);
    _putU16(b, distanceM.clamp(0, 0xFFFF));
    b.addByte(exitNumber.clamp(0, 255));
    b.addByte(nameBytes.length);
    b.add(nameBytes);
    return _frame(_typeNavInstruction, b.toBytes());
  }

  /// Chuẩn bị street_name: tôn trọng sendFullContent, strip dấu, cắt theo maxText.
  Uint8List _encodeStreetName(String name) {
    if (!sendFullContent) return Uint8List(0);

    var text = name.trim();
    final info = _status.info;
    final needStrip =
        forceStripDiacritics || (info != null && !info.supportsDiacritics);
    if (needStrip) text = _stripDiacritics(text);

    var maxText = info?.maxText ?? DeviceInfo.defaultMaxText;
    final systemInfo = _status.systemInfo;
    if (systemInfo != null) {
      if (!systemInfo.supportsScreen) {
        maxText = 0;
      } else if (systemInfo.screenType == HudScreenType.mono) {
        maxText = math.min(maxText, 16);
      } else if (systemInfo.screenWidth > 0) {
        maxText = math.min(maxText, math.max(8, systemInfo.screenWidth ~/ 6));
      }
    }
    var bytes = utf8.encode(text);
    if (bytes.length > maxText) {
      // Cắt UTF-8 an toàn (không cắt giữa 1 ký tự nhiều byte).
      var end = maxText;
      while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
        end--;
      }
      bytes = bytes.sublist(0, end);
    }
    return Uint8List.fromList(bytes);
  }

  String _stripDiacritics(String s) {
    final buf = StringBuffer();
    for (final ch in s.split('')) {
      final lower = ch.toLowerCase();
      final folded = _vietnameseAscii[lower];
      if (folded == null) {
        buf.write(ch); // ASCII / ký tự khác → giữ nguyên.
      } else {
        // Giữ hoa/thường: nếu ký tự gốc là chữ hoa thì viết hoa kết quả.
        buf.write(ch == lower ? folded : folded.toUpperCase());
      }
    }
    return buf.toString();
  }

  bool get _supportsGraphicalMap {
    final info = _status.systemInfo;
    if (info == null) return true;
    return HudDisplayConfig.fromSystemInfo(info).supportsGraphicalMap;
  }

  // ── MAP_* — chiếu equirectangular north-up (§6.2.1, v0.3) ─────────────

  /// Chiếu điểm [p] sang offset mét (east, north) quanh [anchor]
  /// (equirectangular, north-up — KHÔNG xoay theo heading; ESP32 tự xoay).
  ///   east  = (lng−anchor_lng)·cos(anchor_lat)·111320
  ///   north = (lat−anchor_lat)·111320
  ({double east, double north}) _toMeters(GeoPoint p, GeoPoint anchor) {
    const mPerDeg = 111320.0;
    final cosLat = math.cos(anchor.lat * math.pi / 180);
    final east = (p.lng - anchor.lng) * cosLat * mPerDeg;
    final north = (p.lat - anchor.lat) * mPerDeg;
    return (east: east, north: north);
  }

  /// mét → decimet i16 (clamp an toàn vào ±32767).
  int _toDm(double meters) {
    final dm = (meters * 10).round();
    return dm.clamp(-32768, 32767);
  }

  /// Bỏ phần route đã đi: giữ từ vị trí hiện tại ([progressM]) trở đi, lùi lại
  /// một đoạn lead-in nhỏ để vẽ mượt. Tích luỹ độ dài dọc geometry.
  List<GeoPoint> _trimTravelled(List<GeoPoint> geometry, double progressM) {
    if (geometry.length < 2) return geometry;
    final startAt = math.max(0.0, progressM - _kRouteLeadInM);
    if (startAt <= 0) return geometry;

    var acc = 0.0;
    var cutIdx = 0;
    for (var i = 1; i < geometry.length; i++) {
      final seg = geometry[i - 1].distanceTo(geometry[i]);
      if (acc + seg >= startAt) {
        cutIdx = i - 1; // giữ điểm ngay trước ngưỡng để không hụt đầu.
        break;
      }
      acc += seg;
      cutIdx = i;
    }
    if (cutIdx <= 0) return geometry;
    if (cutIdx >= geometry.length - 1) {
      // Đã đi gần hết → giữ 2 điểm cuối để vẫn có đoạn vẽ.
      return geometry.sublist(geometry.length - 2);
    }
    return geometry.sublist(cutIdx);
  }

  /// Clip về cửa sổ ~1.2 km quanh [anchor]: chỉ giữ điểm trong bán kính (cộng
  /// 1 điểm kề ở mỗi biên để đường không bị "cụt" ngay tại mép màn).
  List<GeoPoint> _clipToWindow(List<GeoPoint> geometry, GeoPoint anchor) {
    if (geometry.isEmpty) return geometry;
    final inside = [
      for (final p in geometry) anchor.distanceTo(p) <= _kMapWindowM,
    ];
    final out = <GeoPoint>[];
    for (var i = 0; i < geometry.length; i++) {
      final keep =
          inside[i] ||
          (i > 0 && inside[i - 1]) ||
          (i < geometry.length - 1 && inside[i + 1]);
      if (keep) out.add(geometry[i]);
    }
    return out;
  }

  /// Cửa sổ trượt không phụ thuộc routeProgress: chọn đỉnh gần vị trí xe nhất,
  /// giữ một đoạn ngắn phía sau và đủ xa phía trước để route luôn phủ viewport.
  List<GeoPoint> _routeWindowNearAnchor(
    List<GeoPoint> geometry,
    GeoPoint anchor,
  ) {
    if (geometry.length < 2) return geometry;

    var nearest = 0;
    var nearestDistance = double.infinity;
    for (var i = 0; i < geometry.length; i++) {
      final distance = anchor.distanceTo(geometry[i]);
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = i;
      }
    }

    var start = nearest;
    var walked = 0.0;
    while (start > 0 && walked < _kRouteLeadInM) {
      walked += geometry[start].distanceTo(geometry[start - 1]);
      start--;
    }

    var end = nearest;
    walked = 0.0;
    while (end < geometry.length - 1 && walked < _kMapWindowM * 1.25) {
      walked += geometry[end].distanceTo(geometry[end + 1]);
      end++;
    }

    if (end == start) {
      if (end < geometry.length - 1) {
        end++;
      } else if (start > 0) {
        start--;
      }
    }
    return geometry.sublist(start, end + 1);
  }

  /// Douglas–Peucker đơn giản hoá polyline; [epsM] tính bằng MÉT (xấp xỉ qua
  /// chiếu phẳng quanh điểm đầu — đủ chính xác cho cửa sổ HUD vài km).
  List<GeoPoint> _douglasPeucker(List<GeoPoint> pts, double epsM) {
    if (pts.length <= 2) return pts;
    final anchor = pts.first;
    final xy = [for (final p in pts) _toMeters(p, anchor)];

    final keep = List<bool>.filled(pts.length, false);
    keep[0] = true;
    keep[pts.length - 1] = true;
    _dpRecurse(xy, 0, pts.length - 1, epsM, keep);

    final out = <GeoPoint>[];
    for (var i = 0; i < pts.length; i++) {
      if (keep[i]) out.add(pts[i]);
    }
    return out;
  }

  void _dpRecurse(
    List<({double east, double north})> xy,
    int lo,
    int hi,
    double epsM,
    List<bool> keep,
  ) {
    if (hi <= lo + 1) return;
    final ax = xy[lo].east, ay = xy[lo].north;
    final bx = xy[hi].east, by = xy[hi].north;
    final dx = bx - ax, dy = by - ay;
    final segLen2 = dx * dx + dy * dy;

    var maxDist = -1.0;
    var maxIdx = lo;
    for (var i = lo + 1; i < hi; i++) {
      final px = xy[i].east, py = xy[i].north;
      double dist;
      if (segLen2 == 0) {
        final ex = px - ax, ey = py - ay;
        dist = math.sqrt(ex * ex + ey * ey);
      } else {
        // Khoảng cách vuông góc tới đoạn AB.
        final cross = (px - ax) * dy - (py - ay) * dx;
        dist = cross.abs() / math.sqrt(segLen2);
      }
      if (dist > maxDist) {
        maxDist = dist;
        maxIdx = i;
      }
    }
    if (maxDist > epsM) {
      keep[maxIdx] = true;
      _dpRecurse(xy, lo, maxIdx, epsM, keep);
      _dpRecurse(xy, maxIdx, hi, epsM, keep);
    }
  }

  /// MAP_ROUTE (0x31) → fragment nhiều frame cùng [seq] khi vượt payload 1 write.
  /// Mỗi frame: header (anchor_lat i32, anchor_lng i32, seq u8, frag_idx u8,
  /// frag_total u8, n u16 = 13 byte) + n×{east i16, north i16}.
  List<Uint8List> _encodeMapRoute(
    List<GeoPoint> geometry,
    GeoPoint anchor,
    int seq,
  ) {
    final pts = <({int e, int n})>[];
    for (final p in geometry) {
      final m = _toMeters(p, anchor);
      pts.add((e: _toDm(m.east), n: _toDm(m.north)));
    }

    const headerLen = 4 + 4 + 1 + 1 + 1 + 2; // 13 byte
    final maxPtsPerFrame = (_kMaxSingleWritePayload - headerLen) ~/ 4;

    // Chia điểm thành các mảnh; tối thiểu 1 mảnh (kể cả khi rỗng).
    final chunks = <List<({int e, int n})>>[];
    if (pts.isEmpty) {
      chunks.add(const []);
    } else {
      for (var i = 0; i < pts.length; i += maxPtsPerFrame) {
        chunks.add(pts.sublist(i, math.min(i + maxPtsPerFrame, pts.length)));
      }
    }

    final fragTotal = chunks.length;
    final frames = <Uint8List>[];
    for (var idx = 0; idx < fragTotal; idx++) {
      final chunk = chunks[idx];
      final b = BytesBuilder();
      _putI32(b, (anchor.lat * 1e7).round());
      _putI32(b, (anchor.lng * 1e7).round());
      b.addByte(seq & 0xFF);
      b.addByte(idx & 0xFF);
      b.addByte(fragTotal & 0xFF);
      _putU16(b, chunk.length);
      for (final p in chunk) {
        _putI16(b, p.e);
        _putI16(b, p.n);
      }
      frames.add(_frame(_typeMapRoute, b.toBytes()));
    }
    return frames;
  }

  /// MAP_ROADS (0x32) → fragment theo [seq] nếu cần. Mỗi frame: header
  /// (anchor_lat i32, anchor_lng i32, seq u8, frag_idx u8, frag_total u8,
  /// road_count u8 = 12 byte) + mỗi
  /// road: class u8, pt_count u8, pt_count×{east i16, north i16}.
  /// Ưu tiên road GẦN tuyến đường chính (khả năng giao cắt cao) trước, road
  /// xa route bị cắt khi vượt [_kMapMaxRoads] — firmware chỉ giữ tối đa
  /// MAP_MAX_ROADS theo thứ tự đến nên road lân cận giao cắt (thường là
  /// đường nhỏ) không được xếp đầu sẽ bị rớt nếu chỉ sort theo class.
  ({List<Uint8List> frames, List<RoadSegment> roads}) _encodeMapRoads(
    List<RoadSegment> roads,
    GeoPoint anchor,
    int seq,
  ) {
    // Lấy đoạn thực sự cắt cửa sổ trước khi giới hạn điểm. Cách cũ lấy 16/30 điểm
    // ĐẦU của polyline dài nên thường bỏ nhầm đoạn đang nằm ngay cạnh xe.
    final encoded =
        <
          ({HighwayType type, int cls, double dist, List<({int e, int n})> pts})
        >[];
    for (final road in roads) {
      final window = _roadWindowPoints(road.points, anchor);
      if (window.length < 2) continue;
      final limited = _limitRoadPoints(window, _kMapMaxRoadPts);
      final pts = <({int e, int n})>[];
      var minDist = double.infinity;
      for (final p in limited) {
        minDist = math.min(minDist, anchor.distanceTo(p));
        final m = _toMeters(p, anchor);
        pts.add((e: _toDm(m.east), n: _toDm(m.north)));
      }
      encoded.add((
        type: road.type,
        cls: road.type.value & 0xFF,
        dist: minDist,
        pts: pts,
      ));
    }
    final skippedOutside = roads.length - encoded.length;

    // Ưu tiên road GẦN ANCHOR (user) trước — đảm bảo ngõ hẻm ngay bên cạnh
    // luôn được chọn thay vì bị đẩy ra ngoài budget bởi đường xa phía trước.
    // Cùng cự ly: đường lớn (class nhỏ) trước.
    encoded.sort((a, b) {
      final byDist = a.dist.compareTo(b.dist);
      if (byDist != 0) return byDist;
      return a.cls.compareTo(b.cls);
    });
    final budgeted =
        <
          ({HighwayType type, int cls, double dist, List<({int e, int n})> pts})
        >[];
    var pointBudget = 0;
    for (final road in encoded) {
      if (budgeted.length >= _kMapMaxRoads) break;
      final remaining = _kMapMaxRoadPoints - pointBudget;
      if (remaining < 2) break;
      final pts = road.pts.length <= remaining
          ? road.pts
          : _sampleWirePoints(road.pts, remaining);
      if (pts.length < 2) continue;
      budgeted.add((type: road.type, cls: road.cls, dist: road.dist, pts: pts));
      pointBudget += pts.length;
    }
    debugPrint(
      '[MapRoads] _encodeMapRoads: in=${roads.length} outside=$skippedOutside valid=${encoded.length} budgeted=${budgeted.length}/$_kMapMaxRoads'
      ' points=$pointBudget/$_kMapMaxRoadPoints'
      ' (window=${_kMapWindowM.round()}m, maxPts=$_kMapMaxRoadPts)',
    );

    const headerLen = 4 + 4 + 1 + 1 + 1 + 1; // 12 byte
    final maxBody = _kMapRoadsMaxPayload - headerLen;

    // Gom road vào frame; mỗi road = 2 + pts*4 byte. Road không vừa 1 frame
    // (hiếm) thì cắt bớt điểm.
    final chunks = <({Uint8List body, int count})>[];
    var body = BytesBuilder();
    var count = 0;

    void flush() {
      if (count == 0) return;
      chunks.add((body: body.toBytes(), count: count));
      body = BytesBuilder();
      count = 0;
    }

    for (final road in budgeted) {
      var pts = road.pts;
      var roadBytes = 2 + pts.length * 4;
      // Road quá lớn cho 1 frame trống → cắt bớt điểm cho vừa.
      if (roadBytes > maxBody) {
        final maxPts = (maxBody - 2) ~/ 4;
        if (maxPts < 2) continue;
        pts = pts.sublist(0, maxPts);
        roadBytes = 2 + pts.length * 4;
      }
      // Không đủ chỗ trong frame hiện tại → flush sang frame mới.
      if (body.length + roadBytes > maxBody) flush();
      body.addByte(road.cls);
      body.addByte(pts.length);
      for (final p in pts) {
        _putI16(body, p.e);
        _putI16(body, p.n);
      }
      count++;
    }
    flush();
    if (chunks.isEmpty) {
      chunks.add((body: Uint8List(0), count: 0));
    }

    final frames = <Uint8List>[];
    for (var i = 0; i < chunks.length; i++) {
      final b = BytesBuilder();
      _putI32(b, (anchor.lat * 1e7).round());
      _putI32(b, (anchor.lng * 1e7).round());
      b.addByte(seq & 0xFF);
      b.addByte(i & 0xFF);
      b.addByte(chunks.length & 0xFF);
      b.addByte(chunks[i].count & 0xFF);
      b.add(chunks[i].body);
      frames.add(_frame(_typeMapRoads, b.toBytes()));
    }

    final previewRoads = [
      for (final road in budgeted)
        RoadSegment(
          type: road.type,
          points: [for (final p in road.pts) _fromDm(p.e, p.n, anchor)],
        ),
    ];
    return (frames: frames, roads: previewRoads);
  }

  List<GeoPoint> _roadWindowPoints(List<GeoPoint> points, GeoPoint anchor) {
    if (points.length < 2) return const [];
    var first = -1;
    var last = -1;
    for (var i = 0; i < points.length; i++) {
      if (anchor.distanceTo(points[i]) <= _kMapWindowM) {
        if (first < 0) first = i;
        last = i;
      }
    }
    if (first >= 0) {
      return points.sublist(
        math.max(0, first - 1),
        math.min(points.length, last + 2),
      );
    }

    // Hai đỉnh đều ngoài nhưng đoạn thẳng vẫn có thể cắt viewport.
    var nearestSegment = -1;
    var nearestDistance = double.infinity;
    for (var i = 1; i < points.length; i++) {
      final a = _toMeters(points[i - 1], anchor);
      final b = _toMeters(points[i], anchor);
      final dx = b.east - a.east;
      final dy = b.north - a.north;
      final len2 = dx * dx + dy * dy;
      final t = len2 == 0
          ? 0.0
          : (-(a.east * dx + a.north * dy) / len2).clamp(0.0, 1.0);
      final x = a.east + dx * t;
      final y = a.north + dy * t;
      final distance = math.sqrt(x * x + y * y);
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearestSegment = i;
      }
    }
    if (nearestSegment < 0 || nearestDistance > _kMapWindowM) return const [];
    return [points[nearestSegment - 1], points[nearestSegment]];
  }

  List<GeoPoint> _limitRoadPoints(List<GeoPoint> points, int maxPoints) {
    if (points.length <= maxPoints) return points;
    var epsilon = 1.0;
    var simplified = points;
    while (simplified.length > maxPoints && epsilon <= 64) {
      simplified = _douglasPeucker(points, epsilon);
      epsilon *= 1.6;
    }
    if (simplified.length <= maxPoints) return simplified;
    return [
      for (var i = 0; i < maxPoints; i++)
        points[(i * (points.length - 1) / (maxPoints - 1)).round()],
    ];
  }

  List<({int e, int n})> _sampleWirePoints(
    List<({int e, int n})> points,
    int maxPoints,
  ) {
    if (points.length <= maxPoints) return points;
    return [
      for (var i = 0; i < maxPoints; i++)
        points[(i * (points.length - 1) / (maxPoints - 1)).round()],
    ];
  }

  GeoPoint _fromDm(int eastDm, int northDm, GeoPoint anchor) {
    const mPerDeg = 111320.0;
    final cosLat = math.cos(anchor.lat * math.pi / 180);
    return GeoPoint(
      anchor.lat + (northDm / 10) / mPerDeg,
      anchor.lng + (eastDm / 10) / (mPerDeg * cosLat),
    );
  }

  // ── Frame codec (pure, unit-testable) ────────────────────────────────

  /// Dựng 1 frame hoàn chỉnh: SOF | TYPE | LEN16 | PAYLOAD | CRC16(LE).
  /// CRC tính trên TYPE + LEN16 + PAYLOAD. Payload bị cắt nếu > 500.
  Uint8List _frame(int type, List<int> payload) {
    final len = math.min(payload.length, _kMaxPayload);
    final out = Uint8List(_kFrameOverhead + len);
    out[0] = _kSof;
    out[1] = type & 0xFF;
    out[2] = len & 0xFF;
    out[3] = (len >> 8) & 0xFF;
    for (var i = 0; i < len; i++) {
      out[4 + i] = payload[i] & 0xFF;
    }
    // CRC trên TYPE+LEN16+PAYLOAD = bytes [1 .. 4+len).
    final crc = crc16Mcrf4xx(out, 1, 4 + len);
    out[4 + len] = crc & 0xFF;
    out[4 + len + 1] = (crc >> 8) & 0xFF;
    return out;
  }

  // ── Tx queue + coalescing ────────────────────────────────────────────

  void _enqueue(
    int type,
    List<int> payload, {
    bool withResponse = true,
    bool coalesce = false,
  }) {
    _enqueueFrame(
      _frame(type, payload),
      type,
      withResponse: withResponse,
      coalesce: coalesce,
    );
  }

  void _enqueueFrame(
    Uint8List frame,
    int type, {
    bool withResponse = true,
    bool coalesce = false,
  }) {
    if (_status.state != BleConnectionState.connected) return;
    if (coalesce) {
      // Gói mới đè gói cùng TYPE chưa gửi (chỉ giữ bản mới nhất).
      _queue.removeWhere((it) => it.coalesce && it.type == type);
    }
    _queue.add(_TxItem(frame, type, withResponse, coalesce));
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_sending) return;
    _sending = true;
    try {
      while (_queue.isNotEmpty &&
          _status.state == BleConnectionState.connected) {
        final item = _queue.removeAt(0);
        final maxWriteLen = _maxWriteLen;

        // Stop-and-wait: gửi frame, đợi MSG_ACK, retry cho tới khi ACK hoặc
        // connectionState báo mất kết nối. Tuyệt đối không drop một frame chỉ
        // vì hết một số retry cố định.
        var acked = false;
        var attempt = 0;
        while (!acked && _status.state == BleConnectionState.connected) {
          if (_status.state != BleConnectionState.connected) break;

          final completer = Completer<void>();
          _ackCompleter = completer;
          _ackExpectedType = item.type;
          _ackExpectedCrc = _frameCrc(item.frame);

          try {
            if (item.frame.length > maxWriteLen) {
              await _writeChunks(item.frame, maxWriteLen: maxWriteLen);
            } else {
              // GATT Write Request tuần tự hóa cả frame nhỏ; app-level ACK bên
              // dưới vẫn cần để biết ESP32 đã deframe + kiểm CRC thành công.
              await _transport.write(
                item.frame,
                withResponse: item.withResponse,
              );
            }
          } catch (e) {
            if (identical(_ackCompleter, completer)) {
              _ackCompleter = null;
            }
            debugPrint(
              '[BleBridge] write failed type=0x${item.type.toRadixString(16)} '
              'attempt=${attempt + 1}: $e; retry…',
            );
            attempt++;
            await _waitBeforeRetry(attempt);
            continue;
          }

          bool ok;
          try {
            await completer.future.timeout(_kAckTimeout);
            ok = true;
          } catch (_) {
            ok = false;
          }
          if (identical(_ackCompleter, completer)) _ackCompleter = null;

          if (ok) {
            if (item.type == _typeMapRoute || item.type == _typeMapRoads) {
              final seq = item.frame.length > 12 ? item.frame[12] : -1;
              MapDebug.log(
                'ACK',
                'type=0x${item.type.toRadixString(16)} seq=$seq '
                    'attempt=${attempt + 1} crc=0x${_ackExpectedCrc.toRadixString(16)} '
                    'queue=${_queue.length}',
              );
            }
            acked = true;
            break;
          }
          attempt++;
          debugPrint(
            '[BleBridge] ACK timeout type=0x${item.type.toRadixString(16)} '
            'attempt=$attempt, retry…',
          );
          await _waitBeforeRetry(attempt);
        }

        if (!acked) {
          debugPrint(
            '[BleBridge] send interrupted by disconnect'
            ' type=0x${item.type.toRadixString(16)}',
          );
          // At-least-once qua reconnect: ACK có thể đã mất dù ESP32 đã nhận,
          // vì vậy giữ lại frame hiện tại và gửi lại sau khi link phục hồi.
          // Handler phía firmware phải chấp nhận bản sao (map dùng seq; các
          // state message chỉ ghi đè state hiện tại).
          if (!_intentionalDisconnect && !_disposed) {
            _queue.insert(0, item);
          }
          break;
        }
      }
    } finally {
      _ackCompleter = null;
      _sending = false;
    }
  }

  // ── RX deframer (byte-stream state machine) — §6.1 ───────────────────

  // Dù peer từng báo MTU lớn hơn, không vượt 244 byte. 244 data + 3 ATT +
  // 4 L2CAP = 251 byte, vừa một HCI ACL packet của ESP32 và tránh reassembly.
  int get _maxWriteLen =>
      math.max(20, math.min(_transport.mtu - 3, _kPreferredWriteMax));

  Future<void> _waitBeforeRetry(int attempt) async {
    final shift = math.min(attempt - 1, 4);
    final delayMs = math.min(
      _kRetryDelayMin.inMilliseconds * (1 << shift),
      _kRetryDelayMax.inMilliseconds,
    );
    await Future<void>.delayed(Duration(milliseconds: delayMs));
  }

  Future<void> _writeChunks(Uint8List data, {required int maxWriteLen}) async {
    for (var offset = 0; offset < data.length; offset += maxWriteLen) {
      final end = math.min(offset + maxWriteLen, data.length);
      // withResponse: true để BLE layer ACK từng chunk trước khi gửi tiếp — tránh
      // flood HCI queue khi frame lớn hơn MTU-3 và phải split thành nhiều ATT write.
      await _transport.write(
        Uint8List.sublistView(data, offset, end),
        withResponse: true,
      );
    }
  }

  final _Deframer _deframer = _Deframer();

  void _listenIncoming() {
    _incomingSub?.cancel();
    _incomingSub = _transport.incoming.listen((bytes) {
      _deframer.feed(bytes, _onFrame);
    });
  }

  void _listenConnState() {
    _connSub?.cancel();
    _connSub = _transport.connectionState.listen((s) {
      if (s == BleConnectionState.disconnected &&
          _status.state == BleConnectionState.connected) {
        _onConnectionLost();
      }
    });
  }

  void _onFrame(int type, Uint8List payload) {
    switch (type) {
      case _typeDeviceInfo:
        _handleDeviceInfo(payload);
      case _typeSystemInfo:
        _handleSystemInfo(payload);
      case _typeDeviceStatus:
        _handleDeviceStatus(payload);
      case _typeAck:
        if (payload.length >= 2) {
          final ackedType = payload[0];
          // Firmware mới echo CRC frame để ACK trễ của frame trước không thể
          // xác nhận nhầm frame kế tiếp cùng TYPE. Vẫn nhận ACK 2-byte từ
          // firmware cũ để tương thích khi nâng cấp từng phía.
          final crcMatches =
              payload.length < 4 || _readU16(payload, 2) == _ackExpectedCrc;
          final c = _ackCompleter;
          if (c != null &&
              !c.isCompleted &&
              ackedType == _ackExpectedType &&
              crcMatches) {
            _ackCompleter = null;
            c.complete();
          }
        }
      case _typeBtnEvent:
        if (payload.length >= 2) {
          final btn = payload[0];
          final action = payload[1];
          _btnCtrl.add(ButtonEvent(_buttonName(btn, action), action));
        }
      case _typeHeartbeat:
        // 2 chiều — nhận heartbeat thiết bị, không cần phản hồi thêm.
        break;
      default:
        break;
    }
  }

  void _handleDeviceInfo(Uint8List p) {
    if (p.length < 5) return;
    final fwVer = p[0] | (p[1] << 8);
    final capBitmap = p[2] | (p[3] << 8);
    final maxText = p[4];
    final info = DeviceInfo(
      firmwareVersion: fwVer,
      capBitmap: capBitmap,
      maxText: maxText == 0 ? DeviceInfo.defaultMaxText : maxText,
    );
    _setStatus(_status.copyWith(info: info));
  }

  void _handleSystemInfo(Uint8List p) {
    const fixedLength = 28;
    if (p.length < fixedLength || p[0] != _systemInfoSchema) return;

    final dateLength = p[25];
    final serialLength = p[26];
    final mcuLength = p[27];
    final expectedLength = fixedLength + dateLength + serialLength + mcuLength;
    if (p.length < expectedLength) return;

    var offset = fixedLength;
    String readText(int length) {
      final value = utf8.decode(
        Uint8List.sublistView(p, offset, offset + length),
        allowMalformed: true,
      );
      offset += length;
      return value;
    }

    final info = DeviceSystemInfo(
      vendorId: _readU32(p, 1),
      modelId: _readU32(p, 5),
      productId: _readU32(p, 9),
      hardwareVersion: _readU32(p, 13),
      supportsBattery: p[17] != 0,
      supportsScreen: p[18] != 0,
      screenType: HudScreenType.fromWire(p[19]),
      screenWidth: _readU16(p, 21),
      screenHeight: _readU16(p, 23),
      manufacturerDate: readText(dateLength),
      serialNumber: readText(serialLength),
      mcuDescription: readText(mcuLength),
    );

    _setStatus(_status.copyWith(systemInfo: info));
    final deviceId = _status.device?.id;
    if (deviceId != null) {
      unawaited(systemInfoStore?.write(deviceId, info));
    }
  }

  void _handleDeviceStatus(Uint8List p) {
    if (p.length < 20 || p[0] != _deviceStatusSchema) return;

    final batteryRaw = p[3];
    final supplyRaw = _readU16(p, 4);
    final temperatureRaw = _readI16(p, 6);
    final status = DeviceStatus(
      flags: _readU16(p, 1),
      batteryPercent: batteryRaw == 0xFF ? null : batteryRaw.clamp(0, 100),
      supplyMillivolts: supplyRaw == 0 ? null : supplyRaw,
      temperatureCelsius: temperatureRaw == -0x8000
          ? null
          : temperatureRaw / 10.0,
      pinState: _readU32(p, 8),
      uptime: Duration(seconds: _readU32(p, 12)),
      freeHeapBytes: _readU32(p, 16),
      receivedAt: DateTime.now(),
    );
    _setStatus(_status.copyWith(deviceStatus: status));
  }

  String _buttonName(int btn, int action) {
    // Map đơn giản btn → tên dễ đọc (firmware có thể định nghĩa khác).
    switch (btn) {
      case 0:
        return 'mute';
      case 1:
        return 'repeat';
      case 2:
        return 'zoom_in';
      case 3:
        return 'zoom_out';
      case 4:
        return 'next';
      default:
        return 'btn_$btn';
    }
  }

  // ── Heartbeat (§5.3) ─────────────────────────────────────────────────

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
      final b = BytesBuilder();
      _putU32(b, DateTime.now().millisecondsSinceEpoch ~/ 1000);
      _enqueue(_typeHeartbeat, b.toBytes(), coalesce: true);
    });
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  void _startStatusPoll() {
    _stopStatusPoll();
    _statusPoll = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _requestDeviceStatus(),
    );
  }

  void _stopStatusPoll() {
    _statusPoll?.cancel();
    _statusPoll = null;
  }

  void _requestSystemInfo() {
    _enqueue(_typeSystemInfo, const [], coalesce: true);
  }

  void _requestDeviceStatus() {
    _enqueue(_typeDeviceStatus, const [], coalesce: true);
  }

  // ── Clock sync (MAP_CLOCK 0x33) ──────────────────────────────────────
  // Đồng hồ thực tế trên HUD (khác eta — đó là thời lượng còn lại, không
  // phải giờ hiện tại); gửi hiếm (30s) vì ESP32 tự tick giữa các lần sync.

  void _startClockSync() {
    _stopClockSync();
    _sendClock();
    _clockSync = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _sendClock(),
    );
  }

  void _stopClockSync() {
    _clockSync?.cancel();
    _clockSync = null;
  }

  void _sendClock() {
    final now = DateTime.now();
    final b = BytesBuilder();
    _putU32(b, now.toUtc().millisecondsSinceEpoch ~/ 1000);
    _putI16(b, now.timeZoneOffset.inMinutes);
    _enqueue(_typeMapClock, b.toBytes(), coalesce: true);
  }

  // ── Reconnect backoff 1/2/4/8 s (§5.3) ───────────────────────────────

  void _onConnectionLost() {
    final connectedFor = _connectedAt == null
        ? null
        : DateTime.now().difference(_connectedAt!);
    if (connectedFor != null && connectedFor >= const Duration(seconds: 5)) {
      _reconnectAttempt = 0;
    }
    debugPrint(
      '[BleBridge] _onConnectionLost — intentional=$_intentionalDisconnect '
      'autoReconnect=$autoReconnect connectedFor=${connectedFor?.inMilliseconds}ms',
    );
    _connectedAt = null;
    _stopHeartbeat();
    _stopClockSync();
    _stopStatusPoll();
    // Giữ queue và frame đang chờ ACK để _drain gửi lại sau reconnect.
    // disconnect() chủ động vẫn clear queue như trước.
    // Giải phóng bất kỳ ACK đang chờ để _drain không bị treo.
    final pendingAck = _ackCompleter;
    if (pendingAck != null && !pendingAck.isCompleted) {
      pendingAck.completeError(Exception('disconnected'));
    }
    _ackCompleter = null;
    _setStatus(_status.copyWith(state: BleConnectionState.disconnected));
    if (_intentionalDisconnect || !autoReconnect || _status.device == null) {
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _cancelReconnect();
    final delaySec =
        _kReconnectBackoffSec[math.min(
          _reconnectAttempt,
          _kReconnectBackoffSec.length - 1,
        )];
    _reconnectAttempt++;
    _setStatus(_status.copyWith(reconnectInSeconds: delaySec));
    debugPrint('[BleBridge] reconnect scheduled in ${delaySec}s');
    _reconnect = Timer(Duration(seconds: delaySec), () {
      final device = _status.device;
      if (device == null || _intentionalDisconnect || !autoReconnect) return;
      unawaited(
        connectTo(device).then((_) {
          if (_status.state == BleConnectionState.connected) {
            _reconnectAttempt = 0;
          }
        }),
      );
    });
  }

  void _cancelReconnect() {
    _reconnect?.cancel();
    _reconnect = null;
  }

  /// Bắn full state snapshot sau khi nối lại (§5.3).
  void _resendSnapshot() {
    if (_lastNavStateFrame != null) {
      _enqueueFrame(_lastNavStateFrame!, _typeNavState, withResponse: true);
    }
    if (_lastInstructionFrame != null) {
      _enqueueFrame(
        _lastInstructionFrame!,
        _typeNavInstruction,
        withResponse: true,
      );
    }
    if (_lastDistanceTickFrame != null) {
      _enqueueFrame(_lastDistanceTickFrame!, _typeDistanceTick);
    }
    if (_lastSpeedLimitFrame != null) {
      _enqueueFrame(_lastSpeedLimitFrame!, _typeSpeedLimit);
    }
    if (_lastMapPoseFrame != null) {
      _enqueueFrame(
        _lastMapPoseFrame!,
        _typeMapPose,
        withResponse: true,
        coalesce: true,
      );
    }
    final map = _mapSnapshot;
    if (map != null && map.route.length >= 2) {
      // Reconnect có thể xảy ra khi xe đứng yên nên không thể chờ GPS tick kế tiếp.
      // Phát lại snapshot geometry ngay sau pose để HUD tự phục hồi đầy đủ.
      unawaited(
        sendMapData(
          routeGeometry: map.route,
          roads: map.roads,
          routeProgressM: 0,
        ),
      );
    }
  }

  // ── Helper ───────────────────────────────────────────────────────────

  Future<void> _refreshRssi() async {
    final rssi = await _transport.readRssi();
    if (rssi != null) _setStatus(_status.copyWith(rssi: rssi));
  }

  void _setStatus(BleStatus s) {
    _status = s;
    if (!_statusCtrl.isClosed) _statusCtrl.add(s);
  }

  static void _putU16(BytesBuilder b, int v) {
    b.addByte(v & 0xFF);
    b.addByte((v >> 8) & 0xFF);
  }

  static void _putU32(BytesBuilder b, int v) {
    b.addByte(v & 0xFF);
    b.addByte((v >> 8) & 0xFF);
    b.addByte((v >> 16) & 0xFF);
    b.addByte((v >> 24) & 0xFF);
  }

  static void _putI16(BytesBuilder b, int v) {
    final u = v & 0xFFFF;
    b.addByte(u & 0xFF);
    b.addByte((u >> 8) & 0xFF);
  }

  static void _putI32(BytesBuilder b, int v) {
    final u = v & 0xFFFFFFFF;
    b.addByte(u & 0xFF);
    b.addByte((u >> 8) & 0xFF);
    b.addByte((u >> 16) & 0xFF);
    b.addByte((u >> 24) & 0xFF);
  }

  static int _readU16(Uint8List data, int offset) =>
      data[offset] | (data[offset + 1] << 8);

  static int _frameCrc(Uint8List frame) =>
      frame[frame.length - 2] | (frame[frame.length - 1] << 8);

  static int _readI16(Uint8List data, int offset) {
    final value = _readU16(data, offset);
    return value & 0x8000 == 0 ? value : value - 0x10000;
  }

  static int _readU32(Uint8List data, int offset) =>
      data[offset] |
      (data[offset + 1] << 8) |
      (data[offset + 2] << 16) |
      (data[offset + 3] << 24);
}

/// Một item trong Tx queue.
class _TxItem {
  final Uint8List frame;
  final int type;
  final bool withResponse;
  final bool coalesce;

  _TxItem(this.frame, this.type, this.withResponse, this.coalesce);
}

/// State machine deframe: SOF → TYPE → LEN → PAYLOAD → CRC (§6.1).
/// Chịu được fragment qua nhiều notify; CRC sai → bỏ frame, resync.
class _Deframer {
  static const int _sof = _kSof;

  int _state = 0; // 0 wait SOF, 1 type, 2 len-lo, 3 len-hi, 4 payload, 5/6 crc
  int _type = 0;
  int _len = 0;
  final List<int> _payload = [];
  int _crcLo = 0;

  void feed(
    List<int> bytes,
    void Function(int type, Uint8List payload) onFrame,
  ) {
    for (final raw in bytes) {
      final byte = raw & 0xFF;
      switch (_state) {
        case 0:
          if (byte == _sof) _state = 1;
        case 1:
          _type = byte;
          _state = 2;
        case 2:
          _len = byte;
          _state = 3;
        case 3:
          _len |= byte << 8;
          _payload.clear();
          if (_len > _kMaxPayload) {
            _reset(); // LEN bất hợp lệ → bỏ.
          } else {
            _state = _len == 0 ? 5 : 4;
          }
        case 4:
          _payload.add(byte);
          if (_payload.length >= _len) _state = 5;
        case 5:
          _crcLo = byte;
          _state = 6;
        case 6:
          final crcRx = _crcLo | (byte << 8);
          final calc = _computeCrc();
          if (crcRx == calc) {
            onFrame(_type, Uint8List.fromList(_payload));
          }
          _reset();
      }
    }
  }

  int _computeCrc() {
    final buf = <int>[_type, _len & 0xFF, (_len >> 8) & 0xFF, ..._payload];
    return crc16Mcrf4xx(buf);
  }

  void _reset() {
    _state = 0;
    _type = 0;
    _len = 0;
    _crcLo = 0;
    _payload.clear();
  }
}

/// Bảng bỏ dấu tiếng Việt (giống `geocoding_service.dart`), dùng để strip
/// street_name khi thiết bị không hỗ trợ dấu / người dùng ép bỏ dấu.
const Map<String, String> _vietnameseAscii = {
  'à': 'a',
  'á': 'a',
  'ạ': 'a',
  'ả': 'a',
  'ã': 'a',
  'â': 'a',
  'ầ': 'a',
  'ấ': 'a',
  'ậ': 'a',
  'ẩ': 'a',
  'ẫ': 'a',
  'ă': 'a',
  'ằ': 'a',
  'ắ': 'a',
  'ặ': 'a',
  'ẳ': 'a',
  'ẵ': 'a',
  'è': 'e',
  'é': 'e',
  'ẹ': 'e',
  'ẻ': 'e',
  'ẽ': 'e',
  'ê': 'e',
  'ề': 'e',
  'ế': 'e',
  'ệ': 'e',
  'ể': 'e',
  'ễ': 'e',
  'ì': 'i',
  'í': 'i',
  'ị': 'i',
  'ỉ': 'i',
  'ĩ': 'i',
  'ò': 'o',
  'ó': 'o',
  'ọ': 'o',
  'ỏ': 'o',
  'õ': 'o',
  'ô': 'o',
  'ồ': 'o',
  'ố': 'o',
  'ộ': 'o',
  'ổ': 'o',
  'ỗ': 'o',
  'ơ': 'o',
  'ờ': 'o',
  'ớ': 'o',
  'ợ': 'o',
  'ở': 'o',
  'ỡ': 'o',
  'ù': 'u',
  'ú': 'u',
  'ụ': 'u',
  'ủ': 'u',
  'ũ': 'u',
  'ư': 'u',
  'ừ': 'u',
  'ứ': 'u',
  'ự': 'u',
  'ử': 'u',
  'ữ': 'u',
  'ỳ': 'y',
  'ý': 'y',
  'ỵ': 'y',
  'ỷ': 'y',
  'ỹ': 'y',
  'đ': 'd',
};
