/*
 * map_model.c — State bản đồ HUD: pose (0x30) + route (0x31) + roads (0x32).
 *
 * Double-buffer: s_back tích luỹ frames; khi hoàn tất → copy s_back → s_front
 * dưới mutex. Mutex chỉ giữ trong lúc copy (~8 KB); LVGL task copy s_front ra
 * s_render_geom (display.c) rồi thả mutex ngay, tránh block BLE task.
 */
#include "map_model.h"

#include <math.h>
#include <string.h>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "sdkconfig.h"

#include "nus_protocol.h"

#define MAP_TAG "MAP_MODEL"

static map_pose_t        s_pose;
static bool              s_has_pose;

/* ESP32-H2 (không PSRAM): static .bss — ~8 KB/buffer, fit trong 84 KB heap còn lại.
 * ESP32-S3 + PSRAM: cấp động từ PSRAM — ~64 KB/buffer (MAP_MAX_ROADS=256 ×
 * MAP_MAX_ROAD_PTS=60); giải phóng toàn bộ internal SRAM cho Bluedroid + LVGL. */
#ifdef CONFIG_SPIRAM
  static map_geom_t       *s_front_p;
  static map_geom_t       *s_back_p;
  #define s_front  (*s_front_p)
  #define s_back   (*s_back_p)
#else
  static map_geom_t        s_front;
  static map_geom_t        s_back;
#endif

static SemaphoreHandle_t s_mutex;

static uint8_t  s_route_seq;
static uint8_t  s_route_frag_total;
static uint8_t  s_route_next_frag;
static bool     s_route_active;

static uint8_t  s_roads_seq;
static uint8_t  s_roads_frag_total;
static uint8_t  s_roads_next_frag;
static bool     s_roads_active;

static void map_lock(void)   { if (s_mutex) xSemaphoreTake(s_mutex, portMAX_DELAY); }
static void map_unlock(void) { if (s_mutex) xSemaphoreGive(s_mutex); }

static void map_swap_to_front(void)
{
    map_lock();
    s_front       = s_back;   /* copy ~8 KB; mutex held brevemente */
    s_front.valid = true;
    map_unlock();
}

/* Mỗi batch route/roads được dựng từ snapshot ĐÃ COMMIT gần nhất. Nếu một batch
 * cũ bị thay giữa chừng, dữ liệu nửa vời trong back buffer không được phép lọt
 * vào lần commit kế tiếp. Front vẫn được render nguyên vẹn trong lúc BLE nhận. */
static void map_prepare_back_from_front(void)
{
    map_lock();
    if (s_front.valid) {
        s_back = s_front;
    } else {
        memset(&s_back, 0, sizeof(s_back));
    }
    map_unlock();
}

/* Đổi hệ tọa độ route từ anchor hiện tại sang anchor mới. MAP_ROUTE và
 * MAP_ROADS là hai message độc lập; nếu pose dịch chuyển giữa hai lần encode,
 * roads có thể mang anchor mới hơn. Không rebase route sẽ làm toàn bộ tuyến
 * lệch vài mét, thậm chí ra khỏi viewport ở zoom gần. */
