# Thiết Kế Hệ Thống Navigation ESP32 + Smartphone (OpenStreetMap)

## 1. Mục tiêu

Xây dựng hệ thống chỉ đường cho xe máy/xe đạp gồm:

- Smartphone thực hiện:
  - Hiển thị bản đồ
  - Tìm kiếm địa điểm
  - Định tuyến
  - Điều hướng turn-by-turn
  - Xử lý dữ liệu bản đồ
  - Gửi dữ liệu sang ESP32 qua BLE

- ESP32 thực hiện:
  - Nhận dữ liệu từ điện thoại
  - Hiển thị bản đồ tối giản
  - Hiển thị tuyến đường
  - Hiển thị hướng rẽ
  - Hiển thị tốc độ, ETA, khoảng cách

---

# 2. Kiến trúc tổng thể

```text
OpenStreetMap
      │
      ▼
┌────────────────────┐
│ Search Engine      │
│ Photon/Nominatim   │
└─────────┬──────────┘
          │
          ▼
┌────────────────────┐
│ Routing Engine     │
│ Valhalla / OSRM    │
└─────────┬──────────┘
          │
          ▼
┌────────────────────┐
│ Overpass API       │
│ Nearby Roads       │
└─────────┬──────────┘
          │
          ▼
┌────────────────────┐
│ Flutter App        │
│ Data Processing    │
└─────────┬──────────┘
          │ BLE NUS
          ▼
┌────────────────────┐
│ ESP32              │
│ LVGL + ST7789      │
└────────────────────┘
```

---

# 3. Công nghệ

## Mobile App

- Flutter 3.44.0
- Dart 3.12.0
- Riverpod
- MapLibre
- flutter_foreground_task
- flutter_tts
- flutter_blue_plus

## Backend Services

- OpenStreetMap
- Valhalla
- Overpass API
- Photon hoặc Nominatim

## ESP32

- ESP-IDF v5.5.3
- NimBLE
- LVGL v8
- ST7789 TFT 240x320

---

# 4. Chức năng App

## 4.1 Trang bản đồ

Hiển thị:

- Vị trí hiện tại
- Route
- Điểm đến
- Các đường xung quanh

### Thành phần UI

```text
┌──────────────────────┐
│ Search Bar           │
├──────────────────────┤
│                      │
│      MapLibre        │
│                      │
├──────────────────────┤
│ Start Navigation     │
└──────────────────────┘
```

---

## 4.2 Tìm kiếm địa điểm

Nguồn:

- Photon
- Nominatim

Kết quả:

- Tên
- Địa chỉ
- Khoảng cách
- Tọa độ

---

## 4.3 Định tuyến

Valhalla trả về:

- Polyline
- Distance
- Duration
- Maneuver
- Turn instruction

---

## 4.4 Chế độ Navigation

Hiển thị:

- ETA
- Distance remaining
- Next turn
- Current speed

Chạy nền:

- Foreground Service
- Notification chỉ đường

---

# 5. Lấy đường lân cận

Mục tiêu:

Hiển thị giống Beeline hoặc Google Navigation.

### Nguồn dữ liệu

Overpass API

### Bán kính

```text
100m - 150m
```

### Chỉ lấy

```text
highway=*
```

Bao gồm:

- primary
- secondary
- tertiary
- residential
- service

Không lấy:

- building
- landuse
- amenity

---

# 6. Pipeline xử lý dữ liệu

## Bước 1

Valhalla route

```text
Route chính
```

## Bước 2

Overpass roads

```text
Roads xung quanh
```

## Bước 3

Simplify polyline

Douglas Peucker

---

## Bước 4

Convert GPS

```text
Lat/Lon
    ↓
Local Meter
    ↓
Screen Coordinate
```

ESP32 không xử lý GPS.

---

## Bước 5

Clip viewport

Chỉ gửi dữ liệu nhìn thấy trên màn hình.

---

## Bước 6

Binary packet

Không dùng JSON cho bản release.

---

# 7. BLE Communication

## BLE Service

Nordic UART Service

### TX

App → ESP32

### RX

ESP32 → App

---

## MTU

Khuyến nghị:

```text
500 bytes
```

---

# 8. Protocol

## Header

```c
typedef struct {
    uint8_t magic;
    uint8_t type;
    uint16_t seq;
    uint16_t length;
    uint16_t crc;
} PacketHeader;
```

---

## Packet Types

```text
0x01 ROUTE
0x02 ROADS
0x03 NAV_STATUS
0x04 NEXT_TURN
0x05 CONFIG
0x06 ACK
```

---

# 9. Route Packet

```c
typedef struct {
    uint16_t pointCount;
    Point points[];
} RoutePacket;
```

---

# 10. Nearby Roads Packet

```c
typedef struct {
    uint16_t roadCount;
    Road roads[];
} RoadsPacket;
```

---

# 11. Navigation Packet

```c
typedef struct {
    uint16_t remainDistance;
    uint16_t eta;
    uint8_t maneuver;
} NavPacket;
```

---

# 12. ESP32 Architecture

```text
BLE Task
     │
     ▼
Packet Queue
     │
     ▼
Map Renderer
     │
     ▼
LVGL UI
```

---

# 13. FreeRTOS Tasks

## BLE Task

Nhận dữ liệu BLE

Priority:

```text
5
```

---

## Parser Task

Parse packet

Priority:

```text
4
```

---

## Render Task

Render map

Priority:

```text
3
```

---

## UI Task

LVGL

Priority:

```text
2
```

---

# 14. Layout TFT 240x320

## Top Bar

```text
240 x 59
```

Hiển thị:

- Icon rẽ
- Khoảng cách tới điểm rẽ
- ETA

---

## Map Area

```text
240 x 180
```

Hiển thị:

- Route màu xanh
- Roads màu xám
- User arrow

---

## Bottom Area

```text
240 x 81
```

Hiển thị:

- Speed
- Distance
- GPS Status
- BLE Status

---

# 15. Rendering

## Roads

```text
Màu xám
```

## Route

```text
Màu xanh
Độ dày 4 px
```

## User

```text
Mũi tên trắng
```

---

# 16. Đồng bộ dữ liệu

## Gửi Route

Khi:

- Start navigation
- Reroute

---

## Gửi Roads

Khi:

- Di chuyển > 50m
- Zoom thay đổi

---

## Gửi Status

Tần suất:

```text
1 Hz
```

---

# 17. Tối ưu hiệu năng

## App

- Cache Overpass
- Cache Search
- Simplify Polyline
- Delta Update

## ESP32

- Double Buffer
- Dirty Region Render
- Fixed Point Math
- PSRAM nếu có

---

# 18. Roadmap

## Phase 1

- Search
- Route
- BLE
- Render Route

## Phase 2

- Nearby Roads

## Phase 3

- Turn By Turn

## Phase 4

- Background Navigation

## Phase 5

- Offline Region Cache

---

# 19. Kết quả mong muốn

ESP32 hiển thị:

- Tuyến đường chính
- Đường lân cận
- Hướng rẽ
- ETA
- Tốc độ

Tương tự Beeline nhưng sử dụng:

- OpenStreetMap
- Valhalla
- Overpass
- MapLibre
- BLE NUS
