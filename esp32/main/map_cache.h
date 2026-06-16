/*
 * map_cache.h — Lưu/nạp bộ geom map gần nhất ra SPIFFS (partition "spiffs"),
 * để khôi phục nhanh sau reboot trong lúc chờ app gửi lại.
 */
#pragma once

#include "esp_err.h"
#include "map_model.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t map_cache_init(void);                 /* mount SPIFFS (/spiffs) */
esp_err_t map_cache_save(const map_geom_t *g);  /* ghi /spiffs/map.bin */
esp_err_t map_cache_load(map_geom_t *g);        /* đọc lại; ESP_ERR_NOT_FOUND nếu chưa có */

#ifdef __cplusplus
}
#endif
