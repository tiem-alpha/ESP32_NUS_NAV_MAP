# Thiết Kế Chi Tiết — ESP32 Firmware (HUD full-screen)

> **Phiên bản 0.3 — thiết kế lại cho màn full-screen.** Bỏ layout 3 vùng (top/map/bottom) cũ. Màn TFT 240×320 hiển thị **bản đồ chiếm toàn bộ màn hình**, thông tin dẫn đường vẽ **overlay** đè lên map.

Protocol BLE là **nguồn chân lý** tại `../mobile/thiet-ke-ung-dung-chi-duong-ble-nus.md` (§5–6, frame `SOF 0xA5 | TYPE | LEN | PAYLOAD | CRC16/MCRF4XX`). Tài liệu này mô tả cách firmware ESP32 triển khai phía thiết bị.

---

## 1. Vai trò của ESP32

ESP32 = **HUD hiển thị**, là **Peripheral** advertise Nordic UART Service (NUS). Điện thoại là Central.

- Nhận frame NUS từ app (RX char), parse theo state machine byte-stream.
- Vẽ **bản đồ full-screen heading-up**: tuyến đường, đường lân cận, mũi tên user.
- Vẽ **overlay** đè lên map: hướng rẽ + khoảng cách, tốc độ, ETA, biển báo, trạng thái BLE/GPS.
- Gửi ngược: DEVICE_INFO (trả HELLO), ACK, BTN_EVENT, HEARTBEAT.

**ESP32 tự chiếu toạ độ** (app KHÔNG biết kích thước màn HUD). App gửi hình học ở hệ mét north-up quanh một anchor tuyệt đối; ESP32 dịch + xoay theo heading + scale + đặt user giữa-dưới (xem §7).

---

## 2. Công nghệ

| Mục đích | Công nghệ |
|----------|-----------|
| Chip | **ESP32-H2** (RISC-V single-core, BLE-only, **KHÔNG có PSRAM**, ~256KB SRAM sau Bluedroid) |
| Framework | ESP-IDF v5.x |
| BLE stack | Bluedroid GATT server (NUS) — đã có tại `main/nus.c` |
| GUI | **LVGL v8.3** (managed component `lvgl/lvgl`), color depth 16, `LV_COLOR_16_SWAP=1` |
| Display | ST7789 TFT 240×320, SPI qua `esp_lcd`; chân từ Kconfig (`CONFIG_LCD_*`: MOSI5/SCLK4/CS1/DC10/RST12/BL22, 40MHz) |
| RTOS | FreeRTOS (100 Hz) |
| Lưu trữ | SPIFFS cho asset + map cache (partition `spiffs` 2MB) |

> **Ràng buộc RAM (H2, không PSRAM):** KHÔNG đủ chỗ cho framebuffer full 240×320 (153KB). Dùng **LVGL partial draw buffer** nhỏ (vd 2× 240×40 ≈ 38KB) — LVGL tự render từng dải rồi flush ra ST7789. Map vẽ bằng **custom draw** (`LV_EVENT_DRAW_MAIN` của 1 obj full-screen, dùng `lv_draw_line`), KHÔNG dùng `lv_canvas` full-screen. Overlay = widget LVGL con (label/img) đặt đè. Giữ `MAX_ROUTE_PTS`/`MAX_ROADS` nhỏ.

---

## 3. Kiến trúc module (component riêng biệt)

`main.c` hiện đã tham chiếu `nus.h`, `nus_protocol.h`, `map_cache.h` và `display_*`. Các module cần hoàn thiện:

| Module | File | Trách nhiệm duy nhất | Trạng thái |
|--------|------|----------------------|-----------|
| `nus` | `main/nus.c/.h` | GATT NUS: advertise, MTU, RX→callback, TX queue | ✅ đã có |
| `nus_protocol` | `main/nus_protocol.c/.h` | Deframe `SOF 0xA5..CRC16`, verify CRC16/MCRF4XX, dispatch theo TYPE, sinh ACK; encode frame TX | ⬜ cần viết |
| `nav_model` | `main/nav_model.c/.h` | State overlay: instruction, distance, speed, eta, speed limit, nav_state (từ TYPE 0x10–0x14) | ⬜ |
| `map_model` | `main/map_model.c/.h` | State map: live pose (0x30), route + roads (0x31/0x32) ở hệ mét north-up; double-buffer + seq/frag reassembly | ⬜ |
| `map_cache` | `main/map_cache.c/.h` | Lưu/nạp bộ route+roads gần nhất vào SPIFFS (khôi phục nhanh sau reboot) | ⬜ |
| `projection` | `main/projection.c/.h` | Chiếu mét north-up → pixel màn hình (translate + rotate heading + scale + anchor giữa-dưới); fixed-point | ⬜ |
| `display` | `main/display.c/.h` | LVGL: canvas map full-screen + overlay widgets; `display_set_connected()` v.v. | ⬜ |

