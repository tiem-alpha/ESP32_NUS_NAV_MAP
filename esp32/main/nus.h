/*
 * SPDX-FileCopyrightText: 2026
 *
 * SPDX-License-Identifier: Unlicense OR CC0-1.0
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"
#include "freertos/FreeRTOS.h"

#ifdef __cplusplus
extern "C" {
#endif

#define NUS_DEVICE_NAME "Tiem NUS"
#define NUS_MAX_DATA_LEN 512
#define NUS_TX_QUEUE_LEN 10

#define NUS_CONFIG_DEFAULT() { \
    .device_name = NUS_DEVICE_NAME, \
    .adv_interval_min_ms = 20, \
    .adv_interval_max_ms = 40, \
    .adv_timeout_ms = 0, \
    .conn_interval_min_ms = 20, \
    .conn_interval_max_ms = 40, \
    .conn_latency = 0, \
    .conn_timeout_ms = 4000, \
    .idle_timeout_ms = 0, \
    .auto_start_adv = true, \
    .restart_adv_after_disconnect = true, \
}

typedef enum {
    NUS_STATE_ADV_STARTED,
    NUS_STATE_ADV_STOPPED,
    NUS_STATE_ADV_TIMEOUT,
    NUS_STATE_CONNECTED,
    NUS_STATE_DISCONNECTED,
    NUS_STATE_NOTIFY_ENABLED,
    NUS_STATE_NOTIFY_DISABLED,
    NUS_STATE_IDLE_TIMEOUT,
} nus_state_event_t;

typedef struct {
    const char *device_name;
    uint16_t adv_interval_min_ms;
    uint16_t adv_interval_max_ms;
    uint32_t adv_timeout_ms;
    uint16_t conn_interval_min_ms;
    uint16_t conn_interval_max_ms;
    uint16_t conn_latency;
    uint16_t conn_timeout_ms;
    uint32_t idle_timeout_ms;
    bool auto_start_adv;
    bool restart_adv_after_disconnect;
} nus_config_t;

typedef void (*nus_rx_cb_t)(const uint8_t *data, uint16_t len);
typedef void (*nus_state_cb_t)(nus_state_event_t event);

esp_err_t nus_init(nus_rx_cb_t rx_cb);
esp_err_t nus_init_with_config(const nus_config_t *config, nus_rx_cb_t rx_cb);
void nus_set_rx_callback(nus_rx_cb_t rx_cb);
void nus_set_state_callback(nus_state_cb_t state_cb);

bool nus_is_connected(void);
bool nus_is_advertising(void);
bool nus_is_notify_enabled(void);
uint16_t nus_get_mtu(void);
uint16_t nus_get_max_payload_len(void);

esp_err_t nus_start_adv(uint32_t timeout_ms);
esp_err_t nus_stop_adv(void);
esp_err_t nus_send(const uint8_t *data, uint16_t len, TickType_t ticks_to_wait);
void nus_flush_tx_queue(void);
void nus_reset_idle_timeout(void);

#ifdef __cplusplus
}
#endif
