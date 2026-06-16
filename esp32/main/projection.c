/*
 * SPDX-FileCopyrightText: 2026
 * SPDX-License-Identifier: Unlicense OR CC0-1.0
 *
 * projection.c — Chiếu hình học mét north-up (offset dm so với anchor) → pixel
 * màn hình, heading-up, user neo giữa-dưới. Toán thuần float (đủ nhanh trên
 * RISC-V H2; vòng vẽ gọi projection_point cho từng đỉnh polyline).
 */
#include "projection.h"

#include <math.h>
#include <stdint.h>

/* Hằng số chuyển độ → mét (xấp xỉ Trái Đất cầu). */
#define DEG_E7_TO_RAD   (1e-7 * (M_PI / 180.0))
#define M_PER_DEG_LAT   111320.0   /* mét cho 1 độ vĩ */

/*
 * Zoom (px_per_dm) khớp đúng tỷ lệ zoom điện thoại:
 *   - 1 dm = 0.1 m, nên px_per_dm = px_per_m / 10.
 *   - pose->view_span_dm = số mét×10 mà TOÀN CHIỀU RỘNG màn hình điện thoại
 *     đang hiển thị (App tính từ widget width × metersPerPixel ở zoom dẫn
 *     đường) → px_per_dm = SCR_W / view_span_dm cho HUD hiển thị đúng cùng
 *     số mét đó trên toàn chiều rộng của nó.
 *   - Kẹp về dải an toàn để tránh scale rác khi view_span_dm bất thường.
 */
#define ZOOM_PX_PER_DM_MIN   0.02f   /* view_span rất lớn (zoom xa) */
#define ZOOM_PX_PER_DM_MAX   0.40f   /* view_span rất nhỏ (zoom gần) */

static inline float px_per_dm_from_span(uint16_t view_span_dm)
{
    if (view_span_dm == 0) {
        view_span_dm = 1; /* tránh chia 0; map_model đã default trước đó */
    }
    float px_per_dm = (float)SCR_W / (float)view_span_dm;
    if (px_per_dm < ZOOM_PX_PER_DM_MIN) px_per_dm = ZOOM_PX_PER_DM_MIN;
    if (px_per_dm > ZOOM_PX_PER_DM_MAX) px_per_dm = ZOOM_PX_PER_DM_MAX;
    return px_per_dm;
}

void projection_begin(proj_ctx_t *c, const map_geom_t *g, const map_pose_t *pose)
{
    if (!c || !g || !pose) {
        return;
    }

    /* cos(vĩ độ anchor) để co kinh độ về mét (north-up). */
    double anchor_lat_rad = (double)g->anchor_lat_e7 * DEG_E7_TO_RAD;
    double cos_lat = cos(anchor_lat_rad);

    /* Offset live pose so với anchor → mét → dm (×10). */
    double dlat_deg = (double)(pose->lat_e7 - g->anchor_lat_e7) * 1e-7;
    double dlng_deg = (double)(pose->lng_e7 - g->anchor_lng_e7) * 1e-7;
    double north_m = dlat_deg * M_PER_DEG_LAT;
    double east_m  = dlng_deg * cos_lat * M_PER_DEG_LAT;

    c->user_n_dm = (int32_t)lround(north_m * 10.0);
    c->user_e_dm = (int32_t)lround(east_m  * 10.0);

    /* Xoay -heading: heading deci-độ (0.1°, 0..3599) → rad. */
    float heading_rad = (float)pose->heading_ddeg * 0.1f * ((float)M_PI / 180.0f);
    c->sin_h = sinf(heading_rad);
    c->cos_h = cosf(heading_rad);

    /* Zoom khớp tỷ lệ điện thoại theo view_span_dm. */
    c->px_per_dm = px_per_dm_from_span(pose->view_span_dm);
}

scr_pt_t projection_point(const proj_ctx_t *c, int16_t e_dm, int16_t n_dm)
{
    scr_pt_t out;

    /* 1) Dịch về hệ user (north-up). */
    float de = (float)((int32_t)e_dm - c->user_e_dm);
    float dn = (float)((int32_t)n_dm - c->user_n_dm);

    /* 2) Xoay -heading (heading-up): trục y' hướng theo heading. */
    float xr = de * c->cos_h - dn * c->sin_h;
    float yr = de * c->sin_h + dn * c->cos_h;

    /* 3) Sang pixel: x phải, y xuống; user neo tại (USER_X, USER_Y). */
    float px = (float)USER_X + xr * c->px_per_dm;
    float py = (float)USER_Y - yr * c->px_per_dm;

    /* Làm tròn + kẹp về dải int16 (chống tràn khi điểm rất xa). */
    long xi = lroundf(px);
    long yi = lroundf(py);
    if (xi < INT16_MIN) xi = INT16_MIN; else if (xi > INT16_MAX) xi = INT16_MAX;
    if (yi < INT16_MIN) yi = INT16_MIN; else if (yi > INT16_MAX) yi = INT16_MAX;

    out.x = (int16_t)xi;
    out.y = (int16_t)yi;
    return out;
}