static void map_rebase_route_to(int32_t anchor_lat, int32_t anchor_lng)
{
    if (s_back.route_n == 0 || s_back.anchor_lat_e7 == 0) return;

    int32_t dlat_e7 = anchor_lat - s_back.anchor_lat_e7;
    int32_t dlng_e7 = anchor_lng - s_back.anchor_lng_e7;
    if (dlat_e7 == 0 && dlng_e7 == 0) return;

    float lat_rad = (float)s_back.anchor_lat_e7 * 1e-7f
                    * (float)M_PI / 180.0f;
    float cos_lat = cosf(lat_rad);
    int32_t dn = (int32_t)lroundf(
        (float)dlat_e7 * 1e-7f * 111320.0f * 10.0f);
    int32_t de = (int32_t)lroundf(
        (float)dlng_e7 * 1e-7f * 111320.0f * cos_lat * 10.0f);

    ESP_LOGI(MAP_TAG,
             "rebase route: pts=%u de=%ld dm dn=%ld dm old=(%ld,%ld) new=(%ld,%ld)",
             s_back.route_n, (long)de, (long)dn,
             s_back.anchor_lat_e7, s_back.anchor_lng_e7,
             anchor_lat, anchor_lng);

    for (uint16_t i = 0; i < s_back.route_n; i++) {
        int32_t e = (int32_t)s_back.route[i].e_dm - de;
        int32_t n = (int32_t)s_back.route[i].n_dm - dn;
        if (e < INT16_MIN) e = INT16_MIN; else if (e > INT16_MAX) e = INT16_MAX;
        if (n < INT16_MIN) n = INT16_MIN; else if (n > INT16_MAX) n = INT16_MAX;
        s_back.route[i].e_dm = (int16_t)e;
        s_back.route[i].n_dm = (int16_t)n;
    }
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
        map_prepare_back_from_front();
        s_roads_active = false; /* bỏ batch roads nửa chừng, front vẫn còn nguyên */
        /* Re-encode road points từ roads_anchor cũ sang route_anchor mới.
         * s_back.anchor_* hiện giữ roads_anchor (từ map_on_roads cuối).
         * Nếu không re-encode: roads lệch ~8–15m trong khoảng trống BLE giữa
         * MAP_ROUTE xong và MAP_ROADS đến, gây nháy. Phép tính O(road_n×pt_n)
         * int16 ở đây — không tốn thêm RAM, không chạy trong hot render path. */
        if (s_back.road_n > 0 && s_back.anchor_lat_e7 != 0) {
            int32_t dlat_e7 = anchor_lat - s_back.anchor_lat_e7;
            int32_t dlng_e7 = anchor_lng - s_back.anchor_lng_e7;
            if (dlat_e7 != 0 || dlng_e7 != 0) {
                float lat_rad = (float)s_back.anchor_lat_e7 * 1e-7f
                                * (float)M_PI / 180.0f;
                float cos_lat = cosf(lat_rad);
                int32_t dn = (int32_t)lroundf(
                    (float)dlat_e7 * 1e-7f * 111320.0f * 10.0f);
                int32_t de = (int32_t)lroundf(
                    (float)dlng_e7 * 1e-7f * 111320.0f * cos_lat * 10.0f);
                for (uint16_t i = 0; i < s_back.road_pt_n; i++) {
                    int32_t e = (int32_t)s_back.road_pts[i].e_dm - de;
                    int32_t n = (int32_t)s_back.road_pts[i].n_dm - dn;
                    if (e < INT16_MIN) e = INT16_MIN; else if (e > INT16_MAX) e = INT16_MAX;
                    if (n < INT16_MIN) n = INT16_MIN; else if (n > INT16_MAX) n = INT16_MAX;
                    s_back.road_pts[i].e_dm = (int16_t)e;
                    s_back.road_pts[i].n_dm = (int16_t)n;
                }
            }
        }
        s_back.anchor_lat_e7 = anchor_lat;
        s_back.anchor_lng_e7 = anchor_lng;
        s_back.route_n       = 0;
        s_route_seq          = seq;
        s_route_frag_total   = frag_total;
        s_route_next_frag    = 0;
        s_route_active       = true;
        ESP_LOGI(MAP_TAG, "route seq=%u frags=%u anchor=(%ld,%ld)",
                 seq, frag_total, anchor_lat, anchor_lng);
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
        s_route_active     = false;
        map_swap_to_front();
        ESP_LOGI(MAP_TAG,
                 "route ready: seq=%u pts=%u roads=%u anchor=(%ld,%ld)",
                 seq, s_back.route_n, s_back.road_n,
                 s_back.anchor_lat_e7, s_back.anchor_lng_e7);
    }
}

