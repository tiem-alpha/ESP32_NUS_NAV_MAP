/*
 * SPDX-FileCopyrightText: 2021-2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Unlicense OR CC0-1.0
 */

#include "nus.h"

#include <inttypes.h>
#include <stdlib.h>
#include <string.h>

#include "esp_bt.h"
#include "esp_bt_defs.h"
#include "esp_bt_device.h"
#include "esp_bt_main.h"
#include "esp_gap_ble_api.h"
#include "esp_gatt_common_api.h"
#include "esp_gatts_api.h"
#include "esp_log.h"
#include "esp_system.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "freertos/timers.h"
#include "nvs_flash.h"
#include "sdkconfig.h"

#define NUS_TAG "NUS"
#define NUS_APP_ID 0
#define NUS_NUM_HANDLES 6
#define PREPARE_BUF_MAX_SIZE 1024

static const uint8_t s_nus_service_uuid128[ESP_UUID_LEN_128] = {
    0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9, 0xE0,
    0x93, 0xF3, 0xA3, 0xB5, 0x01, 0x00, 0x40, 0x6E
};

static const uint8_t s_nus_rx_char_uuid128[ESP_UUID_LEN_128] = {
    0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9, 0xE0,
    0x93, 0xF3, 0xA3, 0xB5, 0x02, 0x00, 0x40, 0x6E
};

static const uint8_t s_nus_tx_char_uuid128[ESP_UUID_LEN_128] = {
    0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9, 0xE0,
    0x93, 0xF3, 0xA3, 0xB5, 0x03, 0x00, 0x40, 0x6E
};

typedef struct {
    uint16_t len;
    uint8_t data[NUS_MAX_DATA_LEN];
} nus_tx_packet_t;

typedef struct {
    uint8_t *prepare_buf;
    int prepare_len;
    uint16_t handle;
} prepare_type_env_t;

typedef struct {
    bool initialized;
    bool connected;
    bool advertising;
    bool adv_data_ready;
    bool adv_start_requested;
    bool adv_timed_out;
    bool congested;
    uint32_t adv_timeout_ms;
    esp_gatt_if_t gatts_if;
    uint16_t conn_id;
    esp_bd_addr_t remote_bda;
    uint16_t service_handle;
    uint16_t rx_char_handle;
    uint16_t tx_char_handle;
    uint16_t tx_cccd_handle;
    uint16_t tx_cccd_value;
    uint16_t mtu;
    nus_rx_cb_t rx_cb;
    nus_state_cb_t state_cb;
    nus_config_t config;
    QueueHandle_t tx_queue;
    TaskHandle_t tx_task;
    TimerHandle_t adv_timer;
    TimerHandle_t idle_timer;
} nus_context_t;

static nus_context_t s_nus = {
    .gatts_if = ESP_GATT_IF_NONE,
    .mtu = 23,
    .config = NUS_CONFIG_DEFAULT(),
};

static char s_device_name[ESP_BLE_ADV_NAME_LEN_MAX] = NUS_DEVICE_NAME;
static uint8_t s_rx_value[NUS_MAX_DATA_LEN] = {0};
static uint8_t s_tx_value[NUS_MAX_DATA_LEN] = {0};

static esp_attr_value_t s_rx_char_val = {
    .attr_max_len = NUS_MAX_DATA_LEN,
    .attr_len = 0,
    .attr_value = s_rx_value,
};

static esp_attr_value_t s_tx_char_val = {
    .attr_max_len = NUS_MAX_DATA_LEN,
    .attr_len = 0,
    .attr_value = s_tx_value,
};

static uint8_t s_adv_config_done = 0;
#define ADV_CONFIG_FLAG      (1 << 0)
#define SCAN_RSP_CONFIG_FLAG (1 << 1)

#ifdef CONFIG_EXAMPLE_SET_RAW_ADV_DATA
static uint8_t s_raw_adv_data[] = {
    0x02, ESP_BLE_AD_TYPE_FLAG, 0x06,
    0x11, ESP_BLE_AD_TYPE_128SRV_CMPL,
    0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9, 0xE0,
    0x93, 0xF3, 0xA3, 0xB5, 0x01, 0x00, 0x40, 0x6E,
};

static uint8_t s_raw_scan_rsp_data[31];
static uint8_t s_raw_scan_rsp_data_len;
#else
static uint8_t s_adv_service_uuid128[ESP_UUID_LEN_128] = {
    0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9, 0xE0,
    0x93, 0xF3, 0xA3, 0xB5, 0x01, 0x00, 0x40, 0x6E
};

static esp_ble_adv_data_t s_adv_data = {
    .set_scan_rsp = false,
    .include_name = false,
    .include_txpower = false,
    .min_interval = 0,
    .max_interval = 0,
    .appearance = 0x00,
    .manufacturer_len = 0,
    .p_manufacturer_data = NULL,
    .service_data_len = 0,
    .p_service_data = NULL,
    .service_uuid_len = sizeof(s_adv_service_uuid128),
    .p_service_uuid = s_adv_service_uuid128,
    .flag = (ESP_BLE_ADV_FLAG_GEN_DISC | ESP_BLE_ADV_FLAG_BREDR_NOT_SPT),
};

static esp_ble_adv_data_t s_scan_rsp_data = {
    .set_scan_rsp = true,
    .include_name = true,
    .include_txpower = true,
    .appearance = 0x00,
    .manufacturer_len = 0,
    .p_manufacturer_data = NULL,
    .service_data_len = 0,
    .p_service_data = NULL,
    .service_uuid_len = 0,
    .p_service_uuid = NULL,
    .flag = (ESP_BLE_ADV_FLAG_GEN_DISC | ESP_BLE_ADV_FLAG_BREDR_NOT_SPT),
};
#endif

