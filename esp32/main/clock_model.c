/*
 * clock_model.c — Parse MAP_CLOCK (0x33): epoch_s u32 (UTC) | tz_offset_min i16
 * → 6 byte. Lưu mốc sync + thời điểm monotonic tương ứng; suy ra giờ:phút địa
 * phương hiện tại bằng cách cộng thêm thời gian trôi từ lúc sync.
 */
#include "clock_model.h"

#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#include "nav_proto.h"
#include "nus_protocol.h"

static SemaphoreHandle_t s_mutex;
static bool    s_valid       = false;
static int64_t s_synced_us;       /* esp_timer_get_time() lúc sync */
static int64_t s_epoch_local_s;   /* epoch_s + tz_offset_min*60 lúc sync */

/* display_init() dựng UI + chạy lvgl_task TRƯỚC khi clock_model_init() được
 * gọi trong app_main (display lên sớm để báo trạng thái) — overlay_update()
 * có thể gọi clock_model_get_local() khi s_mutex còn NULL. Phải guard, không
 * thì xSemaphoreTake(NULL) trip configASSERT (xQueueSemaphoreTake) → reboot loop. */
static void clock_lock(void)
{
    if (s_mutex) {
        xSemaphoreTake(s_mutex, portMAX_DELAY);
    }
}

static void clock_unlock(void)
{
    if (s_mutex) {
        xSemaphoreGive(s_mutex);
    }
}

static void clock_on_msg(uint8_t type, const uint8_t *p, uint16_t len, void *ctx)
{
    (void)type;
    (void)ctx;
    if (len < 6) {
        return;
    }

    uint32_t epoch_s      = le_u32(&p[0]);
    int16_t  tz_offset_min = le_i16(&p[4]);

    clock_lock();
    s_epoch_local_s = (int64_t)epoch_s + (int64_t)tz_offset_min * 60;
    s_synced_us     = esp_timer_get_time();
    s_valid         = true;
    clock_unlock();
}

void clock_model_init(void)
{
    if (s_mutex == NULL) {
        s_mutex = xSemaphoreCreateMutex();
    }
    nus_protocol_register(MSG_MAP_CLOCK, clock_on_msg, NULL);
}

bool clock_model_get_local(uint8_t *out_h, uint8_t *out_m)
{
    clock_lock();
    bool valid = s_valid;
    int64_t now_local_s = 0;
    if (valid) {
        int64_t elapsed_s = (esp_timer_get_time() - s_synced_us) / 1000000;
        now_local_s = s_epoch_local_s + elapsed_s;
    }
    clock_unlock();

    if (!valid) {
        return false;
    }
    int64_t secs_of_day = now_local_s % 86400;
    if (secs_of_day < 0) {
        secs_of_day += 86400;
    }
    *out_h = (uint8_t)(secs_of_day / 3600);
    *out_m = (uint8_t)((secs_of_day % 3600) / 60);
    return true;
}