static void map_on_roads(uint8_t type, const uint8_t *p, uint16_t len, void *ctx)
{
    (void)type; (void)ctx;
    if (len < 12) { ESP_LOGW(MAP_TAG, "MAP_ROADS too short (%u)", len); return; }

    int32_t anchor_lat = le_i32(&p[0]);
    int32_t anchor_lng = le_i32(&p[4]);
    uint8_t seq        = p[8];
    uint8_t frag_idx   = p[9];
    uint8_t frag_total = p[10];
    uint8_t road_count = p[11];

    if (frag_total == 0) return;

    if (frag_idx == 0) {
        map_prepare_back_from_front();
        s_route_active = false; /* bỏ batch route nửa chừng, front vẫn còn nguyên */
        map_rebase_route_to(anchor_lat, anchor_lng);
        s_back.road_n        = 0;
        s_back.road_pt_n     = 0;
        s_back.anchor_lat_e7 = anchor_lat;
        s_back.anchor_lng_e7 = anchor_lng;
        s_roads_seq          = seq;
        s_roads_frag_total   = frag_total;
        s_roads_next_frag    = 0;
        s_roads_active       = true;
        ESP_LOGI(MAP_TAG, "roads seq=%u frags=%u anchor=(%ld,%ld)",
                 seq, frag_total, anchor_lat, anchor_lng);
    }

    if (!s_roads_active || seq != s_roads_seq ||
        frag_total != s_roads_frag_total || frag_idx != s_roads_next_frag) {
        ESP_LOGW(MAP_TAG, "roads frag OOO seq=%u idx=%u/%u expected=%u",
                 seq, frag_idx, frag_total, s_roads_next_frag);
        s_roads_active = false;
        return;
    }

    uint16_t off = 12;
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
        uint16_t room = MAP_MAX_ROAD_POINTS - s_back.road_pt_n;
        uint8_t store_n = pt_count;
        if (store_n > MAP_MAX_ROAD_PTS) store_n = MAP_MAX_ROAD_PTS;
        if (store_n > room) store_n = (uint8_t)room;
        if (s_back.road_n < MAP_MAX_ROADS && store_n >= 2) {
            map_road_t *rd = &s_back.roads[s_back.road_n];
            rd->road_class = cls;
            rd->first_pt   = s_back.road_pt_n;
            rd->n          = store_n;
            for (uint8_t i = 0; i < store_n; i++) {
                s_back.road_pts[s_back.road_pt_n].e_dm = le_i16(&p[off + i * 4 + 0]);
                s_back.road_pts[s_back.road_pt_n].n_dm = le_i16(&p[off + i * 4 + 2]);
                s_back.road_pt_n++;
            }
            s_back.road_n++;
        }
        off += need;
    }

    s_roads_next_frag++;
    ESP_LOGI(MAP_TAG,
             "roads frame: seq=%u frag=%u/%u added=%u total=%u pts=%u route=%u",
             seq, frag_idx + 1, frag_total, road_count, s_back.road_n,
             s_back.road_pt_n, s_back.route_n);

    if (frag_idx == (uint8_t)(frag_total - 1)) {
        s_roads_active = false;
        map_swap_to_front();
        ESP_LOGI(MAP_TAG,
             "roads ready: seq=%u roads=%u pts=%u route=%u anchor=(%ld,%ld)",
             seq, s_back.road_n, s_back.road_pt_n, s_back.route_n,
             s_back.anchor_lat_e7, s_back.anchor_lng_e7);
    }
}

void map_model_init(void)
{
    if (!s_mutex) s_mutex = xSemaphoreCreateMutex();

#ifdef CONFIG_SPIRAM
    if (!s_front_p) {
        s_front_p = heap_caps_malloc(sizeof(map_geom_t), MALLOC_CAP_SPIRAM);
        s_back_p  = heap_caps_malloc(sizeof(map_geom_t), MALLOC_CAP_SPIRAM);
        ESP_LOGI(MAP_TAG, "geom buffers in PSRAM: 2 × %u B", (unsigned)sizeof(map_geom_t));
    }
    assert(s_front_p && s_back_p);
    memset(s_front_p, 0, sizeof(map_geom_t));
    memset(s_back_p,  0, sizeof(map_geom_t));
#else
    memset(&s_back, 0, sizeof(s_back));
#endif

    s_route_active = s_roads_active = false;

    nus_protocol_register(MSG_MAP_POSE,  map_on_pose,  NULL);
    nus_protocol_register(MSG_MAP_ROUTE, map_on_route, NULL);
    nus_protocol_register(MSG_MAP_ROADS, map_on_roads, NULL);
    ESP_LOGI(MAP_TAG, "init geom=%u B max_roads=%u road_points=%u route_points=%u",
             (unsigned)sizeof(map_geom_t), (unsigned)MAP_MAX_ROADS,
             (unsigned)MAP_MAX_ROAD_POINTS, (unsigned)MAP_MAX_ROUTE_PTS);
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
