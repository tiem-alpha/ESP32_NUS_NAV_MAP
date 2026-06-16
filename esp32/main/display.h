/*
 * display.h — ST7789 (esp_lcd) + LVGL v8 full-screen map + overlay.
 * display_init() dựng panel + LVGL (partial draw buffer, KHÔNG full framebuffer
 * vì H2 không PSRAM) + UI, và chạy task render đọc nav_model/map_model mỗi khung.
 */
#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

void display_init(void);
void display_set_connected(bool connected);

#ifdef __cplusplus
}
#endif
