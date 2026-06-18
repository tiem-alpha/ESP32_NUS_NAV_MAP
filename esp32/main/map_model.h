/*
 * map_model.h — State bản đồ: live pose (0x30) + route (0x31) + roads (0x32).
 * Hình học ở hệ mét north-up, lưu offset decimet (dm) i16 so với anchor tuyệt đối.
 * Double-buffer: ghi back buffer theo seq/frag, đủ frag_total mới swap để render.
 * Kích thước giữ NHỎ vì ESP32-H2 không có PSRAM.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "nav_proto.h"

#ifdef __cplusplus
extern "C" {
#endif

#define MAP_MAX_ROUTE_PTS 200
#define MAP_MAX_ROADS     64   /* 48→64: RAM giữ nguyên (64×122B = 48×162B); đủ phủ hẻm dày VN */
#define MAP_MAX_ROAD_PTS  30   /* 40→30: giao hoán pts lấy roads; ~40m/pt đủ mượt ở HUD scale */

typedef struct { int16_t e_dm, n_dm; } map_pt_t; /* north-up dm so với anchor */

typedef struct {
    uint8_t  road_class; /* HighwayType.value */
    uint8_t  n;
    map_pt_t pts[MAP_MAX_ROAD_PTS];
} map_road_t;

typedef struct {
    bool     valid;
    int32_t  anchor_lat_e7;
    int32_t  anchor_lng_e7;
    uint16_t route_n;
    map_pt_t route[MAP_MAX_ROUTE_PTS];
    uint8_t  road_n;
    map_road_t roads[MAP_MAX_ROADS];
} map_geom_t;

void map_model_init(void);                   /* đăng ký handler 0x30–0x32 */

/* Pose mới nhất (atomic copy). */
void map_model_get_pose(map_pose_t *out);
bool map_model_has_pose(void);

/* Khoá front buffer geom để render. Trả NULL nếu chưa có. PHẢI gọi unlock sau đó. */
const map_geom_t *map_model_lock_geom(void);
void map_model_unlock_geom(void);

/* Nạp geom từ cache lúc boot (front buffer). */
void map_model_set_geom(const map_geom_t *g);

#ifdef __cplusplus
}
#endif
