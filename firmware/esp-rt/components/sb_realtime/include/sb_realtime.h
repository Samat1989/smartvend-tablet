// Supabase Realtime client for one public channel (Phoenix protocol v1 over
// WebSocket). Joins `realtime:<topic>`, tracks itself in Presence under
// `presence_key`, sends a Phoenix heartbeat every 25 s and reconnects on its
// own. Only what the board needs: broadcast in, broadcast out, Presence track.
//
// Callbacks run on the WebSocket client's task. Keep them short — copy what
// you need and hand it to your own task; do not call sbrt_send() from them.
#pragma once

#include <stdbool.h>
#include "esp_err.h"

typedef void (*sbrt_broadcast_cb_t)(const char *event, const char *payload_json, void *ctx);
typedef void (*sbrt_joined_cb_t)(void *ctx);

typedef struct {
    const char *host;          // "<ref>.supabase.co"
    const char *apikey;        // publishable key
    const char *topic;         // channel name without the "realtime:" prefix, e.g. "dev:<uuid>"
    const char *presence_key;  // our key in Presence (machid)
    const char *presence_meta; // JSON object tracked in Presence, e.g. {"machid":1,"ver":"1.0.0"}
    sbrt_broadcast_cb_t on_broadcast;
    sbrt_joined_cb_t on_joined;  // after every successful (re)join
    void *ctx;
} sbrt_config_t;

// Starts the client; it connects and keeps reconnecting in the background.
// The strings in cfg are copied.
esp_err_t sbrt_start(const sbrt_config_t *cfg);

// Broadcasts `event` with a JSON object payload into the channel. Fails when
// the channel is not joined.
esp_err_t sbrt_send(const char *event, const char *payload_json);

// Channel joined (and Presence tracked) right now.
bool sbrt_joined(void);
