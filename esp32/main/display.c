/*
 * SPDX-FileCopyrightText: 2026
 * SPDX-License-Identifier: Unlicense OR CC0-1.0
 *
 * display.c — ST7789 (esp_lcd SPI) + LVGL v8.3 full-screen map + overlay.
 *
 * Ràng buộc RAM (ESP32-H2, KHÔNG PSRAM): không cấp full framebuffer.
 * Dùng LVGL partial draw buffer theo tỉ lệ SCREEN_W × SCREEN_H.
 *
 * Map vẽ bằng custom draw (LV_EVENT_DRAW_MAIN của 1 obj full-screen) qua
 * lv_draw_line — KHÔNG lv_canvas. Overlay = widget LVGL con nền bán trong suốt.
 *
 * Mọi truy cập LVGL (UI update + lv_timer_handler) bọc trong mutex đệ quy.
 */
#include "display.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "esp_idf_version.h"

#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_heap_caps.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_vendor.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "lvgl.h"
#include "sdkconfig.h"

#include "clock_model.h"
#include "img.h"
#include "map_model.h"
#include "nav_model.h"
#include "nav_proto.h"
#include "projection.h"

#define DISP_TAG "DISPLAY"

/* Font Montserrat 12px subset Latin-1 + Latin Extended-A/B + Extended Additional
 * (lv_font_vi_12.c, sinh từ lv_font_conv) — phủ dấu tiếng Việt mà
 * CONFIG_LV_FONT_MONTSERRAT_12 (chỉ Basic Latin) không có. */
LV_FONT_DECLARE(lv_font_vi_12);

/* ── Cấu hình panel / draw buffer ────────────────────────────────────── */
#define LCD_H_RES        SCR_W
#define LCD_V_RES        SCR_H
/* Draw buffer theo tỉ lệ chiều cao, không phụ thuộc một độ phân giải cụ thể. */
#ifdef CONFIG_SPIRAM
  #define LCD_DRAW_LINES ((LCD_V_RES + 3) / 4)
#else
  #define LCD_DRAW_LINES ((LCD_V_RES + 7) / 8)
#endif
#define LCD_CMD_BITS     8
#define LCD_PARAM_BITS   8
#define LVGL_TICK_MS     2
#define LVGL_TASK_MS     16      /* ~60 Hz xử lý LVGL */
#define MAP_REFRESH_MS   150     /* ~6–7 Hz invalidate map (tiết kiệm CPU) */

/* ── Màu sắc (LVGL v8 lv_color_t) ────────────────────────────────────── */
#define COL_BG          lv_color_black()
#define COL_ROAD        lv_color_hex(0x707070)
#define COL_ROUTE       lv_color_hex(0x2A7CFF)
#define COL_USER        lv_color_white()
#define COL_PANEL       lv_color_hex(0x101418)
#define COL_TEXT        lv_color_white()
#define COL_DOT_ON      lv_color_hex(0x33D17A)  /* xanh lá: đã kết nối */
#define COL_DOT_OFF     lv_color_hex(0x606060)  /* xám: chưa kết nối */
#define COL_LIMIT_RING  lv_color_hex(0xD01010)  /* viền đỏ biển tốc độ */
#define COL_OVER_BG     lv_color_hex(0xD01010)  /* nền đỏ khi vượt tốc */

/* ── Trạng thái module ───────────────────────────────────────────────── */
static esp_lcd_panel_handle_t s_panel = NULL;
static lv_disp_drv_t          s_disp_drv;
static lv_disp_draw_buf_t     s_draw_buf;
static lv_disp_t             *s_disp = NULL;

static SemaphoreHandle_t s_lvgl_mutex = NULL;  /* đệ quy: bảo vệ mọi gọi LVGL */

/* Widget overlay (xây 1 lần trong display_init). */
static lv_obj_t *s_home_img     = NULL;  /* ảnh nền màn hình chính */
static lv_obj_t *s_home_clock   = NULL;  /* đồng hồ nổi trên ảnh nền */
static lv_obj_t *s_nav_layer    = NULL;  /* chứa toàn bộ giao diện dẫn đường */
static lv_obj_t *s_map_obj      = NULL;  /* obj full-screen, custom draw map */
static lv_obj_t *s_turn_label   = NULL;  /* mũi tên rẽ */
static lv_obj_t *s_dist_label   = NULL;  /* "350 m" */
static lv_obj_t *s_street_label = NULL;  /* tên đường */
static lv_obj_t *s_limit_panel  = NULL;  /* biển tốc độ (badge) */
static lv_obj_t *s_limit_label  = NULL;
static lv_obj_t *s_speed_label  = NULL;  /* "42 km/h" */
static lv_obj_t *s_eta_label    = NULL;  /* "14:32 · 6.2 km" */
static lv_obj_t *s_ble_dot      = NULL;  /* chấm trạng thái BLE */
static lv_obj_t *s_clock_label  = NULL;  /* đồng hồ thực "07:42" */

