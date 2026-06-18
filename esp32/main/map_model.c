/*
 * map_model.c — State bản đồ HUD: pose (0x30) + route (0x31) + roads (0x32).
 *
 * Double-buffer: s_back tích luỹ frames; khi hoàn tất → copy s_back → s_front
 * dưới mutex. Mutex chỉ giữ trong lúc copy (~8 KB); LVGL task copy s_front ra
 * s_render_geom (display.c) rồi thả mutex ngay, tránh block BLE task.
 */
#include "map_model.h"

#include <string.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#include "nus_protocol.h"

#define MAP_TAG "MAP_MODEL"

static map_pose_t        s_pose;
static bool              s_has_pose;

static map_geom_t        s_front;
static map_geom_t        s_back;
static SemaphoreHandle_t s_mutex;

static uint8_t  s_route_seq;
static uint8_t  s_route_frag_total;
static uint8_t  s_route_next_frag;
static bool     s_route_active;
static bool     s_back_route_ready;

static uint8_t  s_roads_seq;
static bool     s_roads_active;
static bool     s_back_roads_ready;

static void map_lock(void)   { if (s_mutex) xSemaphoreTake(s_mutex, portMAX_DELAY); }
static void map_unlock(void) { if (s_mutex) xSemaphoreGive(s_mutex); }

static void map_swap_to_front(void)
{
    map_lock();
    s_front       = s_back;   /* copy ~8 KB; mutex held brevemente */
    s_front.valid = true;
    map_unlock();
}

#define MAP_DEFAULT_VIEW_SPAN_DM 2000

static void map_on_pose(uint8_t type, const uint8_t *p, uint16_t len, void *ctx)
{
    (void)type; (void)ctx;
    if (len < 12) { ESP_LOGW(MAP_TAG, "MAP_POSE too short (%u)", len); return; }

    map_pose_t pose;
    pose.lat_e7       = le_i32(&p[0]);
    pose.lng_e7       = le_i32(&p[4]);
    pose.heading_ddeg = le_u16(&p[8]);
    pose.speed_kmh    = p[10];
    pose.flags        = p[11];
    pose.view_span_dm = (len >= 14) ? le_u16(&p[12]) : MAP_DEFAULT_VIEW_SPAN_DM;
    if (pose.view_span_dm == 0) pose.view_span_dm = MAP_DEFAULT_VIEW_SPAN_DM;
    pose.received_us  = esp_timer_get_time();

    map_lock();
    s_pose     = pose;
    s_has_pose = true;
    map_unlock();
}

static void map_on_route(uint8_t type, const uint8_t *p, uint16_t len, void *ctx)
{
    (void)type; (void)ctx;
    if (len < 13) { ESP_LOGW(MAP_TAG, "MAP_ROUTE too short (%u)", len); return; }

    int32_t  anchor_lat = le_i32(&p[0]);
    int32_t  anchor_lng = le_i32(&p[4]);
    uint8_t  seq        = p[8];
    uint8_t  frag_idx   = p[9];
    uint8_t  frag_total = p[10];
    uint16_t n          = le_u16(&p[11]);

    uint16_t avail = (uint16_t)((len - 13) / 4);
    if (n > avail) n = avail;
    if (frag_total == 0) return;

    if (frag_idx == 0) {
        /* Anchor thay đổi (resend sau ~800 m di chuyển): roads cũ không còn
         * hợp lệ với anchor mới → xoá để tránh hiển thị roads lệch 800 m
         * trong khoảng trống giữa MAP_ROUTE hoàn thành và MAP_ROADS đến. */
        bool anchor_changed = (seq != s_route_seq);
        if (anchor_changed) s_back.road_n = 0;
        s_back.anchor_lat_e7 = anchor_lat;
        s_back.anchor_lng_e7 = anchor_lng;
        s_back.route_n       = 0;
        s_route_seq          = seq;
        s_route_frag_total   = frag_total;
        s_route_next_frag    = 0;
        s_route_active       = true;
        ESP_LOGI(MAP_TAG, "route seq=%u frags=%u anchor=(%ld,%ld)%s",
                 seq, frag_total, anchor_lat, anchor_lng,
                 anchor_changed ? " [anchor→reset roads]" : "");
    }

    if (!s_route_active || seq != s_route_seq || frag_idx != s_route_next_frag) {
        ESP_LOGW(MAP_TAG, "route frag OOO seq=%u idx=%u", seq, frag_idx);
        s_route_active = false;
        return;
    }

    const uint8_t *pt = &p[13];
    for (uint16_t i = 0; i < n && s_back.route_n < MAP_MAX_ROUTE_PTS; i++) {
        s_back.route[s_back.route_n].e_dm = le_i16(&pt[i * 4 + 0]);
        s_back.route[s_back.route_n].n_dm = le_i16(&pt[i * 4 + 2]);
        s_back.route_n++;
    }
    s_route_next_frag++;

    if (frag_idx == (uint8_t)(frag_total - 1)) {
        s_back_route_ready = true;
        s_route_active     = false;
        map_swap_to_front();
        ESP_LOGI(MAP_TAG, "route ready: %u pts", s_back.route_n);
    }
}

