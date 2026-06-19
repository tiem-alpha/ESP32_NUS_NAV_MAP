/*
 * SPDX-FileCopyrightText: 2026
 * SPDX-License-Identifier: Unlicense OR CC0-1.0
 *
 * app_main — nối các module HUD full-screen:
 *   nus (BLE NUS) → nus_protocol (deframe/CRC/dispatch) → nav_model / map_model
 *   → display (LVGL full-screen map + overlay). map_cache khôi phục geom sau reboot.
 */
#include <inttypes.h>
#include <stdint.h>

#include "esp_err.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "clock_model.h"
#include "display.h"
#include "map_model.h"
#include "nav_model.h"
#include "nus.h"
#include "nus_protocol.h"

#define APP_TAG "APP"

/* ── Transport glue ──────────────────────────────────────────────────── */

static esp_err_t app_proto_tx(const uint8_t *data, uint16_t len, uint32_t wait_ms)
{
    return nus_send(data, len, pdMS_TO_TICKS(wait_ms));
}

static void app_nus_rx_cb(const uint8_t *data, uint16_t len)
{
    nus_protocol_feed(data, len); /* byte stream → deframer */
}

static void app_nus_state_cb(nus_state_event_t event)
{
    switch (event) {
    case NUS_STATE_CONNECTED:
        ESP_LOGI(APP_TAG, "Connected");
        display_set_connected(true);
        break;
    case NUS_STATE_DISCONNECTED:
        ESP_LOGI(APP_TAG, "Disconnected");
        display_set_connected(false);
        break;
    default:
        break;
    }
}

/* ── app_main ────────────────────────────────────────────────────────── */

void app_main(void)
{
    /* CRC self-test (fail-fast nếu build sai). */
    const uint8_t check[] = "123456789";
    uint16_t crc = nav_crc16_mcrf4xx(check, 9);
    if (crc != 0x6F91) {
        ESP_LOGE(APP_TAG, "CRC16/MCRF4XX self-test FAILED: 0x%04X (expect 0x6F91)", crc);
    }

    /* Display + LVGL trước để báo trạng thái sớm. */
    display_init();

    /* Protocol + feature models. */
    ESP_ERROR_CHECK(nus_protocol_init(app_proto_tx, true /* auto_ack */));
    nav_model_init();
    map_model_init();
    clock_model_init();

    /* NUS config. */
    nus_config_t nus_config = NUS_CONFIG_DEFAULT();
    nus_config.device_name                  = "NAVHUD";
    nus_config.adv_interval_min_ms          = 80;
    nus_config.adv_interval_max_ms          = 120;
    nus_config.conn_interval_min_ms         = 12;  /* HIGH priority khi navigate */
    nus_config.conn_interval_max_ms         = 24;
    nus_config.conn_timeout_ms              = 4000;
    nus_config.auto_start_adv               = true;
    nus_config.restart_adv_after_disconnect = true;

    nus_set_state_callback(app_nus_state_cb);
    ESP_ERROR_CHECK(nus_init_with_config(&nus_config, app_nus_rx_cb));

    ESP_LOGI(APP_TAG, "NAVHUD ready");
}
