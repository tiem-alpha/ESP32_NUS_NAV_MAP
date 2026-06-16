/*
 * nus_protocol.h — Tầng khung (frame) trên NUS: deframe SOF..CRC16, verify
 * CRC16/MCRF4XX, dispatch theo TYPE; encode + gửi frame; auto-ACK gói quan trọng.
 * Transport-agnostic: nhận byte qua nus_protocol_feed(), gửi qua tx callback.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"
#include "nav_proto.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Hàm gửi byte ra transport (bọc nus_send). wait_ms = thời gian chờ tx queue. */
typedef esp_err_t (*nus_proto_tx_fn)(const uint8_t *data, uint16_t len, uint32_t wait_ms);

/* Handler cho 1 TYPE. payload đã verify CRC, len = độ dài payload. */
typedef void (*nus_proto_handler_t)(uint8_t type, const uint8_t *payload, uint16_t len, void *ctx);

/* Khởi tạo. auto_ack=true → tự gửi ACK cho NAV_INSTRUCTION & NAV_STATE. */
esp_err_t nus_protocol_init(nus_proto_tx_fn tx, bool auto_ack);

/* Đăng ký handler theo TYPE (decouple feature khỏi parser). */
void nus_protocol_register(uint8_t type, nus_proto_handler_t handler, void *ctx);

/* Nạp byte stream từ NUS RX callback (chịu được fragment). */
void nus_protocol_feed(const uint8_t *data, uint16_t len);

/* Đóng frame (SOF|TYPE|LEN|PAYLOAD|CRC) rồi gửi. len ≤ NAV_PROTO_MAX_PAYLOAD. */
esp_err_t nus_protocol_send(uint8_t type, const uint8_t *payload, uint16_t len);

/* Tiện ích gửi ACK. */
void nus_protocol_send_ack(uint8_t acked_type, uint8_t seq);

#ifdef __cplusplus
}
#endif
