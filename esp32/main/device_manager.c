#include "device_manager.h"

#include <limits.h>
#include <string.h>

#include "esp_heap_caps.h"
#include "esp_timer.h"

#include "model.h"
#include "nav_proto.h"
#include "nus_protocol.h"

#define SYSTEM_INFO_FIXED_LEN 28u
#define DEVICE_STATUS_LEN     20u

static uint8_t text_len_u8(const char *text)
{
    size_t len = strlen(text);
    return (uint8_t)(len > UINT8_MAX ? UINT8_MAX : len);
}

static esp_err_t send_system_info(void)
{
    const uint8_t date_len = text_len_u8(MANUFACTURER_DATE);
    const uint8_t serial_len = text_len_u8(SERIAL_NUMBER);
    const uint8_t mcu_len = text_len_u8(MCU_DESC);
    uint8_t payload[SYSTEM_INFO_FIXED_LEN + sizeof(MANUFACTURER_DATE) +
                    sizeof(SERIAL_NUMBER) + sizeof(MCU_DESC)];

    payload[0] = SYSTEM_INFO_SCHEMA_V1;
    wr_u32(&payload[1], VENDOR_ID);
    wr_u32(&payload[5], MODEL_ID);
    wr_u32(&payload[9], PRODUCT_ID);
    wr_u32(&payload[13], HARDWARE_VERSION);
    payload[17] = SUPPORT_BATTERY ? 1u : 0u;
    payload[18] = SUPPORT_SCREEN ? 1u : 0u;
    payload[19] = SCREEN_TYPE;
    payload[20] = 0; /* reserved */
    wr_u16(&payload[21], SCREEN_W);
    wr_u16(&payload[23], SCREEN_H);
    payload[25] = date_len;
    payload[26] = serial_len;
    payload[27] = mcu_len;

    uint16_t offset = SYSTEM_INFO_FIXED_LEN;
    memcpy(&payload[offset], MANUFACTURER_DATE, date_len);
    offset += date_len;
    memcpy(&payload[offset], SERIAL_NUMBER, serial_len);
    offset += serial_len;
    memcpy(&payload[offset], MCU_DESC, mcu_len);
    offset += mcu_len;

    return nus_protocol_send(MSG_SYSTEM_INFO, payload, offset);
}

esp_err_t device_manager_send_status(void)
{
    uint8_t payload[DEVICE_STATUS_LEN];
    uint16_t flags = DEVICE_STATUS_SCREEN_ON;

#if SUPPORT_BATTERY
    flags |= DEVICE_STATUS_BATTERY_PRESENT;
#endif

    payload[0] = DEVICE_STATUS_SCHEMA_V1;
    wr_u16(&payload[1], flags);
    payload[3] = DEVICE_STATUS_VALUE_UNKNOWN;
    wr_u16(&payload[4], 0); /* supply voltage unavailable */
    wr_u16(&payload[6], (uint16_t)DEVICE_STATUS_TEMP_UNKNOWN);
    wr_u32(&payload[8], 0); /* input pin bitmask; board integration can update later */
    wr_u32(&payload[12], (uint32_t)(esp_timer_get_time() / 1000000ULL));
    wr_u32(&payload[16], (uint32_t)heap_caps_get_free_size(MALLOC_CAP_8BIT));

    return nus_protocol_send(MSG_DEVICE_STATUS, payload, sizeof(payload));
}

static void on_system_info_request(uint8_t type, const uint8_t *payload,
                                   uint16_t len, void *ctx)
{
    (void)type;
    (void)payload;
    (void)len;
    (void)ctx;
    send_system_info();
}

static void on_device_status_request(uint8_t type, const uint8_t *payload,
                                     uint16_t len, void *ctx)
{
    (void)type;
    (void)payload;
    (void)len;
    (void)ctx;
    device_manager_send_status();
}

esp_err_t device_manager_init(void)
{
    nus_protocol_register(MSG_SYSTEM_INFO, on_system_info_request, NULL);
    nus_protocol_register(MSG_DEVICE_STATUS, on_device_status_request, NULL);
    return ESP_OK;
}
