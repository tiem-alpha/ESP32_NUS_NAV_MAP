/*
 * nav_model.c — State overlay dẫn đường (TYPE 0x10–0x14).
 *
 * Đăng ký handler với nus_protocol; parse payload theo §6.2/§6.3 vào một
 * nav_overlay_t tĩnh (bảo vệ bằng mutex). Display đọc snapshot thread-safe.
 */
#include "nav_model.h"

#include <string.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#include "nus_protocol.h"

#define NAV_TAG "NAV_MODEL"

static nav_overlay_t     s_overlay;
static SemaphoreHandle_t s_mutex;

static void nav_lock(void)
{
    if (s_mutex) {
        xSemaphoreTake(s_mutex, portMAX_DELAY);
    }
}

static void nav_unlock(void)
{
    if (s_mutex) {
        xSemaphoreGive(s_mutex);
    }
}

/* ── 0x10 NAV_INSTRUCTION ─────────────────────────────────────────────
 * seq u8 | maneuver u8 | distance_m u16 | exit_number u8 | name_len u8 |
 * street_name[name_len] UTF-8
 * → tối thiểu 6 byte header. */
static void nav_on_instruction(uint8_t type, const uint8_t *p, uint16_t len, void *ctx)
{
    (void)type;
    (void)ctx;
    if (len < 6) {
        ESP_LOGW(NAV_TAG, "INSTRUCTION too short (%u)", len);
        return;
    }

    uint8_t  seq         = p[0];
    uint8_t  maneuver    = p[1];
    uint16_t distance_m  = le_u16(&p[2]);
    uint8_t  exit_number = p[4];
    uint8_t  name_len    = p[5];

    /* name_len phải vừa trong payload. */
    if ((uint16_t)(6 + name_len) > len) {
        name_len = (uint8_t)(len - 6);
    }

    nav_lock();
    s_overlay.has_instruction = true;
    s_overlay.instr_seq       = seq;
    s_overlay.maneuver        = (maneuver_e)maneuver;
    s_overlay.dist_to_man_m   = distance_m;
    s_overlay.exit_number     = exit_number;

    uint8_t copy = name_len;
    if (copy > NAV_STREET_MAX - 1) {
        copy = NAV_STREET_MAX - 1;
    }
    if (copy > 0) {
        memcpy(s_overlay.street, &p[6], copy);
    }
    s_overlay.street[copy] = '\0';
    nav_unlock();
}

/* ── 0x11 DISTANCE_TICK ───────────────────────────────────────────────
 * dist_to_man u16 | dist_remain u32 | eta u16 (min) | speed u8 → 9 byte. */
static void nav_on_distance_tick(uint8_t type, const uint8_t *p, uint16_t len, void *ctx)
{
    (void)type;
    (void)ctx;
    if (len < 9) {
        ESP_LOGW(NAV_TAG, "DISTANCE_TICK too short (%u)", len);
        return;
    }

    nav_lock();
    s_overlay.dist_to_man_m = le_u16(&p[0]);
    s_overlay.dist_remain_m = le_u32(&p[2]);
    s_overlay.eta_min       = le_u16(&p[6]);
    s_overlay.speed_kmh     = p[8];
    nav_unlock();
}

/* ── 0x12 SPEED_LIMIT ─────────────────────────────────────────────────
 * limit u8 | is_over u8 → 2 byte. */
static void nav_on_speed_limit(uint8_t type, const uint8_t *p, uint16_t len, void *ctx)
{
    (void)type;
    (void)ctx;
    if (len < 2) {
        ESP_LOGW(NAV_TAG, "SPEED_LIMIT too short (%u)", len);
        return;
    }

    nav_lock();
    s_overlay.speed_limit_kmh = p[0];
    s_overlay.is_over         = (p[1] != 0);
    nav_unlock();
}

/* ── 0x13 TRAFFIC_SIGN ────────────────────────────────────────────────
 * sign_type u8 | dist u16 | value u8 → 4 byte. */
static void nav_on_traffic_sign(uint8_t type, const uint8_t *p, uint16_t len, void *ctx)
{
    (void)type;
    (void)ctx;
    if (len < 4) {
        ESP_LOGW(NAV_TAG, "TRAFFIC_SIGN too short (%u)", len);
        return;
    }

    nav_lock();
    s_overlay.has_sign    = true;
    s_overlay.sign        = (sign_type_e)p[0];
    s_overlay.sign_dist_m = le_u16(&p[1]);
    s_overlay.sign_value  = p[3];
    nav_unlock();
}

/* ── 0x14 NAV_STATE ───────────────────────────────────────────────────
 * state u8 → 1 byte. */
static void nav_on_state(uint8_t type, const uint8_t *p, uint16_t len, void *ctx)
{
    (void)type;
    (void)ctx;
    if (len < 1) {
        ESP_LOGW(NAV_TAG, "NAV_STATE too short (%u)", len);
        return;
    }

    nav_lock();
    s_overlay.state = (nav_state_e)p[0];
    nav_unlock();
}

void nav_model_init(void)
{
    if (s_mutex == NULL) {
        s_mutex = xSemaphoreCreateMutex();
    }
    memset(&s_overlay, 0, sizeof(s_overlay));

    nus_protocol_register(MSG_NAV_INSTRUCTION, nav_on_instruction, NULL);
    nus_protocol_register(MSG_DISTANCE_TICK,   nav_on_distance_tick, NULL);
    nus_protocol_register(MSG_SPEED_LIMIT,     nav_on_speed_limit, NULL);
    nus_protocol_register(MSG_TRAFFIC_SIGN,    nav_on_traffic_sign, NULL);
    nus_protocol_register(MSG_NAV_STATE,       nav_on_state, NULL);

    ESP_LOGI(NAV_TAG, "init");
}

void nav_model_get(nav_overlay_t *out)
{
    if (out == NULL) {
        return;
    }
    nav_lock();
    *out = s_overlay;
    nav_unlock();
}

void nav_model_reset(void)
{
    nav_lock();
    memset(&s_overlay, 0, sizeof(s_overlay));
    nav_unlock();
}
