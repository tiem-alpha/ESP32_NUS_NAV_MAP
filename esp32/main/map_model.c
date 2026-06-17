/*
 * map_model.c — State bản đồ HUD: pose (0x30) + route (0x31) + roads (0x32).
 *
 * Hình học north-up, offset decimet i16 so với anchor tuyệt đối.
 * Double-buffer: ghi BACK buffer theo seq/frag; khi 1 bộ (route hoặc roads)
 * hoàn tất → swap CON TRỎ (O(1), không copy struct) sang FRONT dưới mutex.
 * Front luôn là một geom liền lạc cho render, không bao giờ lộ buffer đang
 * ghi dở. Swap con trỏ giữ mutex chỉ vài micro-giây thay vì copy ~11 KB →
 * giảm tắc BLE task khi LVGL đang render.
 */
#include "map_model.h"

#include <string.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#include "nus_protocol.h"

#define MAP_TAG "MAP_MODEL"

/* ── Pose mới nhất (atomic copy dưới mutex) ──────────────────────────── */
static map_pose_t        s_pose;
static bool              s_has_pose;

/* ── Double buffer geom — pointer-swap, không copy struct ─────────────── */
static map_geom_t        s_buf[2];   /* 2 buffer tĩnh dùng chung */
static map_geom_t       *s_front_p;  /* trỏ vào buffer đang render */
static map_geom_t       *s_back_p;   /* trỏ vào buffer đang reassembly */
static SemaphoreHandle_t s_mutex;

/* Theo dõi tiến trình reassembly trên BACK buffer. */
static uint8_t  s_route_seq;
static uint8_t  s_route_frag_total;
static uint8_t  s_route_next_frag;
static bool     s_route_active;
static bool     s_back_route_ready;

static uint8_t  s_roads_seq;
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

/* Swap con trỏ front ↔ back dưới mutex — O(1), không copy struct. */
static void map_swap_to_front(void)
{
    map_lock();
    map_geom_t *tmp = s_front_p;
    s_front_p        = s_back_p;
    s_front_p->valid = true;
    s_back_p         = tmp;
    /* s_back_p giờ trỏ vào buffer cũ của front; reassembly kế tiếp
     * sẽ reset road_n / route_n trước khi ghi, nên không có race. */
    map_unlock();
}

/* view_span_dm mặc định (200 m) khi phone chưa gửi. */
#define MAP_DEFAULT_VIEW_SPAN_DM 2000

/* ── 0x30 MAP_POSE ────────────────────────────────────────────────────── */
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
    pose.view_span_dm = (len >= 14) ? le_u16(&p[12]) : MAP_DEFAULT_VIEW_SPAN_DM;
    if (pose.view_span_dm == 0) {
        pose.view_span_dm = MAP_DEFAULT_VIEW_SPAN_DM;
    }
    pose.received_us = esp_timer_get_time();

    map_lock();
    s_pose     = pose;
    s_has_pose = true;
    map_unlock();
}

/* ── 0x31 MAP_ROUTE ───────────────────────────────────────────────────── */
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

    uint16_t avail_pts = (uint16_t)((len - 13) / 4);
    if (n > avail_pts) {
        n = avail_pts;
    }
    if (frag_total == 0) {
        ESP_LOGW(MAP_TAG, "MAP_ROUTE frag_total=0");
        return;
    }

    if (frag_idx == 0) {
        s_back_p->anchor_lat_e7 = anchor_lat;
        s_back_p->anchor_lng_e7 = anchor_lng;
        s_back_p->route_n       = 0;
        s_route_seq             = seq;
        s_route_frag_total      = frag_total;
        s_route_next_frag       = 0;
        s_route_active          = true;
    }

    if (!s_route_active || seq != s_route_seq || frag_idx != s_route_next_frag) {
        ESP_LOGW(MAP_TAG, "MAP_ROUTE frag out of order (seq %u idx %u)", seq, frag_idx);
        s_route_active = false;
        return;
    }

    const uint8_t *pt = &p[13];
    for (uint16_t i = 0; i < n; i++) {
        if (s_back_p->route_n >= MAP_MAX_ROUTE_PTS) {
            break;
        }
        s_back_p->route[s_back_p->route_n].e_dm = le_i16(&pt[i * 4 + 0]);
        s_back_p->route[s_back_p->route_n].n_dm = le_i16(&pt[i * 4 + 2]);
        s_back_p->route_n++;
    }

    s_route_next_frag++;

    if (frag_idx == (uint8_t)(frag_total - 1)) {
        s_back_route_ready = true;
        s_route_active     = false;
        map_swap_to_front();
        ESP_LOGI(MAP_TAG, "route ready: %u pts", s_front_p->route_n);
    }
}

/* ── 0x32 MAP_ROADS ───────────────────────────────────────────────────── */
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
        s_back_p->road_n        = 0;
        s_back_p->anchor_lat_e7 = anchor_lat;
        s_back_p->anchor_lng_e7 = anchor_lng;
        s_roads_seq             = seq;
        s_roads_active          = true;
    }

    uint16_t off = 10;
    for (uint8_t r = 0; r < road_count; r++) {
        if ((uint16_t)(off + 2) > len) {
            break;
        }
        uint8_t cls      = p[off];
        uint8_t pt_count = p[off + 1];
        off += 2;

        uint16_t need = (uint16_t)pt_count * 4;
        if ((uint16_t)(off + need) > len) {
            pt_count = (uint8_t)((len - off) / 4);
            need     = (uint16_t)pt_count * 4;
        }

        if (s_back_p->road_n < MAP_MAX_ROADS) {
            map_road_t *rd = &s_back_p->roads[s_back_p->road_n];
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
            s_back_p->road_n++;
        }
        off += need;
    }

    s_back_roads_ready = true;
    map_swap_to_front();
    ESP_LOGI(MAP_TAG, "roads updated: %u roads (seq %u)", s_front_p->road_n, seq);
}

void map_model_init(void)
{
    if (s_mutex == NULL) {
        s_mutex = xSemaphoreCreateMutex();
    }
    s_front_p = &s_buf[0];
    s_back_p  = &s_buf[1];
    memset(s_buf, 0, sizeof(s_buf));
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
    if (out == NULL) return;
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
    if (!s_mutex) return NULL;
    /* Timeout 10 ms: nếu BLE đang swap (O(1), rất hiếm), chờ tối đa 10 ms.
     * Trả NULL để LVGL bỏ qua 1 frame thay vì treo vô thời hạn. */
    if (xSemaphoreTake(s_mutex, pdMS_TO_TICKS(10)) != pdTRUE) {
        return NULL;
    }
    if (!s_front_p->valid) {
        xSemaphoreGive(s_mutex);
        return NULL;
    }
    return s_front_p;
}

void map_model_unlock_geom(void)
{
    map_unlock();
}

void map_model_set_geom(const map_geom_t *g)
{
    if (g == NULL) return;
    map_lock();
    *s_front_p        = *g;
    s_front_p->valid  = true;
    *s_back_p         = *s_front_p;
    map_unlock();
}
