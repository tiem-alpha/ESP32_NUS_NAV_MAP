/*
 * nus_protocol.c — Tầng khung (frame) trên NUS.
 *
 * Deframe byte-stream SOF|TYPE|LEN|PAYLOAD|CRC16 (state machine, chịu fragment),
 * verify CRC16/MCRF4XX, dispatch theo TYPE qua bảng handler. Encode + gửi frame.
 * Auto-ACK cho NAV_INSTRUCTION & NAV_STATE. Tự trả DEVICE_INFO khi nhận HELLO.
 *
 * Một BLE link duy nhất → parser context tĩnh, không malloc.
 */
#include "nus_protocol.h"

#include <string.h>

#include "esp_log.h"
#include "model.h"

#define PROTO_TAG "NUS_PROTO"

/* Số TYPE tối đa đăng ký handler (đủ cho 0x01..0x32 + dự phòng). */
#define PROTO_HANDLER_MAX 24

/* Thời gian chờ tx queue mặc định khi gửi frame (ms). */
#define PROTO_TX_WAIT_MS  100

/* DEVICE_INFO trả lời HELLO (§6.2). */
#define PROTO_FW_VER      FIRMWARE_VERSION
#define PROTO_MAX_TEXT    48
#define PROTO_CAP_BITMAP  (CAP_DIACRITICS | CAP_SPEED_LIMIT | CAP_TRAFFIC_SIGN)

/* ── Bảng đăng ký handler theo TYPE ──────────────────────────────────── */
typedef struct {
    uint8_t              type;
    bool                 used;
    nus_proto_handler_t  handler;
    void                *ctx;
} proto_entry_t;

/* ── Trạng thái deframer (byte-stream state machine) ─────────────────── */
typedef enum {
    ST_WAIT_SOF = 0,
    ST_TYPE,
    ST_LEN_LO,
    ST_LEN_HI,
    ST_PAYLOAD,
    ST_CRC_LO,
    ST_CRC_HI,
} proto_state_e;

typedef struct {
    proto_state_e state;
    uint8_t       type;
    uint16_t      len;
    uint16_t      idx;     /* số byte payload đã nhận */
    uint8_t       crc_lo;
    uint8_t       payload[NAV_PROTO_MAX_PAYLOAD];
} proto_parser_t;

static nus_proto_tx_fn s_tx       = NULL;
static bool            s_auto_ack  = false;
static proto_entry_t   s_handlers[PROTO_HANDLER_MAX];
static proto_parser_t  s_parser;

/* ── CRC-16/MCRF4XX (poly reflected 0x8408, init 0xFFFF, xorout 0) ───── */
uint16_t nav_crc16_mcrf4xx(const uint8_t *data, size_t len)
{
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < len; i++) {
        crc ^= (uint16_t)data[i];
        for (int b = 0; b < 8; b++) {
            if (crc & 0x0001) {
                crc = (uint16_t)((crc >> 1) ^ 0x8408);
            } else {
                crc >>= 1;
            }
        }
    }
    return crc;
}

/* ── Tìm handler đã đăng ký cho 1 TYPE ───────────────────────────────── */
static proto_entry_t *proto_find(uint8_t type)
{
    for (int i = 0; i < PROTO_HANDLER_MAX; i++) {
        if (s_handlers[i].used && s_handlers[i].type == type) {
            return &s_handlers[i];
        }
    }
    return NULL;
}

/* ── Trả DEVICE_INFO khi nhận HELLO (handler nội bộ) ─────────────────── */
static void proto_on_hello(uint8_t type, const uint8_t *payload, uint16_t len, void *ctx)
{
    (void)type;
    (void)payload;
    (void)len;
    (void)ctx;

    uint8_t info[5];
    wr_u16(&info[0], PROTO_FW_VER);     /* fw_ver u16 */
    wr_u16(&info[2], PROTO_CAP_BITMAP); /* cap_bitmap u16 */
    info[4] = PROTO_MAX_TEXT;           /* max_text u8 */
    nus_protocol_send(MSG_DEVICE_INFO, info, sizeof(info));
}

