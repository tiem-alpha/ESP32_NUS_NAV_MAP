/*
 * map_model.c — State bản đồ HUD: pose (0x30) + route (0x31) + roads (0x32).
 *
 * Hình học north-up, offset decimet i16 so với anchor tuyệt đối.
 * Double-buffer: ghi BACK buffer theo seq/frag; khi 1 bộ (route hoặc roads)
 * hoàn tất → copy sang FRONT (dưới mutex) và đánh dấu valid. Front luôn là
 * một geom liền lạc cho render, không bao giờ lộ buffer đang ghi dở.
 *
 * Reassembly:
 *  - ROUTE: fragment nhiều frame cùng seq. frag_idx==0 → reset phần route
 *    của back buffer, ghi anchor+seq+frag_total, nối điểm. Khi nhận frag cuối
 *    (frag_idx==frag_total-1) cho đúng seq → route coi như hoàn tất → swap.
 *  - ROADS: nhiều frame chia sẻ seq, mỗi frame có road_count road bổ sung.
 *    seq mới → reset phần roads của back buffer. Mỗi frame nhận xong coi như
 *    bộ roads hiện tại (additive) hoàn chỉnh → swap. ESP32 chỉ giữ seq mới nhất.
 */
#include "map_model.h"

#include <string.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#include "nus_protocol.h"

#define MAP_TAG "MAP_MODEL"

/* ── Pose mới nhất (atomic copy dưới mutex) ──────────────────────────── */
static map_pose_t        s_pose;
static bool              s_has_pose;

/* ── Double buffer geom ──────────────────────────────────────────────── */
static map_geom_t        s_front;   /* dùng để render (valid) */
static map_geom_t        s_back;    /* đang reassembly */
static SemaphoreHandle_t s_mutex;

/* Theo dõi tiến trình reassembly trên BACK buffer. */
static uint8_t  s_route_seq;        /* seq route đang gom */
static uint8_t  s_route_frag_total;
static uint8_t  s_route_next_frag;  /* frag_idx kỳ vọng kế tiếp */
static bool     s_route_active;     /* đang gom 1 bộ route */
static bool     s_back_route_ready; /* back buffer đã có route hoàn tất */

static uint8_t  s_roads_seq;        /* seq roads đang gom */
static bool     s_roads_active;
static bool     s_back_roads_ready;

static void map_lock(void)
{
    if (s_mutex) {
        xSemaphoreTake(s_mutex, portMAX_DELAY);
    }
}

static void map_unlock(void)
{
    if (s_mutex) {
        xSemaphoreGive(s_mutex);
    }
}

/* Copy back → front dưới mutex; giữ phần kia (route/roads) đã có. */
static void map_swap_to_front(void)
{
    map_lock();
    s_front       = s_back;
    s_front.valid = true;
    map_unlock();
}

/* ── 0x30 MAP_POSE ────────────────────────────────────────────────────
 * lat i32 | lng i32 | heading u16 | speed u8 | flags u8 → 12 byte. */
static void map_on_pose(uint8_t type, const uint8_t *p, uint16_t len, void *ctx)
{
    (void)type;
    (void)ctx;
    if (len < 12) {
        ESP_LOGW(MAP_TAG, "MAP_POSE too short (%u)", len);
        return;
    }

    map_pose_t pose;
    pose.lat_e7       = le_i32(&p[0]);
    pose.lng_e7       = le_i32(&p[4]);
    pose.heading_ddeg = le_u16(&p[8]);
    pose.speed_kmh    = p[10];
    pose.flags        = p[11];

    map_lock();
    s_pose     = pose;
    s_has_pose = true;
    map_unlock();
}

/* ── 0x31 MAP_ROUTE ───────────────────────────────────────────────────
 * header (13B): anchor_lat i32 | anchor_lng i32 | seq u8 | frag_idx u8 |
 * frag_total u8 | n u16; rồi n×{east i16, north i16} (dm). */
static void map_on_route(uint8_t type, const uint8_t *p, uint16_t len, void *ctx)
{
    (void)type;
    (void)ctx;
    if (len < 13) {
        ESP_LOGW(MAP_TAG, "MAP_ROUTE header too short (%u)", len);
        return;
    }

    int32_t  anchor_lat = le_i32(&p[0]);
    int32_t  anchor_lng = le_i32(&p[4]);
    uint8_t  seq        = p[8];
    uint8_t  frag_idx   = p[9];
    uint8_t  frag_total = p[10];
    uint16_t n          = le_u16(&p[11]);

    /* Số điểm thực sự có trong payload (chống OOB / LEN sai). */
    uint16_t avail_pts = (uint16_t)((len - 13) / 4);
    if (n > avail_pts) {
        n = avail_pts;
    }

    if (frag_total == 0) {
        ESP_LOGW(MAP_TAG, "MAP_ROUTE frag_total=0");
        return;
    }

    if (frag_idx == 0) {
        /* Bắt đầu bộ route mới → reset phần route của back buffer. */
        s_back.anchor_lat_e7 = anchor_lat;
        s_back.anchor_lng_e7 = anchor_lng;
        s_back.route_n       = 0;
        s_route_seq          = seq;
        s_route_frag_total   = frag_total;
        s_route_next_frag    = 0;
        s_route_active       = true;
    }

    /* Bỏ frag lạc seq hoặc lệch thứ tự (đơn giản, robust). */
    if (!s_route_active || seq != s_route_seq || frag_idx != s_route_next_frag) {
        ESP_LOGW(MAP_TAG, "MAP_ROUTE frag out of order (seq %u idx %u)", seq, frag_idx);
        s_route_active = false;
        return;
    }

    /* Nối điểm vào back buffer (tôn trọng giới hạn). */
    const uint8_t *pt = &p[13];
    for (uint16_t i = 0; i < n; i++) {
        if (s_back.route_n >= MAP_MAX_ROUTE_PTS) {
            break; /* overflow → drop phần thừa */
        }
        s_back.route[s_back.route_n].e_dm = le_i16(&pt[i * 4 + 0]);
        s_back.route[s_back.route_n].n_dm = le_i16(&pt[i * 4 + 2]);
        s_back.route_n++;
    }

    s_route_next_frag++;

    /* Đủ frag cuối cùng → route hoàn tất → swap sang front. */
    if (frag_idx == (uint8_t)(frag_total - 1)) {
        s_back_route_ready = true;
        s_route_active     = false;
        map_swap_to_front();
        ESP_LOGI(MAP_TAG, "route ready: %u pts", s_back.route_n);
    }
}