static bool s_connected     = false;  /* lưu state nếu UI chưa dựng */
static bool s_ui_ready      = false;
static bool s_navigation_active = false;
static bool s_mode_ready        = false;

/* ── Responsive layout helpers (tỉ lệ phần nghìn của màn hình) ─────────── */
static inline lv_coord_t ratio_w(uint16_t permille)
{
    lv_coord_t value = (lv_coord_t)(((uint32_t)LCD_H_RES * permille + 500u) / 1000u);
    return value > 0 ? value : 1;
}

static inline lv_coord_t ratio_h(uint16_t permille)
{
    lv_coord_t value = (lv_coord_t)(((uint32_t)LCD_V_RES * permille + 500u) / 1000u);
    return value > 0 ? value : 1;
}

static inline lv_coord_t ratio_min(uint16_t permille)
{
    const uint32_t side = LCD_H_RES < LCD_V_RES ? LCD_H_RES : LCD_V_RES;
    lv_coord_t value = (lv_coord_t)((side * permille + 500u) / 1000u);
    return value > 0 ? value : 1;
}

static const lv_font_t *font_for_ratio(uint16_t permille)
{
    lv_coord_t px = ratio_min(permille);
    if (px >= 22) return &lv_font_montserrat_24;
    if (px >= 19) return &lv_font_montserrat_20;
    if (px >= 16) return &lv_font_montserrat_18;
    if (px >= 13) return &lv_font_montserrat_14;
    if (px >= 11) return &lv_font_montserrat_12;
    if (px >= 9) return &lv_font_montserrat_10;
    return &lv_font_montserrat_8;
}

/* Snapshot chụp trước khi invalidate — dùng chung cho tất cả dải của 1 frame.
 * Đảm bảo mọi strip render cùng 1 bộ dữ liệu, không bị đứt đoạn giữa frame.
 * ESP32-S3 + PSRAM: cấp từ PSRAM (map_geom_t ~64 KB trên S3) — internal SRAM
 * giành cho DMA draw buffer + LVGL heap. H2: static .bss như cũ. */
#ifdef CONFIG_SPIRAM
  static map_geom_t *s_render_geom_p;
  #define s_render_geom (*s_render_geom_p)
#else
  static map_geom_t s_render_geom;
#endif
static map_pose_t s_render_pose;
static bool       s_render_ready = false;

/* ── Mutex helpers ───────────────────────────────────────────────────── */
static inline bool lvgl_lock(uint32_t timeout_ms)
{
    TickType_t ticks = (timeout_ms == 0) ? portMAX_DELAY : pdMS_TO_TICKS(timeout_ms);
    return xSemaphoreTakeRecursive(s_lvgl_mutex, ticks) == pdTRUE;
}
static inline void lvgl_unlock(void)
{
    xSemaphoreGiveRecursive(s_lvgl_mutex);
}

/* ── LVGL flush + panel callbacks ────────────────────────────────────── */

/* Panel báo xong DMA color-trans → cho LVGL biết flush đã ready (pattern chuẩn). */
static bool notify_flush_ready(esp_lcd_panel_io_handle_t io,
                               esp_lcd_panel_io_event_data_t *edata,
                               void *user_ctx)
{
    (void)io;
    (void)edata;
    lv_disp_drv_t *drv = (lv_disp_drv_t *)user_ctx;
    lv_disp_flush_ready(drv);
    return false;
}

/* LVGL flush 1 dải → đẩy bitmap ra ST7789. flush_ready gọi ở callback DMA. */
static void lvgl_flush_cb(lv_disp_drv_t *drv, const lv_area_t *area, lv_color_t *color_p)
{
    esp_lcd_panel_handle_t panel = (esp_lcd_panel_handle_t)drv->user_data;
    /* esp_lcd dùng x2/y2 exclusive (+1). */
    esp_lcd_panel_draw_bitmap(panel, area->x1, area->y1,
                              area->x2 + 1, area->y2 + 1, color_p);
}

/* esp_timer định kỳ → tick cho LVGL. */
static void lvgl_tick_cb(void *arg)
{
    (void)arg;
    lv_tick_inc(LVGL_TICK_MS);
}

/* ── Helpers chiếu/vẽ map ────────────────────────────────────────────── */

/* Kiểm tra 1 đoạn có giao vùng màn hình không (loại sớm đoạn ngoài hẳn). */
static inline bool seg_maybe_visible(const scr_pt_t *a, const scr_pt_t *b)
{
    if (a->x < 0 && b->x < 0)               return false;
    if (a->x >= LCD_H_RES && b->x >= LCD_H_RES) return false;
    if (a->y < 0 && b->y < 0)               return false;
    if (a->y >= LCD_V_RES && b->y >= LCD_V_RES) return false;
    return true;
}