static esp_ble_adv_params_t s_adv_params = {
    .adv_int_min = ESP_BLE_GAP_ADV_ITVL_MS(20),
    .adv_int_max = ESP_BLE_GAP_ADV_ITVL_MS(40),
    .adv_type = ADV_TYPE_IND,
    .own_addr_type = BLE_ADDR_TYPE_PUBLIC,
    .channel_map = ADV_CHNL_ALL,
    .adv_filter_policy = ADV_FILTER_ALLOW_SCAN_ANY_CON_ANY,
};

static esp_gatt_srvc_id_t s_service_id;
static esp_bt_uuid_t s_char_uuid;
static esp_bt_uuid_t s_descr_uuid;
static prepare_type_env_t s_prepare_write_env;

static void nus_gap_event_handler(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t *param);
static void nus_gatts_event_handler(esp_gatts_cb_event_t event, esp_gatt_if_t gatts_if, esp_ble_gatts_cb_param_t *param);
static void nus_adv_timeout_cb(TimerHandle_t timer);
static void nus_idle_timeout_cb(TimerHandle_t timer);

static size_t nus_strnlen(const char *str, size_t max_len)
{
    size_t len = 0;
    while (len < max_len && str[len] != '\0') {
        len++;
    }
    return len;
}

static TickType_t nus_ms_to_ticks(uint32_t timeout_ms)
{
    TickType_t ticks = pdMS_TO_TICKS(timeout_ms);
    return (ticks == 0 && timeout_ms > 0) ? 1 : ticks;
}

#ifdef CONFIG_EXAMPLE_SET_RAW_ADV_DATA
static void nus_build_raw_scan_rsp_data(void)
{
    size_t name_len = nus_strnlen(s_device_name, sizeof(s_device_name));
    if (name_len > 29) {
        name_len = 29;
    }

    s_raw_scan_rsp_data[0] = (uint8_t)(name_len + 1);
    s_raw_scan_rsp_data[1] = ESP_BLE_AD_TYPE_NAME_CMPL;
    memcpy(&s_raw_scan_rsp_data[2], s_device_name, name_len);
    s_raw_scan_rsp_data_len = (uint8_t)(name_len + 2);
}
#endif

