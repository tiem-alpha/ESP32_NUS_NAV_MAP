/*
 * Quản lý thông tin tĩnh và trạng thái động của thiết bị trên BLE protocol.
 */
#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Đăng ký handler SYSTEM_INFO và DEVICE_STATUS với nus_protocol. */
esp_err_t device_manager_init(void);

/* Chủ động gửi snapshot status hiện tại, dùng được khi status thay đổi. */
esp_err_t device_manager_send_status(void);

#ifdef __cplusplus
}
#endif