/* Vẽ 1 polyline đã chiếu ra pixel. */
static void draw_polyline(lv_draw_ctx_t *draw_ctx, lv_draw_line_dsc_t *dsc,
                          const map_pt_t *pts, int n, const proj_ctx_t *proj)
{
    if (n < 2) {
        return;
    }
    scr_pt_t prev = projection_point(proj, pts[0].e_dm, pts[0].n_dm);
    for (int i = 1; i < n; i++) {
        scr_pt_t cur = projection_point(proj, pts[i].e_dm, pts[i].n_dm);
        if (seg_maybe_visible(&prev, &cur)) {
            lv_point_t p1 = { .x = prev.x, .y = prev.y };
            lv_point_t p2 = { .x = cur.x,  .y = cur.y  };
            lv_draw_line(draw_ctx, dsc, &p1, &p2);
        }
        prev = cur;
    }
}

/* Độ dày đường theo class: class nhỏ (đường lớn) → dày hơn. */
static inline lv_coord_t road_width_for_class(uint8_t road_class)
{
    if (road_class <= 1) return ratio_min(21); /* motorway/trunk */
    if (road_class <= 3) return ratio_min(17); /* primary/secondary */
    if (road_class <= 5) return ratio_min(13); /* tertiary/residential */
    return ratio_min(8);                         /* service/khác */
}

/* Vẽ mũi tên user: arrowhead khuyết đáy, fill trắng, hướng lên tại (USER_X, USER_Y).
 * 4 điểm: đỉnh trên → phải dưới → trọng tâm (indent đáy) → trái dưới.
 * Centroid = (USER_Y-10 + USER_Y+5 + USER_Y+5)/3 = USER_Y → vị trí GPS đúng tâm. */
static void draw_user_arrow(lv_draw_ctx_t *draw_ctx)
{
    const lv_coord_t half_w = ratio_min(29);
    const lv_coord_t tip_h = ratio_min(42);
    const lv_coord_t tail_h = ratio_min(21);
    const lv_point_t arrow[4] = {
        { USER_X,          USER_Y - tip_h  }, /* đỉnh trên */
        { USER_X + half_w, USER_Y + tail_h }, /* phải dưới */
        { USER_X,          USER_Y          }, /* indent đáy */
        { USER_X - half_w, USER_Y + tail_h }, /* trái dưới */
    };

    lv_draw_line_dsc_t dsc;
    lv_draw_line_dsc_init(&dsc);
    dsc.color = COL_USER;
    dsc.width = ratio_min(13);
    dsc.round_start = 1;
    dsc.round_end = 1;

    for (int i = 0; i < 3; i++) {
        lv_draw_line(draw_ctx, &dsc, &arrow[i], &arrow[i + 1]);
    }
    lv_draw_line(draw_ctx, &dsc, &arrow[3], &arrow[0]);
}

/* Custom draw map: chạy trong LV_EVENT_DRAW_MAIN của s_map_obj. */
static void map_draw_event_cb(lv_event_t *e)
{
    if (lv_event_get_code(e) != LV_EVENT_DRAW_MAIN) {
        return;
    }
    lv_draw_ctx_t *draw_ctx = lv_event_get_draw_ctx(e);
    if (!draw_ctx) {
        return;
    }

    /* Dùng snapshot đã chụp trong lvgl_task trước khi invalidate.
     * Đảm bảo tất cả dải strip của 1 frame dùng cùng dữ liệu — không đứt đoạn. */
    if (!s_render_ready) {
        return;
    }

    proj_ctx_t proj;
    projection_begin(&proj, &s_render_geom, &s_render_pose);

    /* 1) Roads (xám, độ dày theo class). */
    lv_draw_line_dsc_t road_dsc;
    lv_draw_line_dsc_init(&road_dsc);
    road_dsc.color = COL_ROAD;
    road_dsc.round_start = 1;
    road_dsc.round_end = 1;
    for (int r = 0; r < s_render_geom.road_n; r++) {
        const map_road_t *road = &s_render_geom.roads[r];
        if ((uint32_t)road->first_pt + road->n > s_render_geom.road_pt_n) continue;
        road_dsc.width = road_width_for_class(road->road_class);
        draw_polyline(draw_ctx, &road_dsc,
                      &s_render_geom.road_pts[road->first_pt], road->n, &proj);
    }

    /* 2) Route (xanh, dày ~6). */
    lv_draw_line_dsc_t route_dsc;
    lv_draw_line_dsc_init(&route_dsc);
    route_dsc.color = COL_ROUTE;
    route_dsc.width = ratio_min(25);
    route_dsc.round_start = 1;
    route_dsc.round_end = 1;
    draw_polyline(draw_ctx, &route_dsc, s_render_geom.route, s_render_geom.route_n, &proj);

    /* 3) Mũi tên user trên cùng. */
    draw_user_arrow(draw_ctx);
}

