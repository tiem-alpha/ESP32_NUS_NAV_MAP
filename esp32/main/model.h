#pragma once

/*
 * Thông tin tĩnh của một biến thể phần cứng.
 * Mobile đọc SYSTEM_INFO đúng một lần khi ghép thiết bị và cache theo BLE ID.
 */
#define FIRMWARE_VERSION  0x0100u
#define HARDWARE_VERSION  1u

#define VENDOR_ID          0x00001234u
#define MODEL_ID           0x00005678u
#define PRODUCT_ID         0x00009ABCu

#define MANUFACTURER_DATE  "2026-06-01"
#define SERIAL_NUMBER      "SN1234567890"
#define MCU_DESC           "ESP32-H2"

#define SUPPORT_BATTERY    0u

#define SUPPORT_SCREEN     1u
#define SCREEN_TYPE        2u /* 0: none, 1: mono, 2: RGB565, 3: RGB888 */
#define SCREEN_W           240u
#define SCREEN_H           320u
