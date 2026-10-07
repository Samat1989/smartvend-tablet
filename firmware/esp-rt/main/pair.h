// One-time pairing: exchange the code from the owner's panel (plus the board
// ID) for the board's Realtime channel and command key (RPC device_pair).
#pragma once

#include "esp_err.h"

typedef enum {
    PAIR_OK,
    PAIR_REFUSED,   // bad / expired / burned code — back to the portal
    PAIR_NET_ERR,   // transport problem or shared rate limit — retry later
} pair_result_t;

pair_result_t pair_device(void);   // uses g_cfg.code + store_device_id(), stores the result

// Shared by pair.c, migrate.c and beat.c.
esp_err_t rpc_post(const char *name, const char *body, char *resp, int cap, int *status);
pair_result_t pair_store_reply(const char *resp, const char *what);