static esp_err_t nus_apply_config(const nus_config_t *config)
{
    nus_config_t cfg = NUS_CONFIG_DEFAULT();
    if (config) {
        cfg = *config;
    }

    if (cfg.device_name == NULL) {
        cfg.device_name = NUS_DEVICE_NAME;
    }
    if (cfg.adv_interval_min_ms == 0 ||
        cfg.adv_interval_max_ms == 0 ||
        cfg.adv_interval_min_ms > cfg.adv_interval_max_ms ||
        cfg.conn_interval_min_ms == 0 ||
        cfg.conn_interval_max_ms == 0 ||
        cfg.conn_interval_min_ms > cfg.conn_interval_max_ms ||
        cfg.conn_timeout_ms == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    size_t name_len = nus_strnlen(cfg.device_name, sizeof(s_device_name));
    if (name_len >= sizeof(s_device_name)) {
        return ESP_ERR_INVALID_SIZE;
    }

    memcpy(s_device_name, cfg.device_name, name_len);
    s_device_name[name_len] = '\0';

    s_nus.config = cfg;
    s_nus.config.device_name = s_device_name;

    s_adv_params.adv_int_min = ESP_BLE_GAP_ADV_ITVL_MS(cfg.adv_interval_min_ms);
    s_adv_params.adv_int_max = ESP_BLE_GAP_ADV_ITVL_MS(cfg.adv_interval_max_ms);

#ifdef CONFIG_EXAMPLE_SET_RAW_ADV_DATA
    nus_build_raw_scan_rsp_data();
#else
    s_adv_data.min_interval = ESP_BLE_GAP_CONN_ITVL_MS(cfg.conn_interval_min_ms);
    s_adv_data.max_interval = ESP_BLE_GAP_CONN_ITVL_MS(cfg.conn_interval_max_ms);
#endif

    return ESP_OK;
}

static void nus_emit_state(nus_state_event_t event)
{
    if (s_nus.state_cb) {
        s_nus.state_cb(event);
    }
}

static void nus_start_adv_timeout_timer(uint32_t timeout_ms)
{
    if (s_nus.adv_timer == NULL || timeout_ms == 0) {
        return;
    }

    xTimerChangePeriod(s_nus.adv_timer, nus_ms_to_ticks(timeout_ms), 0);
    xTimerStart(s_nus.adv_timer, 0);
}

static void nus_stop_adv_timeout_timer(void)
{
    if (s_nus.adv_timer) {
        xTimerStop(s_nus.adv_timer, 0);
    }
}

static void nus_adv_timeout_cb(TimerHandle_t timer)
{
    (void)timer;

    if (!s_nus.connected && s_nus.advertising) {
        s_nus.adv_timed_out = true;
        esp_err_t err = esp_ble_gap_stop_advertising();
        if (err != ESP_OK) {
            ESP_LOGE(NUS_TAG, "Stop advertising on timeout failed: %s", esp_err_to_name(err));
        }
    }
}

static void nus_idle_timeout_cb(TimerHandle_t timer)
{
    (void)timer;

    if (s_nus.connected) {
        ESP_LOGW(NUS_TAG, "Idle timeout");
        nus_emit_state(NUS_STATE_IDLE_TIMEOUT);
        esp_err_t err = esp_ble_gap_disconnect(s_nus.remote_bda);
        if (err != ESP_OK) {
            ESP_LOGE(NUS_TAG, "Disconnect on idle timeout failed: %s", esp_err_to_name(err));
        }
    }
}

static void nus_on_adv_data_ready(void)
{
    if (s_adv_config_done != 0) {
        return;
    }

    s_nus.adv_data_ready = true;
    if (s_nus.config.auto_start_adv || s_nus.adv_start_requested) {
        uint32_t timeout_ms = s_nus.adv_start_requested ? s_nus.adv_timeout_ms : s_nus.config.adv_timeout_ms;
        esp_err_t err = nus_start_adv(timeout_ms);
        if (err != ESP_OK) {
            ESP_LOGE(NUS_TAG, "Start advertising failed: %s", esp_err_to_name(err));
        }
    }
}

static bool nus_is_ready_to_send(void)
{
    return s_nus.connected &&
           nus_is_notify_enabled() &&
           s_nus.gatts_if != ESP_GATT_IF_NONE &&
           s_nus.tx_char_handle != 0;
}

static void nus_store_tx_value(const uint8_t *data, uint16_t len)
{
    uint16_t copy_len = len;
    if (copy_len > NUS_MAX_DATA_LEN) {
        copy_len = NUS_MAX_DATA_LEN;
    }

    memcpy(s_tx_value, data, copy_len);
    s_tx_char_val.attr_len = copy_len;
}

static void nus_handle_rx_data(const uint8_t *data, uint16_t len)
{
    uint16_t copy_len = len;
    if (copy_len > NUS_MAX_DATA_LEN) {
        copy_len = NUS_MAX_DATA_LEN;
    }

    memcpy(s_rx_value, data, copy_len);
    s_rx_char_val.attr_len = copy_len;
    nus_reset_idle_timeout();
    // ESP_LOGI(NUS_TAG, "RX %u bytes", copy_len);
    // ESP_LOG_BUFFER_HEX(NUS_TAG, s_rx_value, copy_len);

    if (s_nus.rx_cb) {
        s_nus.rx_cb(s_rx_value, copy_len);
    }
}

static void nus_tx_task(void *arg)
{
    (void)arg;
    nus_tx_packet_t packet;

    while (true) {
        if (xQueueReceive(s_nus.tx_queue, &packet, portMAX_DELAY) != pdTRUE) {
            continue;
        }

        if (!nus_is_ready_to_send()) {
            ESP_LOGW(NUS_TAG, "Drop TX packet: client is not ready");
            continue;
        }

        uint16_t offset = 0;
        while (offset < packet.len) {
            if (!nus_is_ready_to_send()) {
                ESP_LOGW(NUS_TAG, "Drop remaining TX data: client disconnected or notify disabled");
                break;
            }

            while (s_nus.congested && nus_is_ready_to_send()) {
                vTaskDelay(pdMS_TO_TICKS(20));
            }

            uint16_t max_payload = nus_get_max_payload_len();
            if (max_payload == 0) {
                vTaskDelay(pdMS_TO_TICKS(20));
                continue;
            }

            uint16_t chunk_len = packet.len - offset;
            if (chunk_len > max_payload) {
                chunk_len = max_payload;
            }

            esp_err_t err = esp_ble_gatts_send_indicate(s_nus.gatts_if,
                                                        s_nus.conn_id,
                                                        s_nus.tx_char_handle,
                                                        chunk_len,
                                                        packet.data + offset,
                                                        false);
            if (err != ESP_OK) {
                ESP_LOGE(NUS_TAG, "Send failed: %s", esp_err_to_name(err));
                break;
            }

            offset += chunk_len;
            vTaskDelay(pdMS_TO_TICKS(10));
        }
    }
}

static void nus_write_event_env(esp_gatt_if_t gatts_if, prepare_type_env_t *prepare_write_env, esp_ble_gatts_cb_param_t *param)
{
    esp_gatt_status_t status = ESP_GATT_OK;

    if (!param->write.need_rsp) {
        return;
    }

    if (param->write.is_prep) {
        if (param->write.offset > PREPARE_BUF_MAX_SIZE) {
            status = ESP_GATT_INVALID_OFFSET;
        } else if ((param->write.offset + param->write.len) > PREPARE_BUF_MAX_SIZE) {
            status = ESP_GATT_INVALID_ATTR_LEN;
        }

        if (status == ESP_GATT_OK && prepare_write_env->prepare_buf == NULL) {
            prepare_write_env->prepare_buf = (uint8_t *)malloc(PREPARE_BUF_MAX_SIZE);
            prepare_write_env->prepare_len = 0;
            prepare_write_env->handle = param->write.handle;
            if (prepare_write_env->prepare_buf == NULL) {
                ESP_LOGE(NUS_TAG, "Prepare write alloc failed");
                status = ESP_GATT_NO_RESOURCES;
            }
        }

        esp_gatt_rsp_t *gatt_rsp = (esp_gatt_rsp_t *)calloc(1, sizeof(esp_gatt_rsp_t));
        if (gatt_rsp) {
            gatt_rsp->attr_value.len = param->write.len;
            gatt_rsp->attr_value.handle = param->write.handle;
            gatt_rsp->attr_value.offset = param->write.offset;
            gatt_rsp->attr_value.auth_req = ESP_GATT_AUTH_REQ_NONE;
            memcpy(gatt_rsp->attr_value.value, param->write.value, param->write.len);
            esp_err_t response_err = esp_ble_gatts_send_response(gatts_if,
                                                                 param->write.conn_id,
                                                                 param->write.trans_id,
                                                                 status,
                                                                 gatt_rsp);
            if (response_err != ESP_OK) {
                ESP_LOGE(NUS_TAG, "Send prepare response failed: %s", esp_err_to_name(response_err));
            }
            free(gatt_rsp);
        } else {
            ESP_LOGE(NUS_TAG, "No memory for prepare response");
            status = ESP_GATT_NO_RESOURCES;
        }

        if (status != ESP_GATT_OK) {
            return;
        }

        memcpy(prepare_write_env->prepare_buf + param->write.offset,
               param->write.value,
               param->write.len);
        prepare_write_env->prepare_len += param->write.len;
    } else {
        esp_ble_gatts_send_response(gatts_if,
                                    param->write.conn_id,
                                    param->write.trans_id,
                                    status,
                                    NULL);
    }
}

static void nus_exec_write_event_env(prepare_type_env_t *prepare_write_env, esp_ble_gatts_cb_param_t *param)
{
    if (param->exec_write.exec_write_flag == ESP_GATT_PREP_WRITE_EXEC &&
        prepare_write_env->prepare_buf &&
        prepare_write_env->prepare_len > 0) {
        if (prepare_write_env->handle == s_nus.rx_char_handle) {
            nus_handle_rx_data(prepare_write_env->prepare_buf, prepare_write_env->prepare_len);
        } else {
            ESP_LOG_BUFFER_HEX(NUS_TAG, prepare_write_env->prepare_buf, prepare_write_env->prepare_len);
        }
    } else {
        ESP_LOGI(NUS_TAG, "Prepare write cancel");
    }

    if (prepare_write_env->prepare_buf) {
        free(prepare_write_env->prepare_buf);
        prepare_write_env->prepare_buf = NULL;
    }
    prepare_write_env->prepare_len = 0;
    prepare_write_env->handle = 0;
}

static void nus_gap_event_handler(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t *param)
{
    switch (event) {
#ifdef CONFIG_EXAMPLE_SET_RAW_ADV_DATA
    case ESP_GAP_BLE_ADV_DATA_RAW_SET_COMPLETE_EVT:
        s_adv_config_done &= (~ADV_CONFIG_FLAG);
        nus_on_adv_data_ready();
        break;
    case ESP_GAP_BLE_SCAN_RSP_DATA_RAW_SET_COMPLETE_EVT:
        s_adv_config_done &= (~SCAN_RSP_CONFIG_FLAG);
        nus_on_adv_data_ready();
        break;
#else
    case ESP_GAP_BLE_ADV_DATA_SET_COMPLETE_EVT:
        s_adv_config_done &= (~ADV_CONFIG_FLAG);
        nus_on_adv_data_ready();
        break;
    case ESP_GAP_BLE_SCAN_RSP_DATA_SET_COMPLETE_EVT:
        s_adv_config_done &= (~SCAN_RSP_CONFIG_FLAG);
        nus_on_adv_data_ready();
        break;
#endif
    case ESP_GAP_BLE_ADV_START_COMPLETE_EVT:
        if (param->adv_start_cmpl.status != ESP_BT_STATUS_SUCCESS) {
            ESP_LOGE(NUS_TAG, "Advertising start failed, status %d", param->adv_start_cmpl.status);
            break;
        }
        s_nus.advertising = true;
        s_nus.adv_start_requested = false;
        s_nus.adv_timed_out = false;
        nus_start_adv_timeout_timer(s_nus.adv_timeout_ms);
        nus_emit_state(NUS_STATE_ADV_STARTED);
        ESP_LOGI(NUS_TAG, "Advertising started");
        break;
    case ESP_GAP_BLE_ADV_STOP_COMPLETE_EVT:
        if (param->adv_stop_cmpl.status != ESP_BT_STATUS_SUCCESS) {
            ESP_LOGE(NUS_TAG, "Advertising stop failed, status %d", param->adv_stop_cmpl.status);
            break;
        }
        s_nus.advertising = false;
        s_nus.adv_start_requested = false;
        nus_stop_adv_timeout_timer();
        nus_emit_state(s_nus.adv_timed_out ? NUS_STATE_ADV_TIMEOUT : NUS_STATE_ADV_STOPPED);
        s_nus.adv_timed_out = false;
        ESP_LOGI(NUS_TAG, "Advertising stopped");
        break;
    case ESP_GAP_BLE_UPDATE_CONN_PARAMS_EVT:
        ESP_LOGI(NUS_TAG, "Conn params update, status %d, conn_int %d, latency %d, timeout %d",
                 param->update_conn_params.status,
                 param->update_conn_params.conn_int,
                 param->update_conn_params.latency,
                 param->update_conn_params.timeout);
        break;
    case ESP_GAP_BLE_SET_PKT_LENGTH_COMPLETE_EVT:
        ESP_LOGI(NUS_TAG, "Packet length update, status %d, rx %d, tx %d",
                 param->pkt_data_length_cmpl.status,
                 param->pkt_data_length_cmpl.params.rx_len,
                 param->pkt_data_length_cmpl.params.tx_len);
        break;
    default:
        break;
    }
}

static void nus_gatts_event_handler(esp_gatts_cb_event_t event, esp_gatt_if_t gatts_if, esp_ble_gatts_cb_param_t *param)
{
    switch (event) {
    case ESP_GATTS_REG_EVT:
        ESP_LOGI(NUS_TAG, "GATT server register, status %d, app_id %d, gatts_if %d",
                 param->reg.status, param->reg.app_id, gatts_if);
        s_service_id.is_primary = true;
        s_service_id.id.inst_id = 0x00;
        s_service_id.id.uuid.len = ESP_UUID_LEN_128;
        memcpy(s_service_id.id.uuid.uuid.uuid128, s_nus_service_uuid128, sizeof(s_nus_service_uuid128));

        esp_err_t set_dev_name_ret = esp_ble_gap_set_device_name(s_device_name);
        if (set_dev_name_ret) {
            ESP_LOGE(NUS_TAG, "Set device name failed: %s", esp_err_to_name(set_dev_name_ret));
        }

#ifdef CONFIG_EXAMPLE_SET_RAW_ADV_DATA
        esp_err_t raw_adv_ret = esp_ble_gap_config_adv_data_raw(s_raw_adv_data, sizeof(s_raw_adv_data));
        if (raw_adv_ret) {
            ESP_LOGE(NUS_TAG, "Config raw adv failed: %s", esp_err_to_name(raw_adv_ret));
        }
        s_adv_config_done |= ADV_CONFIG_FLAG;

        esp_err_t raw_scan_ret = esp_ble_gap_config_scan_rsp_data_raw(s_raw_scan_rsp_data, s_raw_scan_rsp_data_len);
        if (raw_scan_ret) {
            ESP_LOGE(NUS_TAG, "Config raw scan rsp failed: %s", esp_err_to_name(raw_scan_ret));
        }
        s_adv_config_done |= SCAN_RSP_CONFIG_FLAG;
#else
        esp_err_t ret = esp_ble_gap_config_adv_data(&s_adv_data);
        if (ret) {
            ESP_LOGE(NUS_TAG, "Config adv failed: %s", esp_err_to_name(ret));
        }
        s_adv_config_done |= ADV_CONFIG_FLAG;

        ret = esp_ble_gap_config_adv_data(&s_scan_rsp_data);
        if (ret) {
            ESP_LOGE(NUS_TAG, "Config scan rsp failed: %s", esp_err_to_name(ret));
        }
        s_adv_config_done |= SCAN_RSP_CONFIG_FLAG;
#endif

        esp_ble_gatts_create_service(gatts_if, &s_service_id, NUS_NUM_HANDLES);
        break;

    case ESP_GATTS_READ_EVT: {
        if (!param->read.need_rsp) {
            break;
        }

        esp_gatt_rsp_t rsp;
        memset(&rsp, 0, sizeof(rsp));
        rsp.attr_value.handle = param->read.handle;

        if (param->read.handle == s_nus.tx_cccd_handle) {
            memcpy(rsp.attr_value.value, &s_nus.tx_cccd_value, sizeof(s_nus.tx_cccd_value));
            rsp.attr_value.len = sizeof(s_nus.tx_cccd_value);
            esp_ble_gatts_send_response(gatts_if,
                                        param->read.conn_id,
                                        param->read.trans_id,
                                        ESP_GATT_OK,
                                        &rsp);
            break;
        }

        if (param->read.handle == s_nus.tx_char_handle) {
            uint16_t offset = param->read.offset;
            if (offset > s_tx_char_val.attr_len) {
                esp_ble_gatts_send_response(gatts_if,
                                            param->read.conn_id,
                                            param->read.trans_id,
                                            ESP_GATT_INVALID_OFFSET,
                                            &rsp);
                break;
            }

            uint16_t send_len = s_tx_char_val.attr_len - offset;
            uint16_t mtu_size = (s_nus.mtu > 1) ? (s_nus.mtu - 1) : 0;
            if (send_len > mtu_size) {
                send_len = mtu_size;
            }
            memcpy(rsp.attr_value.value, s_tx_char_val.attr_value + offset, send_len);
            rsp.attr_value.len = send_len;
            esp_ble_gatts_send_response(gatts_if,
                                        param->read.conn_id,
                                        param->read.trans_id,
                                        ESP_GATT_OK,
                                        &rsp);
            break;
        }

        esp_ble_gatts_send_response(gatts_if,
                                    param->read.conn_id,
                                    param->read.trans_id,
                                    ESP_GATT_READ_NOT_PERMIT,
                                    &rsp);
        break;
    }

    case ESP_GATTS_WRITE_EVT:
        ESP_LOGI(NUS_TAG, "Write request, conn_id %d, trans_id %" PRIu32 ", handle %d, len %d",
                 param->write.conn_id, param->write.trans_id, param->write.handle, param->write.len);

        if (!param->write.is_prep) {
            if (param->write.handle == s_nus.rx_char_handle) {
                nus_handle_rx_data(param->write.value, param->write.len);
            } else if (param->write.handle == s_nus.tx_cccd_handle && param->write.len == 2) {
                bool was_enabled = nus_is_notify_enabled();
                s_nus.tx_cccd_value = (uint16_t)param->write.value[1] << 8 | param->write.value[0];
                bool is_enabled = nus_is_notify_enabled();

                ESP_LOGI(NUS_TAG, "TX notify %s", is_enabled ? "enabled" : "disabled");

                if (was_enabled != is_enabled) {
                    nus_emit_state(is_enabled ? NUS_STATE_NOTIFY_ENABLED : NUS_STATE_NOTIFY_DISABLED);
                }
                if (!is_enabled) {
                    nus_flush_tx_queue();
                }
            }
        }

        nus_write_event_env(gatts_if, &s_prepare_write_env, param);
        break;

    case ESP_GATTS_EXEC_WRITE_EVT:
        ESP_LOGI(NUS_TAG, "Execute write");
        esp_ble_gatts_send_response(gatts_if,
                                    param->exec_write.conn_id,
                                    param->exec_write.trans_id,
                                    ESP_GATT_OK,
                                    NULL);
        nus_exec_write_event_env(&s_prepare_write_env, param);
        break;

    case ESP_GATTS_MTU_EVT:
        ESP_LOGI(NUS_TAG, "MTU exchange, MTU %d", param->mtu.mtu);
        s_nus.mtu = param->mtu.mtu;
        break;

    case ESP_GATTS_CREATE_EVT:
        ESP_LOGI(NUS_TAG, "Service create, status %d, service_handle %d",
                 param->create.status, param->create.service_handle);
        s_nus.service_handle = param->create.service_handle;
        esp_ble_gatts_start_service(s_nus.service_handle);

        s_char_uuid.len = ESP_UUID_LEN_128;
        memcpy(s_char_uuid.uuid.uuid128, s_nus_rx_char_uuid128, sizeof(s_nus_rx_char_uuid128));
        esp_gatt_char_prop_t rx_property = ESP_GATT_CHAR_PROP_BIT_WRITE | ESP_GATT_CHAR_PROP_BIT_WRITE_NR;
        esp_err_t add_char_ret = esp_ble_gatts_add_char(s_nus.service_handle,
                                                        &s_char_uuid,
                                                        ESP_GATT_PERM_WRITE,
                                                        rx_property,
                                                        &s_rx_char_val,
                                                        NULL);
        if (add_char_ret) {
            ESP_LOGE(NUS_TAG, "Add RX char failed: %s", esp_err_to_name(add_char_ret));
        }
        break;

    case ESP_GATTS_ADD_CHAR_EVT:
        ESP_LOGI(NUS_TAG, "Characteristic add, status %d, attr_handle %d, service_handle %d",
                 param->add_char.status, param->add_char.attr_handle, param->add_char.service_handle);

        if (s_nus.rx_char_handle == 0) {
            s_nus.rx_char_handle = param->add_char.attr_handle;
            s_char_uuid.len = ESP_UUID_LEN_128;
            memcpy(s_char_uuid.uuid.uuid128, s_nus_tx_char_uuid128, sizeof(s_nus_tx_char_uuid128));
            esp_gatt_char_prop_t tx_property = ESP_GATT_CHAR_PROP_BIT_NOTIFY | ESP_GATT_CHAR_PROP_BIT_READ;
            esp_err_t add_tx_ret = esp_ble_gatts_add_char(s_nus.service_handle,
                                                          &s_char_uuid,
                                                          ESP_GATT_PERM_READ,
                                                          tx_property,
                                                          &s_tx_char_val,
                                                          NULL);
            if (add_tx_ret) {
                ESP_LOGE(NUS_TAG, "Add TX char failed: %s", esp_err_to_name(add_tx_ret));
            }
        } else {
            s_nus.tx_char_handle = param->add_char.attr_handle;
            s_descr_uuid.len = ESP_UUID_LEN_16;
            s_descr_uuid.uuid.uuid16 = ESP_GATT_UUID_CHAR_CLIENT_CONFIG;
            esp_err_t add_descr_ret = esp_ble_gatts_add_char_descr(s_nus.service_handle,
                                                                   &s_descr_uuid,
                                                                   ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE,
                                                                   NULL,
                                                                   NULL);
            if (add_descr_ret) {
                ESP_LOGE(NUS_TAG, "Add TX CCCD failed: %s", esp_err_to_name(add_descr_ret));
            }
        }
        break;

    case ESP_GATTS_ADD_CHAR_DESCR_EVT:
        s_nus.tx_cccd_handle = param->add_char_descr.attr_handle;
        ESP_LOGI(NUS_TAG, "Descriptor add, status %d, attr_handle %d, service_handle %d",
                 param->add_char_descr.status,
                 param->add_char_descr.attr_handle,
                 param->add_char_descr.service_handle);
        break;

    case ESP_GATTS_START_EVT:
        ESP_LOGI(NUS_TAG, "Service start, status %d, service_handle %d",
                 param->start.status, param->start.service_handle);
        break;

    case ESP_GATTS_CONNECT_EVT: {
        esp_ble_conn_update_params_t conn_params = {0};
        memcpy(conn_params.bda, param->connect.remote_bda, sizeof(esp_bd_addr_t));
        conn_params.latency = s_nus.config.conn_latency;
        conn_params.max_int = ESP_BLE_GAP_CONN_ITVL_MS(s_nus.config.conn_interval_max_ms);
        conn_params.min_int = ESP_BLE_GAP_CONN_ITVL_MS(s_nus.config.conn_interval_min_ms);
        conn_params.timeout = s_nus.config.conn_timeout_ms / 10;
        if (conn_params.timeout == 0) {
            conn_params.timeout = 1;
        }

        ESP_LOGI(NUS_TAG, "Connected, conn_id %u, remote " ESP_BD_ADDR_STR,
                 param->connect.conn_id, ESP_BD_ADDR_HEX(param->connect.remote_bda));
        bool adv_was_active = s_nus.advertising;
        s_nus.conn_id = param->connect.conn_id;
        memcpy(s_nus.remote_bda, param->connect.remote_bda, sizeof(esp_bd_addr_t));
        s_nus.connected = true;
        s_nus.advertising = false;
        s_nus.adv_start_requested = false;
        s_nus.congested = false;
        s_nus.tx_cccd_value = 0x0000;
        nus_stop_adv_timeout_timer();
        if (adv_was_active) {
            nus_emit_state(NUS_STATE_ADV_STOPPED);
        }
        nus_emit_state(NUS_STATE_CONNECTED);
        nus_reset_idle_timeout();
        esp_ble_gap_update_conn_params(&conn_params);
        break;
    }

    case ESP_GATTS_DISCONNECT_EVT: {
        bool notify_was_enabled = nus_is_notify_enabled();
        ESP_LOGI(NUS_TAG, "Disconnected, remote " ESP_BD_ADDR_STR ", reason 0x%02x",
                 ESP_BD_ADDR_HEX(param->disconnect.remote_bda), param->disconnect.reason);
        s_nus.connected = false;
        s_nus.congested = false;
        s_nus.mtu = 23;
        s_nus.tx_cccd_value = 0x0000;
        if (s_nus.idle_timer) {
            xTimerStop(s_nus.idle_timer, 0);
        }
        nus_flush_tx_queue();
        if (notify_was_enabled) {
            nus_emit_state(NUS_STATE_NOTIFY_DISABLED);
        }
        nus_emit_state(NUS_STATE_DISCONNECTED);
        if (s_nus.config.restart_adv_after_disconnect) {
            esp_err_t err = nus_start_adv(s_nus.config.adv_timeout_ms);
            if (err != ESP_OK) {
                ESP_LOGE(NUS_TAG, "Restart advertising failed: %s", esp_err_to_name(err));
            }
        }
        break;
    }

    case ESP_GATTS_CONGEST_EVT:
        if (param->congest.conn_id == s_nus.conn_id) {
            s_nus.congested = param->congest.congested;
            ESP_LOGI(NUS_TAG, "Congestion %s", s_nus.congested ? "on" : "off");
        }
        break;

    case ESP_GATTS_CONF_EVT:
        ESP_LOGI(NUS_TAG, "Confirm receive, status %d, attr_handle %d",
                 param->conf.status, param->conf.handle);
        if (param->conf.status != ESP_GATT_OK) {
            ESP_LOG_BUFFER_HEX(NUS_TAG, param->conf.value, param->conf.len);
        }
        break;

    case ESP_GATTS_UNREG_EVT:
    case ESP_GATTS_ADD_INCL_SRVC_EVT:
    case ESP_GATTS_DELETE_EVT:
    case ESP_GATTS_STOP_EVT:
    case ESP_GATTS_OPEN_EVT:
    case ESP_GATTS_CANCEL_OPEN_EVT:
    case ESP_GATTS_CLOSE_EVT:
    case ESP_GATTS_LISTEN_EVT:
    default:
        break;
    }
}

static void nus_gatts_dispatch_event(esp_gatts_cb_event_t event, esp_gatt_if_t gatts_if, esp_ble_gatts_cb_param_t *param)
{
    if (event == ESP_GATTS_REG_EVT) {
        if (param->reg.status == ESP_GATT_OK) {
            s_nus.gatts_if = gatts_if;
        } else {
            ESP_LOGE(NUS_TAG, "Register app failed, app_id %04x, status %d",
                     param->reg.app_id, param->reg.status);
            return;
        }
    }

    if (gatts_if == ESP_GATT_IF_NONE || gatts_if == s_nus.gatts_if) {
        nus_gatts_event_handler(event, gatts_if, param);
    }
}

esp_err_t nus_init(nus_rx_cb_t rx_cb)
{
    return nus_init_with_config(NULL, rx_cb);
}

esp_err_t nus_init_with_config(const nus_config_t *config, nus_rx_cb_t rx_cb)
{
    if (s_nus.initialized) {
        s_nus.rx_cb = rx_cb;
        return ESP_OK;
    }

    esp_err_t ret = nus_apply_config(config);
    if (ret != ESP_OK) {
        return ret;
    }

    s_nus.rx_cb = rx_cb;
    s_nus.tx_queue = xQueueCreate(NUS_TX_QUEUE_LEN, sizeof(nus_tx_packet_t));
    if (s_nus.tx_queue == NULL) {
        return ESP_ERR_NO_MEM;
    }

    s_nus.adv_timer = xTimerCreate("nus_adv_timeout",
                                   nus_ms_to_ticks(1000),
                                   pdFALSE,
                                   NULL,
                                   nus_adv_timeout_cb);
    if (s_nus.adv_timer == NULL) {
        vQueueDelete(s_nus.tx_queue);
        s_nus.tx_queue = NULL;
        return ESP_ERR_NO_MEM;
    }

    s_nus.idle_timer = xTimerCreate("nus_idle_timeout",
                                    nus_ms_to_ticks(1000),
                                    pdFALSE,
                                    NULL,
                                    nus_idle_timeout_cb);
    if (s_nus.idle_timer == NULL) {
        xTimerDelete(s_nus.adv_timer, 0);
        s_nus.adv_timer = NULL;
        vQueueDelete(s_nus.tx_queue);
        s_nus.tx_queue = NULL;
        return ESP_ERR_NO_MEM;
    }

    if (xTaskCreate(nus_tx_task, "nus_tx", 4096, NULL, 10, &s_nus.tx_task) != pdPASS) {
        xTimerDelete(s_nus.idle_timer, 0);
        s_nus.idle_timer = NULL;
        xTimerDelete(s_nus.adv_timer, 0);
        s_nus.adv_timer = NULL;
        vQueueDelete(s_nus.tx_queue);
        s_nus.tx_queue = NULL;
        return ESP_ERR_NO_MEM;
    }

    ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    if (ret != ESP_OK) {
        return ret;
    }

#if CONFIG_EXAMPLE_CI_PIPELINE_ID
    memcpy(s_device_name, esp_bluedroid_get_example_name(), ESP_BLE_ADV_NAME_LEN_MAX);
    s_device_name[sizeof(s_device_name) - 1] = '\0';
    s_nus.config.device_name = s_device_name;
#ifdef CONFIG_EXAMPLE_SET_RAW_ADV_DATA
    nus_build_raw_scan_rsp_data();
#endif
#endif

    ret = esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT);
    if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
        return ret;
    }

    esp_bt_controller_config_t bt_cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    ret = esp_bt_controller_init(&bt_cfg);
    if (ret != ESP_OK) {
        ESP_LOGE(NUS_TAG, "Controller init failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = esp_bt_controller_enable(ESP_BT_MODE_BLE);
    if (ret != ESP_OK) {
        ESP_LOGE(NUS_TAG, "Controller enable failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = esp_bluedroid_init();
    if (ret != ESP_OK) {
        ESP_LOGE(NUS_TAG, "Bluedroid init failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = esp_bluedroid_enable();
    if (ret != ESP_OK) {
        ESP_LOGE(NUS_TAG, "Bluedroid enable failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = esp_ble_gatts_register_callback(nus_gatts_dispatch_event);
    if (ret != ESP_OK) {
        ESP_LOGE(NUS_TAG, "Register GATTS callback failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = esp_ble_gap_register_callback(nus_gap_event_handler);
    if (ret != ESP_OK) {
        ESP_LOGE(NUS_TAG, "Register GAP callback failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = esp_ble_gatts_app_register(NUS_APP_ID);
    if (ret != ESP_OK) {
        ESP_LOGE(NUS_TAG, "Register GATTS app failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = esp_ble_gatt_set_local_mtu(500);
    if (ret != ESP_OK) {
        ESP_LOGE(NUS_TAG, "Set local MTU failed: %s", esp_err_to_name(ret));
        return ret;
    }

    s_nus.initialized = true;
    return ESP_OK;
}

void nus_set_rx_callback(nus_rx_cb_t rx_cb)
{
    s_nus.rx_cb = rx_cb;
}

void nus_set_state_callback(nus_state_cb_t state_cb)
{
    s_nus.state_cb = state_cb;
}

bool nus_is_connected(void)
{
    return s_nus.connected;
}

bool nus_is_advertising(void)
{
    return s_nus.advertising;
}

bool nus_is_notify_enabled(void)
{
    return (s_nus.tx_cccd_value & 0x0001) != 0;
}

uint16_t nus_get_mtu(void)
{
    return s_nus.mtu;
}

uint16_t nus_get_max_payload_len(void)
{
    return (s_nus.mtu > 3) ? (s_nus.mtu - 3) : 0;
}

esp_err_t nus_start_adv(uint32_t timeout_ms)
{
    if (s_nus.tx_queue == NULL) {
        return ESP_ERR_INVALID_STATE;
    }
    if (s_nus.connected) {
        return ESP_ERR_INVALID_STATE;
    }

    s_nus.adv_timeout_ms = timeout_ms;
    s_nus.adv_start_requested = true;

    if (!s_nus.adv_data_ready) {
        return ESP_OK;
    }

    if (s_nus.advertising) {
        nus_stop_adv_timeout_timer();
        nus_start_adv_timeout_timer(timeout_ms);
        return ESP_OK;
    }

    s_nus.adv_timed_out = false;
    esp_err_t err = esp_ble_gap_start_advertising(&s_adv_params);
    if (err != ESP_OK) {
        s_nus.adv_start_requested = false;
    }

    return err;
}

esp_err_t nus_stop_adv(void)
{
    if (s_nus.tx_queue == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    s_nus.adv_start_requested = false;
    s_nus.adv_timed_out = false;

    if (!s_nus.adv_data_ready || !s_nus.advertising) {
        nus_stop_adv_timeout_timer();
        return ESP_OK;
    }

    return esp_ble_gap_stop_advertising();
}

esp_err_t nus_send(const uint8_t *data, uint16_t len, TickType_t ticks_to_wait)
{
    if (data == NULL || len == 0) {
        return ESP_ERR_INVALID_ARG;
    }
    if (len > NUS_MAX_DATA_LEN) {
        return ESP_ERR_INVALID_SIZE;
    }
    if (s_nus.tx_queue == NULL || !nus_is_ready_to_send()) {
        return ESP_ERR_INVALID_STATE;
    }

    nus_tx_packet_t packet = {
        .len = len,
    };
    memcpy(packet.data, data, len);
    nus_store_tx_value(data, len);

    if (xQueueSend(s_nus.tx_queue, &packet, ticks_to_wait) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }

    nus_reset_idle_timeout();
    return ESP_OK;
}

void nus_flush_tx_queue(void)
{
    if (s_nus.tx_queue) {
        xQueueReset(s_nus.tx_queue);
    }
}

void nus_reset_idle_timeout(void)
{
    if (!s_nus.connected || s_nus.config.idle_timeout_ms == 0 || s_nus.idle_timer == NULL) {
        return;
    }

    xTimerChangePeriod(s_nus.idle_timer, nus_ms_to_ticks(s_nus.config.idle_timeout_ms), 0);
    xTimerStart(s_nus.idle_timer, 0);
}
