# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Mobile navigation app (Flutter, `mobile/`) + BLE HUD companion firmware (ESP32, `esp32/`). The phone does all the heavy lifting (map, search, routing, turn-by-turn, map-matching) and pushes nav data over BLE (Nordic UART Service) to an ESP32 that renders a **full-screen heading-up map** with nav info overlaid on a ST7789 240×320 TFT.

Two real codebases live here; the `.md` design docs are background, the code is the truth.

Design documents:
- **BLE protocol + mobile app design (SOURCE OF TRUTH): `mobile/thiet-ke-ung-dung-chi-duong-ble-nus.md`** — the app code follows this. Frame format, message table (§6), UI screens (§11). Any protocol change goes here first, then both sides.
- ESP32 firmware design (full-screen HUD): `esp32/DESIGN.md`
- Original system sketch (historical): `ESP32_Navigation_OpenStreetMap_Design.md`

## Tech Stack

**Flutter App (`mobile/`)** — package `navhud`
- Flutter 3.44.0 / Dart 3.12.0, state via `flutter_riverpod` 3
- Map: `maplibre_gl`; GPS: `geolocator`; BLE: `flutter_blue_plus` (commercial license — wrapped behind `IBleTransport` so it can be swapped)
- HTTP: `dio`; storage: `drift` + `shared_preferences`; TTS: `flutter_tts`; background: `flutter_foreground_task`

**ESP32 Firmware (`esp32/`)** — ESP-IDF v5.x
- BLE: **Bluedroid** GATT server implementing NUS (`main/nus.c`, already working) — not NimBLE
- UI: LVGL v9 (managed component); Display: ST7789 240×320

**External services**
- Routing: Valhalla (`auto`/`motor_scooter`/`bicycle` profiles)
- Geocoding: Goong (if `GOONG_API_KEY` set) else Nominatim
- Roads + traffic signs: Overpass API

## Build Commands

**Flutter App** (from `mobile/`)
```bash
flutter pub get
flutter run
flutter analyze lib                  # or: dart analyze lib/<subdir>
flutter test
flutter build apk --release
# endpoints overridable: --dart-define=VALHALLA_URL=... GOONG_API_KEY=... MAP_STYLE_URL=...
```

**ESP32 Firmware** (from `esp32/`)
```bash
idf.py set-target esp32
idf.py build
idf.py size                          # firmware must fit factory partition (~1.94MB)
idf.py -p <PORT> flash monitor
```

## Architecture — Mobile

Layered, interface-driven (see design §2.2). Lower layers don't know upper ones.

- **Navigation Engine** (`lib/navigation/nav_controller.dart`) is the single source of truth: a state machine (IDLE→ROUTING→NAVIGATING↔OFF_ROUTE→ARRIVED) that map-matches each 1 Hz GPS fix and emits `NavEvent`s onto an event bus (`lib/core/event_bus.dart`). It does NOT know about BLE.
- **Subscribers** render from those events independently: UI screens, TTS (`lib/navigation/nav_voice.dart`), and the **BLE Bridge** (`lib/ble/ble_bridge.dart`). Adding a subscriber never touches the engine.
- **Services behind interfaces** (`lib/providers/app_providers.dart` wires them): `IRouteService`→`ValhallaRouteService` (`lib/routing/`), `IGeocodingService`→`GeocodingService` (`lib/search/`), `ISignService`→`OverpassSignService` + `OverpassRoadService` (`lib/traffic/`), `IBleTransport`→`FlutterBlueTransport` (`lib/ble/`).
- **Riverpod providers** in `lib/providers/` (`app_providers`, `ble_providers`, `nav_providers`, `ui_providers`).

Key folders under `mobile/lib/`: `ble/`, `routing/`, `search/`, `traffic/`, `navigation/`, `models/`, `providers/`, `ui/`, `core/`.

## BLE Protocol (source of truth: design §5–6)

NUS service `6E400001-…`, RX (phone→device write) `…0002-…`, TX (device→phone notify) `…0003-…`. Negotiated MTU 247. All multi-byte **little-endian**.

**Frame:** `SOF(0xA5) | TYPE(u8) | LEN(u8, ≤200) | PAYLOAD | CRC16/MCRF4XX(u16 LE)`. CRC over `TYPE+LEN+PAYLOAD`. Byte-stream parser (SOF→TYPE→LEN→PAYLOAD→CRC) tolerant of BLE fragmentation. CRC self-test: `"123456789" → 0x6F91` (impl: `lib/ble/crc16_mcrf4xx.dart`).

**Messages:** banner/HUD info (App→Dev) `0x01 HELLO`, `0x02 DEVICE_INFO` (Dev→App), `0x10 NAV_INSTRUCTION`, `0x11 DISTANCE_TICK`, `0x12 SPEED_LIMIT`, `0x13 TRAFFIC_SIGN`, `0x14 NAV_STATE`, `0x20 ACK` (Dev→App), `0x21 BTN_EVENT` (Dev→App), `0x7E HEARTBEAT`. Full-screen map extension (§6.2.1): `0x30 MAP_POSE`, `0x31 MAP_ROUTE`, `0x32 MAP_ROADS`.

**Wire enums are shared with firmware** and must stay stable (only append): `ManeuverType.wire` (`lib/models/maneuver_type.dart`), `SignType.wire` (`lib/models/traffic_sign.dart`), `HighwayType.value` (`lib/models/road_segment.dart`).

**Reliability (§5.3):** Write-No-Response + coalescing for periodic frames (DISTANCE_TICK, MAP_POSE); Write-With-Response for important ones (NAV_INSTRUCTION, NAV_STATE), never dropped. Reconnect backoff 1/2/4/8 s, resend snapshot on reconnect. 5 s heartbeat.

## Map sync — full-screen HUD (§6.2.1)

ESP32 renders the map **full-screen** with nav info overlaid; **ESP32 does the projection** (the app doesn't know HUD screen size).
- App sends `MAP_POSE` frequently (~2 Hz: absolute lat/lng deg×1e7, heading, speed, flags).
- App sends `MAP_ROUTE`/`MAP_ROADS` rarely (start/reroute or anchor moved >~800 m): geometry as **north-up east/north decimetre offsets** around an absolute `anchor`, simplified + clipped to a ~1.2 km window, fragmented across frames by `seq`/`frag_idx`.
- ESP32 each frame translates anchor→live user, rotates by −heading (heading-up), scales by zoom, places user bottom-center. North-up offsets mean **heading changes need no resend**.

Bandwidth rule: only MAP_POSE is frequent; route/roads are infrequent — don't resend bulk geometry every position tick.

## Architecture — ESP32 (see `esp32/DESIGN.md`)

`main/nus.c` (Bluedroid NUS) is done. To build: `nus_protocol` (deframe/CRC/dispatch by TYPE), `nav_model` (overlay state), `map_model` (pose + route/roads, double-buffered seq/frag reassembly), `projection` (metres→pixels, fixed-point), `display` (LVGL full-screen map + overlay widgets), `map_cache` (SPIFFS). `main.c` already references `nus_protocol.h`/`map_cache.h`/`display_*` — those modules still need writing.

Flash: 4MB, 2MB filesystem. `factory` app ≈1.94MB + `storage` 2MB (SPIFFS, no OTA). Check `idf.py size` each build. Device config in NVS, not the filesystem.
