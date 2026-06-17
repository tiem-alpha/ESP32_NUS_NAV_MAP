/*
 * nav_proto.h — Hợp đồng wire dùng chung với app Flutter.
 * Nguồn chân lý: ../../mobile/thiet-ke-ung-dung-chi-duong-ble-nus.md §5–6.
 * Frame: SOF(0xA5) | TYPE(u8) | LEN(u8 ≤200) | PAYLOAD | CRC16/MCRF4XX(u16 LE).
 * Mọi số multi-byte little-endian. KHÔNG đổi giá trị enum (chỉ append).
 */
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NAV_PROTO_SOF          0xA5
#define NAV_PROTO_VER          1
#define NAV_PROTO_MAX_PAYLOAD  200

/* Message TYPE (§6.2) */
enum {
    MSG_HELLO           = 0x01, /* App→Dev: proto_ver u8 */
    MSG_DEVICE_INFO     = 0x02, /* Dev→App: fw_ver u16, cap_bitmap u16, max_text u8 */
    MSG_NAV_INSTRUCTION = 0x10, /* App→Dev: §6.3 */
    MSG_DISTANCE_TICK   = 0x11, /* App→Dev: dist_to_man u16, dist_remain u32, eta u16(min), speed u8 */
    MSG_SPEED_LIMIT     = 0x12, /* App→Dev: limit u8, is_over u8 */
    MSG_TRAFFIC_SIGN    = 0x13, /* App→Dev: sign_type u8, dist u16, value u8 */
    MSG_NAV_STATE       = 0x14, /* App→Dev: state u8 */
    MSG_ACK             = 0x20, /* Dev→App: acked_type u8, seq u8 */
    MSG_BTN_EVENT       = 0x21, /* Dev→App: btn u8, action u8 */
    MSG_HEARTBEAT       = 0x7E, /* 2 chiều: uptime u32 */
    MSG_MAP_POSE        = 0x30, /* App→Dev: §6.2.1 */
    MSG_MAP_ROUTE       = 0x31, /* App→Dev: §6.2.1 (anchor + frag) */
    MSG_MAP_ROADS       = 0x32, /* App→Dev: §6.2.1 (anchor + frag) */
    MSG_MAP_CLOCK       = 0x33, /* App→Dev: epoch_s u32, tz_offset_min i16 */
};

/* maneuver_e — khớp Dart ManeuverType.wire */
typedef enum {
    MAN_DEPART = 0, MAN_STRAIGHT, MAN_TURN_SLIGHT_LEFT, MAN_TURN_LEFT,
    MAN_TURN_SHARP_LEFT, MAN_UTURN, MAN_TURN_SHARP_RIGHT, MAN_TURN_RIGHT,
    MAN_TURN_SLIGHT_RIGHT, MAN_ROUNDABOUT, MAN_EXIT_LEFT, MAN_EXIT_RIGHT,
    MAN_MERGE, MAN_FERRY, MAN_ARRIVE, MAN_ARRIVE_LEFT, MAN_ARRIVE_RIGHT,
    MAN_COUNT
} maneuver_e;

/* sign_type — khớp Dart SignType.wire */
typedef enum {
    SIGN_UNKNOWN = 0, SIGN_SPEED_LIMIT, SIGN_SPEED_CAMERA, SIGN_NO_ENTRY,
    SIGN_NO_LEFT, SIGN_NO_RIGHT, SIGN_NO_UTURN, SIGN_STOP, SIGN_YIELD,
    SIGN_RAILWAY, SIGN_SCHOOL, SIGN_RED_LIGHT_CAMERA,
} sign_type_e;

/* nav_state (TYPE 0x14) */
typedef enum { NAV_IDLE = 0, NAV_NAVIGATING, NAV_REROUTING, NAV_ARRIVED } nav_state_e;

/* MAP_POSE flags */
#define MAP_FLAG_GPS_FIX    (1u << 0)
#define MAP_FLAG_OFF_ROUTE  (1u << 1)
#define MAP_FLAG_NAVIGATING (1u << 2)

/* DEVICE_INFO capability bits (cap_bitmap) — khớp Dart DeviceInfo.cap* */
#define CAP_DIACRITICS   (1u << 0)
#define CAP_SPEED_LIMIT  (1u << 1)
#define CAP_TRAFFIC_SIGN (1u << 2)
#define CAP_LANE_INFO    (1u << 3)
#define CAP_BUTTONS      (1u << 4)

/* ── Live pose đã decode (MAP_POSE 0x30) ─────────────────────────────── */
typedef struct {
    int32_t  lat_e7;   /* deg × 1e7 */
    int32_t  lng_e7;   /* deg × 1e7 */
    uint16_t heading_ddeg; /* 0.1°, 0..3599 */
    uint8_t  speed_kmh;
    uint8_t  flags;
    uint16_t view_span_dm; /* mét×10 toàn chiều rộng màn điện thoại ở zoom
                             * hiện tại — projection dùng để khớp tỷ lệ zoom. */
    uint64_t received_us;  /* esp_timer_get_time() khi nhận — dead reckoning */
} map_pose_t;

/* ── Helper đọc little-endian (parser dùng chung) ────────────────────── */
static inline uint16_t le_u16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static inline uint32_t le_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static inline int16_t le_i16(const uint8_t *p) { return (int16_t)le_u16(p); }
static inline int32_t le_i32(const uint8_t *p) { return (int32_t)le_u32(p); }
static inline void wr_u16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static inline void wr_u32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

/* CRC-16/MCRF4XX (poly 0x1021 reflected 0x8408, init 0xFFFF). Self-test "123456789"→0x6F91 */
uint16_t nav_crc16_mcrf4xx(const uint8_t *data, size_t len);

#ifdef __cplusplus
}
#endif