static void map_on_roads(uint8_t type, const uint8_t *p, uint16_t len, void *ctx)
{
    (void)type; (void)ctx;
    if (len < 10) { ESP_LOGW(MAP_TAG, "MAP_ROADS too short (%u)", len); return; }

    int32_t anchor_lat = le_i32(&p[0]);
    int32_t anchor_lng = le_i32(&p[4]);
    uint8_t seq        = p[8];
    uint8_t road_count = p[9];

    if (!s_roads_active || seq != s_roads_seq) {
        s_back.road_n        = 0;
        s_back.anchor_lat_e7 = anchor_lat;
        s_back.anchor_lng_e7 = anchor_lng;
        s_roads_seq          = seq;
        s_roads_active       = true;
    }

    uint16_t off = 10;
    for (uint8_t r = 0; r < road_count; r++) {
        if ((uint16_t)(off + 2) > len) break;
        uint8_t cls      = p[off];
        uint8_t pt_count = p[off + 1];
        off += 2;

        uint16_t need = (uint16_t)pt_count * 4;
        if ((uint16_t)(off + need) > len) {
            pt_count = (uint8_t)((len - off) / 4);
            need     = (uint16_t)pt_count * 4;
        }
        if (s_back.road_n < MAP_MAX_ROADS) {
            map_road_t *rd = &s_back.roads[s_back.road_n];
            rd->road_class = cls;
            rd->n          = 0;
            for (uint8_t i = 0; i < pt_count && rd->n < MAP_MAX_ROAD_PTS; i++) {
                rd->pts[rd->n].e_dm = le_i16(&p[off + i * 4 + 0]);
                rd->pts[rd->n].n_dm = le_i16(&p[off + i * 4 + 2]);
                rd->n++;
            }
            s_back.road_n++;
        }
        off += need;
    }

    s_back_roads_ready = true;
    map_swap_to_front();
    ESP_LOGI(MAP_TAG, "roads frame: road_n=%u (seq=%u frame had %u roads)", s_back.road_n, seq, road_count);
}

void map_model_init(void)
{
    if (!s_mutex) s_mutex = xSemaphoreCreateMutex();
    memset(&s_back, 0, sizeof(s_back));
    s_route_active = s_roads_active = false;
    s_back_route_ready = s_back_roads_ready = false;

    nus_protocol_register(MSG_MAP_POSE,  map_on_pose,  NULL);
    nus_protocol_register(MSG_MAP_ROUTE, map_on_route, NULL);
    nus_protocol_register(MSG_MAP_ROADS, map_on_roads, NULL);
    ESP_LOGI(MAP_TAG, "init");
}

void map_model_get_pose(map_pose_t *out)
{
    if (!out) return;
    map_lock(); *out = s_pose; map_unlock();
}

bool map_model_has_pose(void)
{
    map_lock(); bool h = s_has_pose; map_unlock(); return h;
}

/* Timeout 10 ms: BLE task hiếm khi giữ mutex (chỉ trong map_swap_to_front
 * ~8 KB copy). Trả NULL → LVGL bỏ qua 1 frame thay vì treo. */
const map_geom_t *map_model_lock_geom(void)
{
    if (!s_mutex) return NULL;
    if (xSemaphoreTake(s_mutex, pdMS_TO_TICKS(10)) != pdTRUE) return NULL;
    if (!s_front.valid) { xSemaphoreGive(s_mutex); return NULL; }
    return &s_front;
}

void map_model_unlock_geom(void) { map_unlock(); }

void map_model_set_geom(const map_geom_t *g)
{
    if (!g) return;
    map_lock();
    s_front = *g; s_front.valid = true;
    s_back  = s_front;
    map_unlock();
}
