/*
 * nav_model.h — State overlay dẫn đường (từ TYPE 0x10–0x14). Thread-safe snapshot
 * cho display đọc. Tự đăng ký handler với nus_protocol khi init.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "nav_proto.h"

#ifdef __cplusplus
extern "C" {
#endif

#define NAV_STREET_MAX 64

/* Snapshot overlay cho render. */
typedef struct {
    bool        has_instruction;
    uint8_t     instr_seq;
    maneuver_e  maneuver;
    char        street[NAV_STREET_MAX]; /* UTF-8, null-terminated */
    uint8_t     exit_number;

    uint16_t    dist_to_man_m;   /* khoảng cách tới điểm rẽ */
    uint32_t    dist_remain_m;   /* còn lại tới đích */
    uint16_t    eta_min;
    uint8_t     speed_kmh;

    uint8_t     speed_limit_kmh; /* 0 = unknown */
    bool        is_over;

    bool        has_sign;
    sign_type_e sign;
    uint16_t    sign_dist_m;
    uint8_t     sign_value;

    nav_state_e state;
} nav_overlay_t;

void nav_model_init(void);                 /* đăng ký handler 0x10–0x14 */
void nav_model_get(nav_overlay_t *out);    /* copy snapshot (mutex) */
void nav_model_reset(void);

#ifdef __cplusplus
}
#endif
