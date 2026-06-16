/*
 * projection.h — Chiếu hình học mét north-up (offset dm so với anchor) → pixel
 * màn hình, heading-up, user neo giữa-dưới. Dùng cho display.
 */
#pragma once

#include <stdint.h>

#include "map_model.h"
#include "nav_proto.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SCR_W   240
#define SCR_H   320
#define USER_X  120  /* user neo giữa ngang */
#define USER_Y  230  /* ... và lệch xuống dưới để nhìn xa phía trước */

typedef struct { int16_t x, y; } scr_pt_t;

typedef struct {
    int32_t user_e_dm;   /* offset user so với anchor (dm, north-up) */
    int32_t user_n_dm;
    float   sin_h, cos_h; /* xoay -heading */
    float   px_per_dm;    /* zoom, khớp pose->view_span_dm (tỷ lệ điện thoại) */
} proj_ctx_t;

/* Tính ctx từ geom (anchor) + pose (live). zoom khớp pose->view_span_dm. */
void projection_begin(proj_ctx_t *c, const map_geom_t *g, const map_pose_t *pose);

/* Chiếu 1 điểm north-up dm (so với anchor) ra pixel. */
scr_pt_t projection_point(const proj_ctx_t *c, int16_t e_dm, int16_t n_dm);

#ifdef __cplusplus
}
#endif
