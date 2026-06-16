/*
 * clock_model.h — Đồng hồ thực (TYPE 0x33 MAP_CLOCK). Phone đồng bộ epoch UTC +
 * lệch giờ địa phương mỗi ~30 s; giữa các lần sync, tick nội bộ bằng
 * esp_timer_get_time() (monotonic) để hiển thị mượt không cần BLE liên tục.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void clock_model_init(void);  /* đăng ký handler 0x33 */

/* true nếu đã nhận sync ít nhất 1 lần; out_h/out_m = giờ:phút địa phương hiện tại. */
bool clock_model_get_local(uint8_t *out_h, uint8_t *out_m);

#ifdef __cplusplus
}
#endif