esp_err_t nus_protocol_init(nus_proto_tx_fn tx, bool auto_ack)
{
    if (tx == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    s_tx       = tx;
    s_auto_ack = auto_ack;

    memset(s_handlers, 0, sizeof(s_handlers));
    memset(&s_parser, 0, sizeof(s_parser));
    s_parser.state = ST_WAIT_SOF;

    /* Handler nội bộ: tự trả DEVICE_INFO cho HELLO. */
    nus_protocol_register(MSG_HELLO, proto_on_hello, NULL);

    ESP_LOGI(PROTO_TAG, "init (auto_ack=%d)", auto_ack);
    return ESP_OK;
}

void nus_protocol_register(uint8_t type, nus_proto_handler_t handler, void *ctx)
{
    /* Ghi đè nếu TYPE đã có; nếu chưa, chiếm slot trống. */
    proto_entry_t *e = proto_find(type);
    if (e == NULL) {
        for (int i = 0; i < PROTO_HANDLER_MAX; i++) {
            if (!s_handlers[i].used) {
                e = &s_handlers[i];
                break;
            }
        }
    }
    if (e == NULL) {
        ESP_LOGE(PROTO_TAG, "handler table full, drop type 0x%02X", type);
        return;
    }

    e->type    = type;
    e->used    = true;
    e->handler = handler;
    e->ctx     = ctx;
}

/* ── Xử lý 1 frame đã verify CRC: auto-ACK rồi dispatch ──────────────── */
static void proto_dispatch(uint8_t type, const uint8_t *payload, uint16_t len)
{
    if (s_auto_ack) {
        /* ACK mọi frame; seq = payload[0] chỉ có nghĩa với NAV_INSTRUCTION. */
        uint8_t seq = (type == MSG_NAV_INSTRUCTION && len >= 1) ? payload[0] : 0;
        nus_protocol_send_ack(type, seq);
    }

    proto_entry_t *e = proto_find(type);
    if (e && e->handler) {
        e->handler(type, payload, len, e->ctx);
    }
}

void nus_protocol_feed(const uint8_t *data, uint16_t len)
{
    if (data == NULL) {
        return;
    }

    for (uint16_t i = 0; i < len; i++) {
        uint8_t byte = data[i];

        switch (s_parser.state) {
        case ST_WAIT_SOF:
            if (byte == NAV_PROTO_SOF) {
                s_parser.state = ST_TYPE;
            }
            break;

        case ST_TYPE:
            s_parser.type  = byte;
            s_parser.state = ST_LEN_LO;
            break;

        case ST_LEN_LO:
            s_parser.len = byte;
            s_parser.state = ST_LEN_HI;
            break;

        case ST_LEN_HI:
            s_parser.len |= (uint16_t)byte << 8;
            s_parser.idx = 0;
            if (s_parser.len > NAV_PROTO_MAX_PAYLOAD) {
                /* LEN bất hợp lệ → bỏ, resync (quét 0xA5 kế tiếp). */
                s_parser.state = ST_WAIT_SOF;
            } else {
                s_parser.state = (s_parser.len == 0) ? ST_CRC_LO : ST_PAYLOAD;
            }
            break;

        case ST_PAYLOAD:
            s_parser.payload[s_parser.idx++] = byte;
            if (s_parser.idx >= s_parser.len) {
                s_parser.state = ST_CRC_LO;
            }
            break;

        case ST_CRC_LO:
            s_parser.crc_lo = byte;
            s_parser.state  = ST_CRC_HI;
            break;

        case ST_CRC_HI: {
            uint16_t crc_rx = (uint16_t)(s_parser.crc_lo | ((uint16_t)byte << 8));

            /* CRC tính trên TYPE + LEN + PAYLOAD (init 0xFFFF, poly 0x8408). */
            uint16_t crc = 0xFFFF;
            const uint8_t prefix[3] = {
                s_parser.type,
                (uint8_t)(s_parser.len & 0xFF),
                (uint8_t)(s_parser.len >> 8),
            };
            for (int k = 0; k < 3; k++) {
                crc ^= (uint16_t)prefix[k];
                for (int b = 0; b < 8; b++) {
                    crc = (crc & 1) ? (uint16_t)((crc >> 1) ^ 0x8408) : (uint16_t)(crc >> 1);
                }
            }
            for (uint16_t k = 0; k < s_parser.len; k++) {
                crc ^= (uint16_t)s_parser.payload[k];
                for (int b = 0; b < 8; b++) {
                    crc = (crc & 1) ? (uint16_t)((crc >> 1) ^ 0x8408) : (uint16_t)(crc >> 1);
                }
            }

            if (crc == crc_rx) {
                proto_dispatch(s_parser.type, s_parser.payload, s_parser.len);
            } else {
                ESP_LOGW(PROTO_TAG, "CRC mismatch type 0x%02X (rx 0x%04X calc 0x%04X)",
                         s_parser.type, crc_rx, crc);
            }
            s_parser.state = ST_WAIT_SOF;
            break;
        }

        default:
            s_parser.state = ST_WAIT_SOF;
            break;
        }
    }
}

esp_err_t nus_protocol_send(uint8_t type, const uint8_t *payload, uint16_t len)
{
    if (s_tx == NULL) {
        return ESP_ERR_INVALID_STATE;
    }
    if (len > NAV_PROTO_MAX_PAYLOAD) {
        return ESP_ERR_INVALID_SIZE;
    }
    if (len > 0 && payload == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    /* SOF | TYPE | LEN(u16) | PAYLOAD | CRC(2) */
    static uint8_t buf[4 + NAV_PROTO_MAX_PAYLOAD + 2];
    buf[0] = NAV_PROTO_SOF;
    buf[1] = type;
    buf[2] = (uint8_t)(len & 0xFF);
    buf[3] = (uint8_t)(len >> 8);
    if (len > 0) {
        memcpy(&buf[4], payload, len);
    }

    /* CRC trên TYPE + LEN16 + PAYLOAD = buf[1 .. 4+len). */
    uint16_t crc = nav_crc16_mcrf4xx(&buf[1], (size_t)len + 3);
    buf[4 + len]     = (uint8_t)(crc & 0xFF);
    buf[4 + len + 1] = (uint8_t)((crc >> 8) & 0xFF);

    uint16_t total = (uint16_t)(4 + len + 2);
    return s_tx(buf, total, PROTO_TX_WAIT_MS);
}

void nus_protocol_send_ack(uint8_t acked_type, uint8_t seq)
{
    uint8_t payload[2] = { acked_type, seq };
    nus_protocol_send(MSG_ACK, payload, sizeof(payload));
}