/* ── 0x32 MAP_ROADS ───────────────────────────────────────────────────
 * header (10B): anchor_lat i32 | anchor_lng i32 | seq u8 | road_count u8;
 * rồi mỗi road: class u8 | pt_count u8 | pt_count×{east i16, north i16}. */
static void map_on_roads(uint8_t type, const uint8_t *p, uint16_t len, void *ctx)
{
    (void)type;
    (void)ctx;
    if (len < 10) {
        ESP_LOGW(MAP_TAG, "MAP_ROADS header too short (%u)", len);
        return;
    }

    int32_t anchor_lat = le_i32(&p[0]);
    int32_t anchor_lng = le_i32(&p[4]);
    uint8_t seq        = p[8];
    uint8_t road_count = p[9];

    if (!s_roads_active || seq != s_roads_seq) {
        /* seq mới → reset phần roads của back buffer (chỉ giữ seq mới nhất). */
        s_back.road_n        = 0;
        s_back.anchor_lat_e7 = anchor_lat;
        s_back.anchor_lng_e7 = anchor_lng;
        s_roads_seq          = seq;
        s_roads_active       = true;
    }

    uint16_t off = 10;
    for (uint8_t r = 0; r < road_count; r++) {
        if ((uint16_t)(off + 2) > len) {
            break; /* không đủ cho header road → dừng */
        }
        uint8_t cls      = p[off];
        uint8_t pt_count = p[off + 1];
        off += 2;

        uint16_t need = (uint16_t)pt_count * 4;
        if ((uint16_t)(off + need) > len) {
            /* payload thiếu → cắt theo số byte còn lại */
            pt_count = (uint8_t)((len - off) / 4);
            need     = (uint16_t)pt_count * 4;
        }

        if (s_back.road_n < MAP_MAX_ROADS) {
            map_road_t *rd = &s_back.roads[s_back.road_n];
            rd->road_class = cls;
            rd->n          = 0;
            for (uint8_t i = 0; i < pt_count; i++) {
                if (rd->n >= MAP_MAX_ROAD_PTS) {
                    break;
                }
                rd->pts[rd->n].e_dm = le_i16(&p[off + i * 4 + 0]);
                rd->pts[rd->n].n_dm = le_i16(&p[off + i * 4 + 2]);
                rd->n++;
            }
            s_back.road_n++;
        }
        off += need;
    }

    /* Mỗi frame roads coi như bộ hiện tại đã liền lạc → swap. */
    s_back_roads_ready = true;
    map_swap_to_front();
    ESP_LOGI(MAP_TAG, "roads updated: %u roads (seq %u)", s_back.road_n, seq);
}

void map_model_init(void)
{
    if (s_mutex == NULL) {
        s_mutex = xSemaphoreCreateMutex();
    }
    /* Không xoá s_front: main.c có thể đã nạp từ cache trước init. */
    memset(&s_back, 0, sizeof(s_back));
    s_route_active     = false;
    s_roads_active     = false;
    s_back_route_ready = false;
    s_back_roads_ready = false;

    nus_protocol_register(MSG_MAP_POSE,  map_on_pose,  NULL);
    nus_protocol_register(MSG_MAP_ROUTE, map_on_route, NULL);
    nus_protocol_register(MSG_MAP_ROADS, map_on_roads, NULL);

    ESP_LOGI(MAP_TAG, "init");
}

void map_model_get_pose(map_pose_t *out)
{
    if (out == NULL) {
        return;
    }
    map_lock();
    *out = s_pose;
    map_unlock();
}

bool map_model_has_pose(void)
{
    map_lock();
    bool has = s_has_pose;
    map_unlock();
    return has;
}

const map_geom_t *map_model_lock_geom(void)
{
    map_lock();
    if (!s_front.valid) {
        map_unlock();
        return NULL;
    }
    /* Giữ mutex; caller phải gọi unlock. */
    return &s_front;
}

void map_model_unlock_geom(void)
{
    map_unlock();
}

void map_model_set_geom(const map_geom_t *g)
{
    if (g == NULL) {
        return;
    }
    map_lock();
    s_front       = *g;
    s_front.valid = true;
    /* Đồng bộ back để reassembly kế tiếp dựa trên anchor hiện có. */
    s_back        = s_front;
    map_unlock();
}