/* ── Overlay: helper ─────────────────────────────────────────────────── */

/* Tạo panel bán trong suốt bo góc làm nền overlay. */
static lv_obj_t *make_panel(lv_obj_t *parent)
{
    lv_obj_t *p = lv_obj_create(parent);
    lv_obj_clear_flag(p, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_style_bg_color(p, COL_PANEL, 0);
    lv_obj_set_style_bg_opa(p, LV_OPA_70, 0);
    lv_obj_set_style_border_width(p, 0, 0);
    lv_obj_set_style_radius(p, ratio_min(33), 0);
    lv_obj_set_style_pad_all(p, ratio_min(25), 0);
    return p;
}

/* Glyph mũi tên theo maneuver (dùng ký tự ASCII/Unicode đơn giản). */
static const char *maneuver_glyph(maneuver_e m)
{
    switch (m) {
    case MAN_TURN_LEFT:
    case MAN_TURN_SLIGHT_LEFT:
    case MAN_TURN_SHARP_LEFT:
    case MAN_EXIT_LEFT:
    case MAN_ARRIVE_LEFT:
        return LV_SYMBOL_LEFT;
    case MAN_TURN_RIGHT:
    case MAN_TURN_SLIGHT_RIGHT:
    case MAN_TURN_SHARP_RIGHT:
    case MAN_EXIT_RIGHT:
    case MAN_ARRIVE_RIGHT:
        return LV_SYMBOL_RIGHT;
    case MAN_UTURN:
        return LV_SYMBOL_LOOP;
    case MAN_ARRIVE:
        return LV_SYMBOL_OK;
    case MAN_STRAIGHT:
    case MAN_DEPART:
    default:
        return LV_SYMBOL_UP;
    }
}

/* ── Xây UI ──────────────────────────────────────────────────────────── */
static void build_ui(void)
{
    const lv_coord_t margin = ratio_min(17);
    const lv_coord_t top_h = ratio_h(160);
    const lv_coord_t badge_size = ratio_min(192);
    const lv_coord_t bottom_h = ratio_h(106);
    const lv_coord_t left_text_x = ratio_w(150);

    lv_obj_t *scr = lv_scr_act();
    lv_obj_set_style_bg_color(scr, COL_BG, 0);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, 0);

    /* Màn hình chính: ảnh 240x320 và đồng hồ nổi trong vùng trời phía trên. */
    s_home_img = lv_img_create(scr);
    lv_img_set_src(s_home_img, &img);
    lv_obj_center(s_home_img);
    lv_obj_clear_flag(s_home_img, LV_OBJ_FLAG_CLICKABLE | LV_OBJ_FLAG_SCROLLABLE);

    /* Toàn bộ UI dẫn đường nằm trong một layer để đổi màn hình nguyên khối. */
    s_nav_layer = lv_obj_create(scr);
    lv_obj_remove_style_all(s_nav_layer);
    lv_obj_set_size(s_nav_layer, LCD_H_RES, LCD_V_RES);
    lv_obj_set_pos(s_nav_layer, 0, 0);
    lv_obj_clear_flag(s_nav_layer, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_style_bg_color(s_nav_layer, COL_BG, 0);
    lv_obj_set_style_bg_opa(s_nav_layer, LV_OPA_COVER, 0);

    /* Layer nền: obj full-screen trong suốt với custom draw vẽ map. */
    s_map_obj = lv_obj_create(s_nav_layer);
    lv_obj_remove_style_all(s_map_obj);
    lv_obj_set_size(s_map_obj, LCD_H_RES, LCD_V_RES);
    lv_obj_set_pos(s_map_obj, 0, 0);
    lv_obj_clear_flag(s_map_obj, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_style_bg_opa(s_map_obj, LV_OPA_TRANSP, 0);
    lv_obj_add_event_cb(s_map_obj, map_draw_event_cb, LV_EVENT_DRAW_MAIN, NULL);

    /* ── Overlay TRÊN-TRÁI: mũi tên rẽ + khoảng cách + tên đường. ── */
    lv_obj_t *top_left = make_panel(s_nav_layer);
    lv_coord_t top_w = LCD_H_RES - badge_size - margin * 3;
    if (top_w < ratio_w(500)) top_w = ratio_w(500);
    lv_obj_set_size(top_left, top_w, top_h);
    lv_obj_align(top_left, LV_ALIGN_TOP_LEFT, margin, margin);

    s_turn_label = lv_label_create(top_left);
    lv_obj_set_style_text_font(s_turn_label, font_for_ratio(100), 0);
    lv_obj_set_style_text_color(s_turn_label, COL_TEXT, 0);
    lv_label_set_text(s_turn_label, LV_SYMBOL_UP);
    lv_obj_align(s_turn_label, LV_ALIGN_LEFT_MID, 0, -ratio_h(25));

    s_dist_label = lv_label_create(top_left);
    lv_obj_set_style_text_font(s_dist_label, font_for_ratio(83), 0);
    lv_obj_set_style_text_color(s_dist_label, COL_TEXT, 0);
    lv_label_set_text(s_dist_label, "-- m");
    lv_obj_align(s_dist_label, LV_ALIGN_TOP_LEFT, left_text_x, 0);

    s_street_label = lv_label_create(top_left);
    lv_obj_set_style_text_font(s_street_label, &lv_font_vi_12, 0);
    lv_obj_set_style_text_color(s_street_label, COL_TEXT, 0);
    lv_label_set_long_mode(s_street_label, LV_LABEL_LONG_DOT);
    lv_coord_t street_w = top_w - left_text_x - ratio_min(50);
    lv_obj_set_width(s_street_label, street_w > 1 ? street_w : 1);
    lv_label_set_text(s_street_label, "");
    lv_obj_align(s_street_label, LV_ALIGN_BOTTOM_LEFT, left_text_x, 0);

    /* ── Overlay TRÊN-PHẢI: biển tốc độ (badge tròn). ── */
    s_limit_panel = lv_obj_create(s_nav_layer);
    lv_obj_clear_flag(s_limit_panel, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_size(s_limit_panel, badge_size, badge_size);
    lv_obj_align(s_limit_panel, LV_ALIGN_TOP_RIGHT, -margin, margin);
    lv_obj_set_style_radius(s_limit_panel, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(s_limit_panel, lv_color_white(), 0);
    lv_obj_set_style_bg_opa(s_limit_panel, LV_OPA_COVER, 0);
    lv_obj_set_style_border_color(s_limit_panel, COL_LIMIT_RING, 0);
    lv_obj_set_style_border_width(s_limit_panel, ratio_min(17), 0);
    lv_obj_set_style_pad_all(s_limit_panel, 0, 0);

    s_limit_label = lv_label_create(s_limit_panel);
    lv_obj_set_style_text_font(s_limit_label, font_for_ratio(75), 0);
    lv_obj_set_style_text_color(s_limit_label, lv_color_black(), 0);
    lv_label_set_text(s_limit_label, "");
    lv_obj_center(s_limit_label);
    lv_obj_add_flag(s_limit_panel, LV_OBJ_FLAG_HIDDEN);  /* ẩn tới khi có limit */

    /* ── Overlay DƯỚI-TRÁI: tốc độ hiện tại. ── */
    lv_obj_t *bot_left = make_panel(s_nav_layer);
    lv_obj_set_size(bot_left, ratio_w(417), bottom_h);
    lv_obj_align(bot_left, LV_ALIGN_BOTTOM_LEFT, margin, -margin);

    s_speed_label = lv_label_create(bot_left);
    lv_obj_set_style_text_font(s_speed_label, font_for_ratio(75), 0);
    lv_obj_set_style_text_color(s_speed_label, COL_TEXT, 0);
    lv_label_set_text(s_speed_label, "0 km/h");
    lv_obj_center(s_speed_label);

    /* ── Overlay DƯỚI-PHẢI: ETA + còn lại. ── */
    lv_obj_t *bot_right = make_panel(s_nav_layer);
    lv_obj_set_size(bot_right, ratio_w(500), bottom_h);
    lv_obj_align(bot_right, LV_ALIGN_BOTTOM_RIGHT, -margin, -margin);

    s_eta_label = lv_label_create(bot_right);
    lv_obj_set_style_text_font(s_eta_label, font_for_ratio(58), 0);
    lv_obj_set_style_text_color(s_eta_label, COL_TEXT, 0);
    lv_label_set_text(s_eta_label, "--:-- · -- km");
    lv_obj_center(s_eta_label);

    /* ── Chấm trạng thái BLE (góc trên giữa). ── */
    s_ble_dot = lv_obj_create(s_nav_layer);
    lv_obj_clear_flag(s_ble_dot, LV_OBJ_FLAG_SCROLLABLE);
    lv_coord_t dot_size = ratio_min(50);
    lv_obj_set_size(s_ble_dot, dot_size, dot_size);
    lv_obj_align(s_ble_dot, LV_ALIGN_TOP_MID, 0, ratio_h(19));
    lv_obj_set_style_radius(s_ble_dot, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_border_width(s_ble_dot, 0, 0);
    lv_obj_set_style_bg_color(s_ble_dot, s_connected ? COL_DOT_ON : COL_DOT_OFF, 0);
    lv_obj_set_style_bg_opa(s_ble_dot, LV_OPA_COVER, 0);

    // /* ── Đồng hồ thực, ngay dưới chấm BLE (giữa-trên). ── */
    // lv_obj_t *clock_panel = make_panel(scr);
    // lv_obj_set_size(clock_panel, 64, 24);
    // lv_obj_align(clock_panel, LV_ALIGN_TOP_MID, 0, 22);

    s_clock_label = lv_label_create(top_left);
    lv_obj_set_style_text_font(s_clock_label, font_for_ratio(83), 0);
    lv_obj_set_style_text_color(s_clock_label, COL_TEXT, 0);
    lv_label_set_text(s_clock_label, "--:--");
    lv_obj_align(s_clock_label, LV_ALIGN_TOP_RIGHT, 0, 0);

    lv_obj_t *home_clock_panel = make_panel(scr);
    lv_obj_set_size(home_clock_panel, ratio_w(500), ratio_h(125));
    lv_obj_align(home_clock_panel, LV_ALIGN_TOP_MID, 0, ratio_h(53));
    lv_obj_set_style_bg_opa(home_clock_panel, LV_OPA_50, 0);
    lv_obj_set_style_pad_all(home_clock_panel, 0, 0);

    s_home_clock = lv_label_create(home_clock_panel);
    lv_obj_set_style_text_font(s_home_clock, &lv_font_montserrat_24, 0);
    lv_obj_set_style_text_color(s_home_clock, COL_TEXT, 0);
    lv_label_set_text(s_home_clock, "--:--");
    lv_obj_center(s_home_clock);

    /* Trạng thái ban đầu của nav_model là IDLE. */
    lv_obj_add_flag(s_nav_layer, LV_OBJ_FLAG_HIDDEN);
    s_navigation_active = false;
    s_mode_ready = true;

    s_ui_ready = true;
}

static void set_navigation_mode(bool active)
{
    if (s_mode_ready && s_navigation_active == active) {
        return;
    }

    s_navigation_active = active;
    s_mode_ready = true;

    if (active) {
        lv_obj_add_flag(s_home_img, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(lv_obj_get_parent(s_home_clock), LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(s_nav_layer, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_clear_flag(s_home_img, LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(lv_obj_get_parent(s_home_clock), LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(s_nav_layer, LV_OBJ_FLAG_HIDDEN);
        s_render_ready = false;
    }
}

/* ── Cập nhật overlay từ nav_model ───────────────────────────────────── */
static void overlay_update(void)
{
    nav_overlay_t ov;
    nav_model_get(&ov);

    char buf[48];

    const bool active = ov.state == NAV_NAVIGATING || ov.state == NAV_REROUTING;
    set_navigation_mode(active);

    /* Đồng hồ dùng chung cho màn hình chính và overlay dẫn đường. */
    uint8_t clk_h, clk_m;
    if (clock_model_get_local(&clk_h, &clk_m)) {
        snprintf(buf, sizeof(buf), "%02u:%02u", (unsigned)clk_h, (unsigned)clk_m);
        lv_label_set_text(s_clock_label, buf);
        lv_label_set_text(s_home_clock, buf);
    } else {
        lv_label_set_text(s_clock_label, "--:--");
        lv_label_set_text(s_home_clock, "--:--");
    }

    if (!active) {
        return;
    }

    /* Mũi tên rẽ + khoảng cách. */
    if (ov.has_instruction) {
        lv_label_set_text(s_turn_label, maneuver_glyph(ov.maneuver));
        if (ov.dist_to_man_m >= 1000) {
            snprintf(buf, sizeof(buf), "%.1f km", ov.dist_to_man_m / 1000.0f);
        } else {
            snprintf(buf, sizeof(buf), "%u m", (unsigned)ov.dist_to_man_m);
        }
        lv_label_set_text(s_dist_label, buf);
        lv_label_set_text(s_street_label, ov.street);
    } else {
        lv_label_set_text(s_turn_label, LV_SYMBOL_UP);
        lv_label_set_text(s_dist_label, "-- m");
        lv_label_set_text(s_street_label, "");
    }

    /* Tốc độ hiện tại. */
    snprintf(buf, sizeof(buf), "%u km/h", (unsigned)ov.speed_kmh);
    lv_label_set_text(s_speed_label, buf);

    /* ETA + quãng còn lại. */
    if (ov.eta_min > 0 || ov.dist_remain_m > 0) {
        unsigned h = ov.eta_min / 60u;
        unsigned m = ov.eta_min % 60u;
        snprintf(buf, sizeof(buf), "%u:%02u · %.1f km",
                 h, m, ov.dist_remain_m / 1000.0f);
        lv_label_set_text(s_eta_label, buf);
    } else {
        lv_label_set_text(s_eta_label, "--:-- · -- km");
    }

    /* Biển tốc độ: hiện khi >0, đỏ nền khi vượt. */
    if (ov.speed_limit_kmh > 0) {
        snprintf(buf, sizeof(buf), "%u", (unsigned)ov.speed_limit_kmh);
        lv_label_set_text(s_limit_label, buf);
        lv_obj_clear_flag(s_limit_panel, LV_OBJ_FLAG_HIDDEN);
        if (ov.is_over) {
            lv_obj_set_style_bg_color(s_limit_panel, COL_OVER_BG, 0);
            lv_obj_set_style_text_color(s_limit_label, lv_color_white(), 0);
        } else {
            lv_obj_set_style_bg_color(s_limit_panel, lv_color_white(), 0);
            lv_obj_set_style_text_color(s_limit_label, lv_color_black(), 0);
        }
    } else {
        lv_obj_add_flag(s_limit_panel, LV_OBJ_FLAG_HIDDEN);
    }
}

/* ── LVGL task ───────────────────────────────────────────────────────── */
static void lvgl_task(void *arg)
{
    (void)arg;
    uint32_t since_map_ms = 0;

    for (;;) {
        if (lvgl_lock(0)) {
            since_map_ms += LVGL_TASK_MS;
            if (s_ui_ready && since_map_ms >= MAP_REFRESH_MS) {
                since_map_ms = 0;

                /* Overlay + map trong cùng 1 chu kỳ → 1 lần redraw duy nhất,
                 * tránh partial redraws lệch pha gây giật. */
                overlay_update();

                /* Chụp snapshot pose + geom TRƯỚC khi invalidate.
                 * map_draw_event_cb (gọi 1 lần/dải) dùng lại snapshot này
                 * → mọi strip thấy cùng dữ liệu, không đứt đoạn giữa frame. */
                if (s_navigation_active && map_model_has_pose()) {
                    map_model_get_pose(&s_render_pose);
                    const map_geom_t *g = map_model_lock_geom();
                    if (g) {
                        s_render_geom  = *g;
                        map_model_unlock_geom();
                        s_render_ready = true;
                    } else {
                        s_render_ready = false;
                    }
                } else {
                    s_render_ready = false;
                }

                if (s_navigation_active) {
                    lv_obj_invalidate(s_map_obj);
                }
            }
            lv_timer_handler();
            lvgl_unlock();
        }
        vTaskDelay(pdMS_TO_TICKS(LVGL_TASK_MS));
    }
}

/* ── Khởi tạo panel ST7789 qua esp_lcd ───────────────────────────────── */
static esp_lcd_panel_io_handle_t panel_init(void)
{
    /* Backlight bật trước (nếu có chân). */
#if CONFIG_LCD_BL_GPIO >= 0
    gpio_config_t bl_cfg = {
        .mode = GPIO_MODE_OUTPUT,
        .pin_bit_mask = 1ULL << CONFIG_LCD_BL_GPIO,
    };
    gpio_config(&bl_cfg);
    gpio_set_level(CONFIG_LCD_BL_GPIO, 1);
#endif

    /* SPI bus (SPI2_HOST). max_transfer = 1 dải draw buffer. */
    spi_bus_config_t bus_cfg = {
        .mosi_io_num = CONFIG_LCD_MOSI_GPIO,
        .sclk_io_num = CONFIG_LCD_SCLK_GPIO,
        .miso_io_num = -1,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = LCD_H_RES * LCD_DRAW_LINES * sizeof(lv_color_t),
    };
    ESP_ERROR_CHECK(spi_bus_initialize(SPI2_HOST, &bus_cfg, SPI_DMA_CH_AUTO));

    /* Panel IO (SPI). color-trans-done → notify_flush_ready. */
    esp_lcd_panel_io_handle_t io = NULL;
    esp_lcd_panel_io_spi_config_t io_cfg = {
        .dc_gpio_num = CONFIG_LCD_DC_GPIO,
        .cs_gpio_num = CONFIG_LCD_CS_GPIO,
        .pclk_hz = CONFIG_LCD_SPI_CLOCK_MHZ * 1000 * 1000,
        .lcd_cmd_bits = LCD_CMD_BITS,
        .lcd_param_bits = LCD_PARAM_BITS,
        .spi_mode = 0,
        .trans_queue_depth = 10,
        .on_color_trans_done = notify_flush_ready,
        .user_ctx = &s_disp_drv,
    };
    ESP_ERROR_CHECK(esp_lcd_new_panel_io_spi(SPI2_HOST, &io_cfg, &io));

    /* Panel ST7789. Tên field thứ tự màu đổi giữa các bản IDF v5.x:
     * >=5.3 dùng rgb_ele_order; cũ hơn dùng rgb_endian. */
    esp_lcd_panel_dev_config_t panel_cfg = {
        .reset_gpio_num = CONFIG_LCD_RST_GPIO,
#if ESP_IDF_VERSION >= ESP_IDF_VERSION_VAL(5, 3, 0)
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
#else
        .rgb_endian = LCD_RGB_ENDIAN_RGB,
#endif
        .bits_per_pixel = 16,
    };
    ESP_ERROR_CHECK(esp_lcd_new_panel_st7789(io, &panel_cfg, &s_panel));

    ESP_ERROR_CHECK(esp_lcd_panel_reset(s_panel));
    ESP_ERROR_CHECK(esp_lcd_panel_init(s_panel));
    /* ST7789 thường cần đảo màu để hiển thị đúng. */
    ESP_ERROR_CHECK(esp_lcd_panel_invert_color(s_panel, false));
    ESP_ERROR_CHECK(esp_lcd_panel_disp_on_off(s_panel, true));

    return io;
}

/* ── API công khai ───────────────────────────────────────────────────── */
void display_init(void)
{
    /* Mutex đệ quy bảo vệ mọi gọi LVGL. */
    s_lvgl_mutex = xSemaphoreCreateRecursiveMutex();

#ifdef CONFIG_SPIRAM
    /* Snapshot render từ PSRAM — trên S3 map_geom_t ~64 KB.
     * LVGL không đọc trực tiếp buffer này qua DMA nên PSRAM là OK. */
    s_render_geom_p = heap_caps_malloc(sizeof(map_geom_t), MALLOC_CAP_SPIRAM);
    assert(s_render_geom_p);
    memset(s_render_geom_p, 0, sizeof(map_geom_t));
    ESP_LOGI(DISP_TAG, "render_geom in PSRAM (%u B)", (unsigned)sizeof(map_geom_t));
#endif

    /* 1) Panel ST7789. */
    panel_init();

    /* 2) LVGL + partial draw buffer (DMA internal RAM — bắt buộc, SPI DMA
     * không truy cập PSRAM trực tiếp trên cả H2 và S3 SPI mode). */
    lv_init();

    size_t buf_px = LCD_H_RES * LCD_DRAW_LINES;
    lv_color_t *buf1 = heap_caps_malloc(buf_px * sizeof(lv_color_t),
                                        MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    lv_color_t *buf2 = heap_caps_malloc(buf_px * sizeof(lv_color_t),
                                        MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    assert(buf1 && buf2);
    lv_disp_draw_buf_init(&s_draw_buf, buf1, buf2, buf_px);

    lv_disp_drv_init(&s_disp_drv);
    s_disp_drv.hor_res   = LCD_H_RES;
    s_disp_drv.ver_res   = LCD_V_RES;
    s_disp_drv.flush_cb  = lvgl_flush_cb;
    s_disp_drv.draw_buf  = &s_draw_buf;
    s_disp_drv.user_data = s_panel;
    s_disp = lv_disp_drv_register(&s_disp_drv);

    /* 3) LVGL tick qua esp_timer định kỳ. */
    const esp_timer_create_args_t tick_args = {
        .callback = lvgl_tick_cb,
        .name = "lv_tick",
    };
    esp_timer_handle_t tick_timer = NULL;
    ESP_ERROR_CHECK(esp_timer_create(&tick_args, &tick_timer));
    ESP_ERROR_CHECK(esp_timer_start_periodic(tick_timer, LVGL_TICK_MS * 1000));

    /* 4) Dựng UI (bọc mutex). */
    if (lvgl_lock(0)) {
        build_ui();
        lvgl_unlock();
    }

    /* 5) Task render LVGL.
     * S3 dual-core: pin vào core 1 (APP_CPU) để BLE task chạy độc lập core 0.
     * H2 single-core: xTaskCreate thường (core không quan trọng). */
#ifdef CONFIG_SPIRAM
    xTaskCreatePinnedToCore(lvgl_task, "lvgl_task", 12 * 1024, NULL, 2, NULL, 1);
#else
    xTaskCreate(lvgl_task, "lvgl_task", 8 * 1024, NULL, 2, NULL);
#endif

    ESP_LOGI(DISP_TAG, "Display + LVGL ready (partial buf %dx%d x2)",
             LCD_H_RES, LCD_DRAW_LINES);
}

void display_set_connected(bool connected)
{
    s_connected = connected;
    if (!s_lvgl_mutex) {
        return;  /* gọi quá sớm: chỉ lưu state, build_ui sẽ áp dụng */
    }
    if (lvgl_lock(100)) {
        if (s_ui_ready) {
            if (s_ble_dot) {
                lv_obj_set_style_bg_color(s_ble_dot,
                                          connected ? COL_DOT_ON : COL_DOT_OFF, 0);
            }
            if (!connected) {
                /* Mất BLE: rời giao diện dẫn đường và về màn hình chính ngay. */
                set_navigation_mode(false);
            }
        }
        lvgl_unlock();
    }
}
