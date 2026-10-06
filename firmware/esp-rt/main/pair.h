// One-time pairing: exchange machid + code from the owner's panel for the
// board's Realtime channel and command key (RPC device_pair).
#pragma once

typedef enum {
    PAIR_OK,
    PAIR_REFUSED,   // bad / expired / burned code — back to the portal
    PAIR_NET_ERR,   // transport problem — retry later
} pair_result_t;

pair_result_t pair_device(void);   // uses g_cfg.machid / g_cfg.code, stores the result