`nus_protocol` đăng ký handler theo TYPE (decouple feature khỏi parser):
```c
typedef void (*proto_handler_t)(uint8_t type, const uint8_t *payload, uint16_t len);
esp_err_t nus_protocol_register(uint8_t type, proto_handler_t h);
```

---

## 4. Luồng dữ liệu

```text
 nus (RX char, byte stream)
        │  esp queue
        ▼
 nus_protocol  (deframe SOF..CRC16, verify CRC16/MCRF4XX, dispatch theo TYPE)
        ├── 0x01 HELLO        → trả 0x02 DEVICE_INFO
        ├── 0x10 NAV_INSTRUCTION → nav_model (+ ACK)
        ├── 0x11 DISTANCE_TICK   → nav_model
        ├── 0x12 SPEED_LIMIT     → nav_model
        ├── 0x14 NAV_STATE       → nav_model (+ ACK)
        ├── 0x30 MAP_POSE        → map_model.live_pose
        ├── 0x31 MAP_ROUTE       → map_model (reassembly theo seq/frag → swap)
        └── 0x32 MAP_ROADS       → map_model (reassembly → swap)
        ▼
 map_model + nav_model  (double-buffer, mutex)
        ▼
 projection (mét north-up → pixel, heading-up, user giữa-dưới)
        ▼
 display (LVGL: vẽ map canvas full-screen + overlay widgets) → ST7789
```

Chiều ngược: nav_model/protocol → `nus_protocol` encode frame → `nus_send()` (TX notify): DEVICE_INFO, ACK, BTN_EVENT, HEARTBEAT.

---

## 5. FreeRTOS Tasks

| Task | Priority | Module | Trách nhiệm |
|------|----------|--------|-------------|
| BLE host | (bluedroid) | `nus` | Nhận RX → đẩy byte vào queue; TX queue |
| Proto/Parse | 5 | `nus_protocol` | Deframe, verify CRC, dispatch → cập nhật model |
| Render | 3 | `projection`+`display` | Mỗi khung: chiếu pose mới, vẽ map + overlay (dirty region) |
| LVGL tick | 2 | `display` | `lv_timer_handler()` + flush ST7789 |

Đồng bộ: nus→proto = queue; proto→model = mutex + double-buffer (back buffer ghi đủ frag rồi swap); model→render = cờ dirty.

---

## 6. Bố cục màn hình — FULL-SCREEN (240×320)

```text
┌────────────────────────────┐  y=0
│ ⬅ 350m            ⌀50      │  overlay TRÊN (bán trong suốt):
│                            │    mũi tên rẽ + khoảng cách | biển tốc độ
│                            │
│        [ MAP FULL ]        │  bản đồ chiếm TOÀN BỘ 240×320
│         heading-up         │    route (xanh, đậm), roads (xám),
│            ▲ user          │    user = mũi tên trắng ở giữa-dưới
│      (giữa-dưới màn)        │
│                            │
│ 42 km/h          14:32·6km │  overlay DƯỚI: tốc độ | ETA + còn lại
└────────────────────────────┘  y=320
```

- Map là **layer nền** (LVGL canvas full-screen). Overlay là widget LVGL có nền bán trong suốt vẽ đè.
- User neo ở **giữa-dưới** (≈ x=120, y=230) để nhìn xa phía trước khi heading-up.
- Overlay đổi nội dung từ nav_model (NAV_INSTRUCTION/DISTANCE_TICK/SPEED_LIMIT/NAV_STATE). Lệch tuyến (flags off_route / NAV_STATE rerouting) → overlay rẽ chuyển trạng thái "đang tìm đường".

---

## 7. Projection (mét north-up → pixel)

Mỗi khung render, với `live_pose` (0x30) và bộ route/roads (anchor + offset dm north-up):

1. **Anchor→user**: đổi `anchor` và `live_pose` (đều lat/lng tuyệt đối) sang mét; lấy `user_off = live_pose − anchor` (mét). Điểm route/roads có sẵn offset north-up so với anchor.
2. **Về hệ user**: `p_user = p_anchor_offset − user_off` (mét north-up quanh user).
3. **Xoay heading-up**: quay `−heading`:
   `xr =  e·cosθ + n·sinθ` ; `yr = −e·sinθ + n·cosθ` (θ = heading).
