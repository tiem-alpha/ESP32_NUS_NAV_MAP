/*
 * map_cache.c — Lưu/nạp bộ geom map gần nhất ra SPIFFS (/spiffs/map.bin).
 *
 * Khôi phục nhanh sau reboot trong lúc chờ app gửi lại route/roads.
 * File = header (magic + version + size) + toàn bộ map_geom_t (binary).
 * Ghi tmp rồi rename để giảm rủi ro file hỏng khi mất điện giữa chừng.
 */
#include "map_cache.h"

#include <stdio.h>
#include <string.h>

#include "esp_err.h"
#include "esp_log.h"
#include "esp_spiffs.h"

#define CACHE_TAG  "MAP_CACHE"

#define CACHE_PATH     "/spiffs/map.bin"
#define CACHE_TMP_PATH "/spiffs/map.tmp"
#define CACHE_MAGIC    0x4D504731u  /* "MPG1" */
#define CACHE_VERSION  1u

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t size;   /* sizeof(map_geom_t) lúc ghi — phát hiện đổi layout */
} cache_header_t;

esp_err_t map_cache_init(void)
{
    esp_vfs_spiffs_conf_t conf = {
        .base_path              = "/spiffs",
        .partition_label        = "spiffs",
        .max_files              = 4,
        .format_if_mount_failed = true,
    };

    esp_err_t ret = esp_vfs_spiffs_register(&conf);
    if (ret != ESP_OK) {
        if (ret == ESP_FAIL) {
            ESP_LOGE(CACHE_TAG, "Mount/format SPIFFS failed");
        } else if (ret == ESP_ERR_NOT_FOUND) {
            ESP_LOGE(CACHE_TAG, "SPIFFS partition 'spiffs' not found");
        } else {
            ESP_LOGE(CACHE_TAG, "spiffs register failed: %s", esp_err_to_name(ret));
        }
        return ret;
    }

    size_t total = 0, used = 0;
    if (esp_spiffs_info("spiffs", &total, &used) == ESP_OK) {
        ESP_LOGI(CACHE_TAG, "SPIFFS mounted: %u/%u bytes used", (unsigned)used, (unsigned)total);
    }
    return ESP_OK;
}

esp_err_t map_cache_save(const map_geom_t *g)
{
    if (g == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    FILE *f = fopen(CACHE_TMP_PATH, "wb");
    if (f == NULL) {
        ESP_LOGE(CACHE_TAG, "open tmp for write failed");
        return ESP_FAIL;
    }

    cache_header_t hdr = {
        .magic   = CACHE_MAGIC,
        .version = CACHE_VERSION,
        .size    = (uint32_t)sizeof(map_geom_t),
    };

    bool ok = (fwrite(&hdr, sizeof(hdr), 1, f) == 1) &&
              (fwrite(g, sizeof(map_geom_t), 1, f) == 1);
    fclose(f);

    if (!ok) {
        ESP_LOGE(CACHE_TAG, "write failed");
        remove(CACHE_TMP_PATH);
        return ESP_FAIL;
    }

    /* rename atomic-ish: bỏ file cũ rồi đổi tên tmp. */
    remove(CACHE_PATH);
    if (rename(CACHE_TMP_PATH, CACHE_PATH) != 0) {
        ESP_LOGE(CACHE_TAG, "rename failed");
        remove(CACHE_TMP_PATH);
        return ESP_FAIL;
    }

    ESP_LOGI(CACHE_TAG, "saved geom (%u bytes)", (unsigned)sizeof(map_geom_t));
    return ESP_OK;
}

esp_err_t map_cache_load(map_geom_t *g)
{
    if (g == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    FILE *f = fopen(CACHE_PATH, "rb");
    if (f == NULL) {
        return ESP_ERR_NOT_FOUND;
    }

    cache_header_t hdr;
    if (fread(&hdr, sizeof(hdr), 1, f) != 1) {
        fclose(f);
        ESP_LOGW(CACHE_TAG, "header read failed");
        return ESP_ERR_NOT_FOUND;
    }

    if (hdr.magic != CACHE_MAGIC ||
        hdr.version != CACHE_VERSION ||
        hdr.size != (uint32_t)sizeof(map_geom_t)) {
        fclose(f);
        ESP_LOGW(CACHE_TAG, "header invalid (magic 0x%08X ver %u size %u)",
                 (unsigned)hdr.magic, (unsigned)hdr.version, (unsigned)hdr.size);
        return ESP_ERR_NOT_FOUND;
    }

    if (fread(g, sizeof(map_geom_t), 1, f) != 1) {
        fclose(f);
        ESP_LOGW(CACHE_TAG, "body read failed");
        return ESP_ERR_NOT_FOUND;
    }
    fclose(f);

    ESP_LOGI(CACHE_TAG, "loaded geom (%u route pts, %u roads)",
             (unsigned)g->route_n, (unsigned)g->road_n);
    return ESP_OK;
}
