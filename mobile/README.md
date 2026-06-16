# NavHUD — Ứng dụng chỉ đường + BLE companion (NUS)

App Flutter dẫn đường turn-by-turn, đẩy thông tin dẫn đường xuống HUD nhúng
(ESP32/nRF52) qua Nordic UART Service. Triển khai theo
`thiet-ke-ung-dung-chi-duong-ble-nus.md`.

## Kiến trúc (layered, interface-driven — §2.2)

```
lib/
├─ models/            # Kiểu dùng chung (single source of truth)
│   ├─ geo_point, gps_fix, travel_profile
│   ├─ maneuver_type  # enum CHIA SẺ với firmware (nav_proto.h §6.3)
│   ├─ route_model, nav_state (NavSnapshot), nav_event (event bus)
│   ├─ traffic_sign, place, ble_device, app_settings, route_preview_state
├─ core/
│   ├─ constants.dart # endpoint + API key (đọc qua --dart-define)
│   ├─ event_bus.dart # NavEventBus — engine publish, UI/BLE/TTS subscribe
│   ├─ l10n/          # localization thủ công vi/en
│   └─ theme/         # design system §11.1 (Be Vietnam Pro + Inter)
├─ ble/               # NUS codec + transport + bridge (§5–6)
│   ├─ crc16_mcrf4xx, nus_constants, nus_codec (frame + parser state machine)
│   ├─ i_ble_transport + flutter_blue_transport
│   └─ ble_bridge.dart  # subscriber NavEvent, Tx queue coalescing, reconnect
├─ routing/           # IRouteService + ValhallaRouteService + polyline6
├─ search/            # IGeocodingService + GeocodingService (Goong/Nominatim)
├─ traffic/           # ISignService + OverpassSignService (§4.4)
├─ navigation/        # NavController (state machine §4.3), map_matcher,
│                     # location_service, nav_voice (TTS theo ngôn ngữ app)
├─ providers/         # Riverpod wiring (contract giữa các lớp)
└─ ui/                # S1–S6 (§11) — map-first, bottom sheets, banner TBT
```

**Nguyên tắc:** Navigation Engine không biết BLE — chỉ phát `NavEvent`. BLE
Bridge / UI / TTS là subscriber độc lập. Codec là pure functions, unit-test
được, dùng chung spec với firmware.

## Cấu hình (API keys / endpoint)

Truyền khi chạy qua `--dart-define` (xem `lib/core/constants.dart`):

```bash
flutter run \
  --dart-define=VALHALLA_URL=https://your-valhalla-host \
  --dart-define=GOONG_API_KEY=xxxxxxxx \
  --dart-define=NOMINATIM_COUNTRY_CODES=vn \
  --dart-define=NOMINATIM_ACCEPT_LANGUAGE=vi,en \
  --dart-define=NOMINATIM_USER_AGENT=NavHUD/0.1 \
  --dart-define=MAP_STYLE_URL=https://your-style.json \
  --dart-define=MAP_STYLE_DARK_URL=https://your-style-dark.json
```

- Không có `GOONG_API_KEY` → geocoding tự fallback sang Nominatim (OSM).
- `NOMINATIM_COUNTRY_CODES` mặc định là `vn`; đặt rỗng nếu muốn tìm cả ngoài Việt Nam.
- Mặc định `MAP_STYLE_URL` dùng demotiles của MapLibre (chỉ để chạy thử).
- Ngôn ngữ giao diện chọn trong Settings: Tiếng Việt / English.

## Build

Toolchain (§3.1): Flutter 3.44.0 · Dart 3.12.0 · JDK 21 · compileSdk/targetSdk
36 · minSdk 26 · AGP 9.x · Gradle 9.1 · Kotlin 2.3.x.

```bash
flutter pub get
flutter test          # codec / polyline / crc16
flutter run
```

## NUS Protocol

Protocol nam tren NUS RX/TX va duoc xu ly trong `nus_protocol.c`. Parser la
streaming parser, nen co the nhan frame bi chia nho theo BLE write hoac nhieu
frame trong cung mot lan RX.

Frame:

```text
SOF(0xAC) | CMD(1) | TYPE(1) | LEN(2 LE) | PAYLOAD | CRC16/MCRF4XX(2 LE)
```