4. **Scale + đặt gốc**: `px = CX + xr·s` ; `py = USER_Y − yr·s` (s = px/mét theo zoom; CX=120, USER_Y≈230).
5. **Clip** vào 240×320 (Cohen–Sutherland) trước khi vẽ line.

Dùng **fixed-point** (Q16.16) cho vòng vẽ; tránh float. Zoom `s` auto theo speed (đi nhanh → zoom xa hơn).

---

## 8. Rendering

| Đối tượng | Kiểu vẽ |
|-----------|---------|
| Roads | đường xám, độ dày theo `class` (đường lớn dày hơn) |
| Route | xanh, dày ~5–7 px |
| User | mũi tên trắng tại (CX, USER_Y) |
| Overlay | widget LVGL nền bán trong suốt: turn+dist (trên-trái), speed-limit (trên-phải), speed (dưới-trái), ETA (dưới-phải) |

Tối ưu: double buffer, dirty region (overlay đổi không vẽ lại cả map nếu pose chưa đổi), fixed-point, PSRAM cho canvas nếu có.

---

## 9. Map model — reassembly & double buffer

- `0x30 MAP_POSE`: cập nhật `live_pose` (lat,lng,heading,speed,flags) — rẻ, ghi trực tiếp (atomic/mutex ngắn).
- `0x31 MAP_ROUTE` / `0x32 MAP_ROADS`: có `seq` + `frag_idx`/`frag_total`. Ghi vào **back buffer** theo `seq`; chỉ khi nhận đủ `frag_total` mảnh cùng `seq` mới **swap** sang front buffer để render (chống vẽ nửa vời). Bộ `seq` cũ hơn thì bỏ.
- Giới hạn `MAX_ROUTE_POINTS`, `MAX_ROADS`, `MAX_ROAD_POINTS` chống tràn RAM; vượt thì cắt.
- `map_cache`: lưu front buffer (route+roads+anchor) ra SPIFFS để khôi phục sau reboot trong lúc chờ app gửi lại.

---

## 10. Device Info & Config

- **DEVICE_INFO (0x02)** trả lời HELLO (0x01): `fw_ver` u16, `cap_bitmap` u16, `max_text` u8 (theo §6.2). `cap_bitmap` khai báo năng lực (hỗ trợ dấu tiếng Việt, speed limit, traffic sign…) để app điều chỉnh nội dung gửi.
- Cấu hình day/night + brightness: lưu NVS; áp brightness qua PWM backlight, day/night đổi palette overlay/map.

---

## 11. Quản lý bộ nhớ & Flash (4MB, 2MB filesystem)

`partitions.csv` đề xuất (tổng = 4MB):
```csv
# Name,   Type, SubType,  Offset,   Size
nvs,      data, nvs,      0x9000,   0x6000
phy_init, data, phy,      0xf000,   0x1000
factory,  app,  factory,  0x10000,  0x1F0000   # ~1.94MB firmware
storage,  data, spiffs,   0x200000, 0x200000   # 2MB filesystem (asset + map cache)
```
- Theo dõi `idf.py size` mỗi build, không vượt trần `factory` ~1.94MB. Sơ đồ single-app (không OTA); muốn OTA cần flash 8MB.
- `storage` (2MB): font LVGL có dấu tiếng Việt, icon hướng rẽ/biển báo, `map_cache`. Config thiết bị ở `nvs`.

---

## 12. Build & Flash

```bash
idf.py set-target esp32
idf.py menuconfig     # Bluedroid, PSRAM, SPI/LVGL, SPIFFS, custom partitions.csv
idf.py build
idf.py size           # kiểm firmware không vượt factory
idf.py -p <PORT> flash monitor
```

---

## 13. Lộ trình triển khai (Firmware)

- **Phase 0:** `nus_protocol` (deframe + CRC16 self-test "123456789"→0x6F91 + dispatch) + HELLO→DEVICE_INFO + ACK.
- **Phase 1:** `display` LVGL full-screen + overlay tĩnh; nav_model từ NAV_INSTRUCTION/DISTANCE_TICK → overlay sống.
- **Phase 2:** `map_model` + `projection` + vẽ MAP_POSE/MAP_ROUTE (route full-screen heading-up).
- **Phase 3:** MAP_ROADS (đường lân cận) + speed limit/biển báo overlay + BTN_EVENT.
- **Phase 4:** day/night + brightness (NVS), `map_cache` SPIFFS, HEARTBEAT.
- **Phase 5:** tối ưu dirty region + fixed-point + PSRAM.