CRC tinh tren tat ca byte tu `SOF` den het `PAYLOAD`, khong tinh 2 byte CRC.
Gioi han frame hien tai la `NUS_MAX_DATA_LEN` byte, payload toi da la
`NUS_PROTOCOL_MAX_PAYLOAD_LEN` byte.

### Type

| Type | Value |
| ---- | ----- |
| `REQUEST` | `0x00` |
| `RESPONSE` | `0x01` |
| `EVENT` | `0x02` |
| `COMMAND` | `0x03` |
| `ACK` | `0x04` |

ACK payload co 1 byte status:

| Status | Value |
| ------ | ----- |
| `OK` | `0x00` |
| `INVALID_FRAME` | `0x01` |
| `INVALID_TYPE` | `0x02` |
| `INVALID_PAYLOAD` | `0x03` |
| `UNSUPPORTED_CMD` | `0x04` |
| `APP_ERROR` | `0x05` |
| `TX_FAILED` | `0x06` |

### Commands

| CMD | Type từ mobile | Payload | Reply |
| --- | -------------- | ------- | ----- |
| `NAV_INSTRUCTION_TEXT (0x01)` | `EVENT` | xem bên dưới | `ACK` |
| `NAV_INSTRUCTION_IMAGE (0x02)` | `EVENT` | xem bên dưới | `ACK` |
| `TRAFFIC_SIGN (0x03)` | `EVENT` | `u8 sign_type` · `u16 data_len` · `u8[] data` (string) | `ACK` |
| `DEVICE_INFO (0x04)` | `REQUEST` | rỗng | `RESPONSE` xem bên dưới |
| `CURRENT_TIME (0x05)` | `EVENT` | `u32 epoch_seconds` little-endian | `ACK` |
| `FILE_TRANSFER (0x06)` | `COMMAND` | `u32 file_size` · `u32 offset` · `u16 data_len` · `u8[] data` | `ACK` |
| `OTA (0x07)` | `REQUEST`/`EVENT`/`COMMAND` | raw, TBD | `ACK` |
| `MAP_LINES (0x08)` | `EVENT` | xem phần [Viewport-clipped map lines](#viewport-clipped-map-lines--hud-map_lines) | `ACK` |

---

### NAV_INSTRUCTION_TEXT (0x01) — payload chi tiết

Gửi mỗi khi maneuver thay đổi hoặc khoảng cách cập nhật đáng kể.
Tất cả số nguyên là little-endian. Trường text là UTF-8, tối đa 64 byte, có thể
strip dấu nếu firmware báo không hỗ trợ (qua `capBitmap` trong DEVICE_INFO).

```
u8       direction_len          // byte length của direction_text (0–64)
u8[]     direction_text         // hướng rẽ hiện tại, vd "Rẽ trái"

u8       4                      // luôn = 4 (length prefix cố định cho u32)
u32      distance_to_maneuver_m // khoảng cách tới điểm rẽ (m)

u8       next_len               // byte length của next_direction_text
u8[]     next_direction_text    // hướng rẽ tiếp theo

u8       4
u32      destination_distance_m // tổng khoảng cách còn lại tới đích (m)

u8       4
u32      remaining_time_minutes // thời gian còn lại (phút)

u16      current_speed_mps      // tốc độ hiện tại (m/s), KHÔNG có length prefix

u8       4
u32      epoch_seconds          // Unix time UTC tại thời điểm gửi
```

### NAV_INSTRUCTION_IMAGE (0x02) — payload chi tiết

Gửi khi maneuver type thay đổi (coalesced, bỏ qua nếu type giống lần trước).
Hiện tại fixed 24×24 px RGB565 (maneuver icon), firmware vẽ lên HUD.

```
u8       format      // 0x01=RGB565, 0x02=RGB888, 0x03=MONO1
u16      width       // pixel, little-endian (hiện tại = 24)
u16      height      // pixel, little-endian (hiện tại = 24)
u16      data_len    // byte length của data
u8[]     data        // raw pixel data theo format trên
```

Với RGB565 24×24: `data_len = 24 × 24 × 2 = 1152 byte` → gửi 5 BLE write
chunk (MTU 247 byte).

### DEVICE_INFO (0x04) — response payload

```
u32      hardware_version
u32      firmware_version
u8[16]   manufacturer_id    // ASCII, null-padded
u8[32]   serial_number      // ASCII, null-padded
u32      product_id
u32      model_id           // dùng để tra HudDisplayConfig cho MAP_LINES
```

Tổng: 4+4+16+32+4+4 = **64 byte**.

Mobile đọc `model_id` → tra bảng `_hudDisplayConfigs` → biết `map_w × map_h`
để dùng cho projection trong `MAP_LINES`.

## Mini-map vector lines → HUD (MAP_LINES)

### Ý tưởng

ESP32 display chỉ có một vùng nhỏ dành cho mini-map (hiện tại 240×180 px trong
layout 240×320). Thay vì gửi ảnh bitmap (tốn bandwidth BLE), mobile gửi **dữ
liệu vector** — danh sách tọa độ pixel của các đoạn line — để ESP32 tự vẽ.

Mobile thực hiện toàn bộ phần nặng:
1. Tính geographic bounds mini-map **căn giữa theo vị trí user** (không phụ thuộc camera).
2. Query đường xung quanh từ vector tile source (`querySourceFeatures`).
3. Clip geometry vào bounds, project lat/lng → pixel (u8 x, u8 y).
4. Rotate tất cả toạ độ pixel theo bearing (heading-up).
5. Đóng gói và gửi qua `MAP_LINES (0x08)`.

ESP32 nhận list điểm → vẽ đường nối các điểm liên tiếp trong mỗi polyline.
**Firmware không cần xử lý bất kỳ phép tính bản đồ nào.**

---

### Device pairing — đọc model → suy ra kích thước display

Ngay khi BLE pair thành công, mobile gửi `DEVICE_INFO(0x04) REQUEST`. ESP32
trả về response chứa trường `model (uint32_t)`. Mobile tra bảng để biết:

- Kích thước toàn bộ display (`screen_w × screen_h`)
- Vùng dành riêng cho mini-map (`map_w × map_h`) — phần layout còn lại sau
  khi firmware đã dùng cho speedometer, maneuver icon, v.v.

```dart
// Bảng model → display config (mở rộng khi thêm hardware mới)
const _hudDisplayConfigs = {
  0x0001: HudDisplayConfig(screenW: 240, screenH: 320, screenW: 240, screenH: 180),
  0x0002: HudDisplayConfig(screenW: 320, screenH: 240, screenW: 200, screenH: 160),
  // ...
};

void onDeviceInfoReceived(DeviceInfo info) {
  final config = _hudDisplayConfigs[info.model]
      ?? HudDisplayConfig(screenW: 240, screenH: 320, screenW: 240, screenH: 180); // fallback
  _bleBridge?.setHudDisplayConfig(config);
}
```

`HudDisplayConfig` được lưu trong `BleBridge` và dùng cho mọi lần tính
bounds + pixel projection về sau.

---

### Mobile side (Flutter)

#### 1. Tính geographic bounds mini-map

Không dùng camera viewport (camera nghiêng 45° + look-ahead → user không ở
giữa). Thay vào đó tính bounds **cố định tỉ lệ 3 m/px** xung quanh điểm
phía trước user:

```
metersPerPixel = 3.0       // tỉ lệ cố định, không phụ thuộc zoom camera

// Offset center về phía trước user — khớp _navigationViewportOffsetFraction = 1/6
// trên điện thoại → user hiển thị ở 2/3 từ trên xuống trên cả 2 màn hình
lookahead_m = map_h × metersPerPixel / 6      // ví dụ 180 × 3 / 6 = 90 m

center_lat = user_lat + lookahead_m × cos(bearing) / 111320
center_lng = user_lng + lookahead_m × sin(bearing) / (111320 × cos(user_lat))

half_w_m = map_w × metersPerPixel / 2         // 240 × 3 / 2 = 360 m
half_h_m = map_h × metersPerPixel / 2         // 180 × 3 / 2 = 270 m

west  = center_lng - half_w_m / (111320 × cos(center_lat))
east  = center_lng + half_w_m / (111320 × cos(center_lat))
south = center_lat - half_h_m / 111320
north = center_lat + half_h_m / 111320
```

Kết quả: user luôn ở pixel **(map_w/2, map_h × 2/3)** trong không gian north-up
trước khi rotate — đúng với vị trí trên điện thoại.

#### 2. Query đường xung quanh (context roads)

Dùng `querySourceFeatures` thay vì `queryRenderedFeaturesInRect` vì camera
nghiêng 45° chỉ thấy đường phía trước, bỏ qua đường phía sau/hai bên.

```dart
// Thử các source ID phổ biến (OpenMapTiles / MapTiler / OpenFreeMap)
for (final srcId in ['openmaptiles', 'maptiler_planet', 'tiles']) {
  features = await controller.querySourceFeatures(srcId, 'transportation', null);
  if (features.isNotEmpty) break;
}
// Fallback: queryRenderedFeaturesInRect nếu source ID không khớp
```

Lọc:
- Chỉ lấy `LineString` / `MultiLineString`.
- Bỏ class `service`, `footway`, `cycleway`, `path`, `track`.
- Chỉ giữ segment có ít nhất 1 điểm trong vòng 450 m quanh user.
- Tối đa 30 road segments unique.

#### 3. Clip geometry vào bounds + project lat/lng → pixel (u8)

```
x = round((lng - west)  / (east  - west)  × (map_w - 1))   // 0..map_w-1
y = round((north - lat) / (north - south) × (map_h - 1))   // 0..map_h-1
// y đảo chiều: north → y=0 (top), south → y=max (bottom)
```

Clip: chỉ giữ segment có điểm trong bounds ± 2% buffer; thêm 1 điểm entry/exit
để line không bị cụt tại viền. Downsample tối đa 60 điểm/polyline.

#### 4. Rotate pixel coordinates (heading-up)

Sau khi project sang pixel (x, y) trong không gian north-up, rotate tất cả
toạ độ quanh tâm (cx, cy) = (map_w/2, map_h/2) theo góc **−bearing**:

```
angle = -bearing_deg × π / 180      // âm → rotate ngược chiều kim đồng hồ

x' = cx + (x − cx) × cos(angle) − (y − cy) × sin(angle)
y' = cy + (x − cx) × sin(angle) + (y − cy) × cos(angle)

// clamp x' về [0, map_w-1], y' về [0, map_h-1]
```

Kết quả: hướng di chuyển luôn hướng lên trên (y=0) trên cả điện thoại lẫn ESP32.

#### 5. Trigger gửi

Gửi khi user di chuyển ≥ 15 m so với lần gửi trước. Không gửi nếu BLE chưa
kết nối hoặc không đang dẫn đường.

---

### Protocol — MAP_LINES (0x08)

Frame wrapper giữ nguyên: `SOF | CMD | TYPE | LEN | PAYLOAD | CRC16/MCRF4XX`.

**Payload:**

```
u8   line_count              // số polyline trong gói (thường 2–10)

// Lặp lại line_count lần:
u8   line_type               // 0x01=route chính còn lại, 0x02=đường xung quanh,
                             // 0x03=đoạn đã đi (mờ)
u8   point_count             // số điểm của polyline này (tối đa 60)
u8[] points                  // point_count × 2 byte: x0,y0, x1,y1, ...
                             // toạ độ đã rotate heading-up, clamp [0..255]
```

**Thứ tự gửi:** `0x02` (đường xung quanh) trước → `0x03` (đã đi) → `0x01`
(route chính) sau cùng. ESP32 vẽ theo thứ tự nhận, line sau đè lên line trước.

Ví dụ gói 1 route chính 8 điểm + 2 đường giao 5 điểm + 1 đoạn đã đi 4 điểm:

```
04                                       // line_count = 4
  02  05  x0 y0 x1 y1 x2 y2 x3 y3 x4 y4  // đường giao 1
  02  05  x0 y0 x1 y1 x2 y2 x3 y3 x4 y4  // đường giao 2
  03  04  x0 y0 x1 y1 x2 y2 x3 y3         // đoạn đã đi
  01  08  x0 y0 x1 y1 ... x7 y7           // route chính
```

Tổng byte ví dụ: `1 + 2×(2+10) + (2+8) + (2+16)` = **53 byte** — nhỏ hơn 1 MTU.

**Không giới hạn cứng `line_count`** — `_writeFrame` tự chia chunk theo MTU.
Thực tế tối đa ~10 polylines vừa đủ 1 chunk 247 byte khi mỗi polyline ~5 điểm.

---

### Vị trí user trên mini-map (firmware note)

**User luôn ở tọa độ cố định sau rotation:**

```
user_x ≈ map_w / 2          // trung tâm theo chiều ngang
user_y ≈ map_h × 2 / 3      // 2/3 từ trên xuống (giống điện thoại)
```

Ví dụ 240×180: user ở pixel **(120, 120)**. Firmware có thể vẽ dot/arrow
tại toạ độ cố định này mà không cần nhận tọa độ riêng từ mobile.

---

### ESP32 side (firmware)

#### Parser

Khi `CMD == 0x08`, đọc `line_count` rồi loop. Frame có thể trải qua nhiều BLE
chunk — parser phải reassemble trước khi gọi handler.

```c
void map_lines_handler(const uint8_t *payload, uint16_t len) {
    uint16_t i = 0;
    uint8_t line_count = payload[i++];

    display_clear_map_region();  // xóa vùng mini-map trước khi vẽ lại

    for (uint8_t l = 0; l < line_count; l++) {
        uint8_t line_type   = payload[i++];
        uint8_t point_count = payload[i++];

        for (uint8_t p = 1; p < point_count; p++) {
            uint8_t x0 = payload[i + (p-1)*2];
            uint8_t y0 = payload[i + (p-1)*2 + 1];
            uint8_t x1 = payload[i + p*2];
            uint8_t y1 = payload[i + p*2 + 1];
            display_draw_line(x0, y0, x1, y1, line_type);
        }
        i += point_count * 2;
    }

    // Vẽ dot user tại vị trí cố định (heading-up, 2/3 từ trên)
    display_draw_user_dot(MAP_W / 2, MAP_H * 2 / 3);

    ack_status(ACK_OK);
}
```

#### Vẽ theo line_type

| `line_type` | Ý nghĩa | Style gợi ý |
|-------------|---------|-------------|
| `0x01` | route chính còn lại | nét đậm, màu primary (xanh) |
| `0x02` | đường giao / xung quanh | nét mảnh, màu xám nhạt |
| `0x03` | đoạn đã đi | nét mảnh, màu xám đậm hơn, opacity thấp |

`display_draw_line` dùng Bresenham line algorithm (có sẵn trong hầu hết
TFT driver như `ili9341`, `st7789`).

---

### Luồng tổng thể

```
GPS update (mỗi 1 s)
  └─► NavController → NavSnapshot (position, bearing, routeProgressM)
        └─► NavigationScreen ref.listen
              └─► di chuyển ≥ 15 m so với lần gửi trước?
                    └─► querySourceFeatures('openmaptiles', 'transportation')
                          └─► filter → context roads ≤ 30 segments
                                └─► _miniMapBounds(userLat, userLng, bearing)
                                      └─► clip route + context roads → pixels
                                            └─► rotate pixels by −bearing
                                                  └─► encode MAP_LINES payload
                                                        └─► BleBridge → NUS TX
                                                              └─► ESP32 map_lines_handler()
                                                                    └─► display_draw_line() × N
                                                                          └─► display_draw_user_dot(cx, cy*2/3)
```

---

## Ghi chú triển khai

- **Font (§3.4):** production nên bundle `.ttf` Be Vietnam Pro / Inter vào
  `assets/fonts/` và đặt `GoogleFonts.config.allowRuntimeFetching = false`
  trong `main()` để chạy offline. Hiện đang để runtime fetching = true.
- **Persistence:** dùng `shared_preferences` cho settings/favorites/history
  (drift có trong deps, để mở rộng sign-cache theo §4.4).
- **flutter_blue_plus** cần commercial license cho mục đích thương mại — đã bọc
  sau `IBleTransport` để swap sang `bluetooth_low_energy` (BSD) nếu cần (§3.2).
- **Foreground service** (background navigation §4.3): manifest đã khai báo type
  `location|connectedDevice`; phần khởi động service để TODO trong S4.
