// Board side of the Realtime channel `dev:<rt_topic>`.
//
// The server (create-payment / service-open-request) talks to the board in
// broadcasts:
//   ping {nonce}                        -> pong {nonce, lock_ok, rssi, heap, ver}
//   open {id, seconds, exp, sig}        -> opened {id, ok, seconds}   (paid order)
//   service-open {id, seconds, exp, sig}-> opened {id, ok, seconds}   (refill)
//
// `seconds` is the machine's open time from the panel (1..600), the same for a
// paid order and a service open, and it is part of the signature. The board
// keeps no such setting of its own. A command without it (older server) opens
// for DEFAULT_OPEN_SECONDS. The lock itself only latches shut once the reed
// switch sees the door's magnet, so this is the window to pull the door open,
// not how long it stays open.
//
// The channel is public, so a command opens the lock only if
//   sig == HMAC-SHA256(rt_key, "<event>|<id>|<seconds or empty>|<exp>") (hex),
//   exp is not in the past (and not absurdly far in the future), and
//   id is not among the recently opened ids.
// A repeat of an id we already opened is acknowledged again without opening:
// that is the server retrying because our first `opened` got lost.
//
// Presence (tracked under our board ID, the MAC) is what the server checks
// before it polls the bank; when our socket dies, Realtime drops us from it.
// What we track there — {device, ver, variant, net, rssi_dbm, csq, heap} — goes
// out on every join and again when the signal moves or every 5 minutes, so the
// panel sees the board's state without asking. pong carries the same fields.

#include "app.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "board.h"
#include "cJSON.h"
#include "config.h"
#include "esp_log.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "mbedtls/md.h"
#include "net.h"
#include "sb_realtime.h"
#include "store.h"

static const char *TAG = "app";

#define MAX_EXP_AHEAD_S 120

typedef struct {
    char event[16];
    char payload[400];
} msg_t;

static QueueHandle_t s_msgq;
static QueueHandle_t s_lockq;   // int: seconds to keep the lock open

// ---------------- lock timing ----------------
// Owns the lock line: opens on the first request, keeps it open until the
// latest requested deadline, then closes. A second open while the door is
// already open just extends the window.
static void lock_task(void *pv) {
    bool is_open = false;
    TickType_t until = 0;
    while (true) {
        TickType_t now = xTaskGetTickCount();
        TickType_t wait = is_open ? (until > now ? until - now : 0) : portMAX_DELAY;
        int sec;
        if (xQueueReceive(s_lockq, &sec, wait) == pdTRUE) {
            TickType_t u = xTaskGetTickCount() + pdMS_TO_TICKS(sec * 1000);
            if (!is_open) {
                lock_open();
                is_open = true;
                ESP_LOGI(TAG, "LOCK OPEN for %d s", sec);
            }
            if (u > until) until = u;
        } else if (is_open) {
            lock_close();
            is_open = false;
            ESP_LOGI(TAG, "LOCK CLOSED");
        }
    }
}

// ---------------- signature ----------------
static bool sig_ok(const char *msg, const char *sig_hex) {
    unsigned char mac[32];
    const mbedtls_md_info_t *md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    if (mbedtls_md_hmac(md, (const unsigned char *)g_cfg.rt_key, strlen(g_cfg.rt_key),
                        (const unsigned char *)msg, strlen(msg), mac) != 0) return false;
    if (strlen(sig_hex) != 64) return false;
    char hex[65];
    for (int i = 0; i < 32; i++) sprintf(hex + i * 2, "%02x", mac[i]);
    unsigned char diff = 0;                       // constant-time compare
    for (int i = 0; i < 64; i++) diff |= (unsigned char)(hex[i] ^ sig_hex[i]);
    return diff == 0;
}

static void send_opened(const char *id, bool ok, int seconds, const char *err) {
    char p[180];
    if (err) snprintf(p, sizeof(p), "{\"id\":\"%s\",\"ok\":%s,\"err\":\"%s\"}", id, ok ? "true" : "false", err);
    else     snprintf(p, sizeof(p), "{\"id\":\"%s\",\"ok\":%s,\"seconds\":%d}", id, ok ? "true" : "false", seconds);
    if (sbrt_send("opened", p) != ESP_OK) ESP_LOGW(TAG, "opened ack for %s not sent", id);
}

static void handle_command(const char *event, cJSON *p) {
    const cJSON *id = cJSON_GetObjectItem(p, "id");
    const cJSON *exp = cJSON_GetObjectItem(p, "exp");
    const cJSON *sig = cJSON_GetObjectItem(p, "sig");
    const cJSON *secj = cJSON_GetObjectItem(p, "seconds");
    if (!cJSON_IsString(id) || !cJSON_IsNumber(exp) || !cJSON_IsString(sig) ||
        strlen(id->valuestring) >= 64) {
        ESP_LOGW(TAG, "%s: malformed", event);
        return;
    }
    long long exp_s = (long long)exp->valuedouble;
    // The signed string carries seconds exactly as sent ("" when absent), so a
    // tampered value breaks the signature; only then is it clamped for use.
    char seconds_str[12] = "";
    int seconds = DEFAULT_OPEN_SECONDS;
    if (cJSON_IsNumber(secj)) {
        int req = secj->valueint;
        snprintf(seconds_str, sizeof(seconds_str), "%d", req);
        if (req >= 1) seconds = req > 600 ? 600 : req;
    }

    char msg[160];
    snprintf(msg, sizeof(msg), "%s|%s|%s|%lld", event, id->valuestring, seconds_str, exp_s);
    if (!sig_ok(msg, sig->valuestring)) {
        ESP_LOGW(TAG, "%s %s: BAD SIGNATURE — ignored", event, id->valuestring);
        return;
    }
    if (!net_time_synced()) {
        // Without a clock we cannot tell a fresh command from a replayed one.
        // Say so instead of staying silent: the server records "failed".
        ESP_LOGE(TAG, "%s %s: clock not set — refusing", event, id->valuestring);
        send_opened(id->valuestring, false, 0, "no_time");
        return;
    }
    long long now = (long long)time(NULL);
    if (exp_s < now || exp_s > now + MAX_EXP_AHEAD_S) {
        ESP_LOGW(TAG, "%s %s: expired/out of window (exp %lld, now %lld)", event, id->valuestring, exp_s, now);
        return;
    }
    if (seen_has(id->valuestring)) {
        ESP_LOGI(TAG, "%s %s: already opened — re-ack", event, id->valuestring);
        send_opened(id->valuestring, true, seconds, NULL);
        return;
    }

    seen_add(id->valuestring);
    xQueueSend(s_lockq, &seconds, portMAX_DELAY);
    ESP_LOGI(TAG, "%s %s: OPEN %d s", event, id->valuestring, seconds);
    send_opened(id->valuestring, true, seconds, NULL);
}

// Board state as JSON object fields (no braces), shared by Presence and pong.
static int state_fields(char *out, size_t sz) {
    int dbm, csq;
    net_signal(&dbm, &csq);
    return snprintf(out, sz,
                    "\"device\":\"%s\",\"ver\":\"%s\",\"variant\":\"%s\",\"net\":\"%s\","
                    "\"rssi_dbm\":%d,\"csq\":%d,\"heap\":%lu",
                    store_device_id(), FW_VERSION_NAME, FW_VARIANT, g_cfg.netmode,
                    dbm, csq, (unsigned long)esp_get_free_heap_size());
}

static void handle_ping(cJSON *p) {
    const cJSON *nonce = cJSON_GetObjectItem(p, "nonce");
    if (!cJSON_IsString(nonce) || strlen(nonce->valuestring) > 40) return;
    char st[220], out[300];
    state_fields(st, sizeof(st));
    snprintf(out, sizeof(out), "{\"nonce\":\"%s\",\"lock_ok\":true,%s}", nonce->valuestring, st);
    sbrt_send("pong", out);
}

// Re-publish state in Presence when the signal moved by more than 6 dB, and
// every 5 minutes regardless (heap, a CSQ that settled after the first read).
static void state_task(void *pv) {
    int last_dbm = 0;
    TickType_t last_at = 0;
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(30000));
        int dbm, csq;
        net_signal(&dbm, &csq);
        bool moved = abs(dbm - last_dbm) > 6;
        bool stale = xTaskGetTickCount() - last_at > pdMS_TO_TICKS(5 * 60 * 1000);
        if (!moved && !stale) continue;
        char st[220], meta[240];
        state_fields(st, sizeof(st));
        snprintf(meta, sizeof(meta), "{%s}", st);
        if (sbrt_track(meta) == ESP_OK) {
            last_dbm = dbm;
            last_at = xTaskGetTickCount();
        }
    }
}

static void worker_task(void *pv) {
    msg_t m;
    while (true) {
        if (xQueueReceive(s_msgq, &m, pdMS_TO_TICKS(1000)) == pdTRUE) {
            cJSON *p = cJSON_Parse(m.payload);
            if (p) {
                if (strcmp(m.event, "ping") == 0) handle_ping(p);
                else if (strcmp(m.event, "open") == 0 || strcmp(m.event, "service-open") == 0)
                    handle_command(m.event, p);
                cJSON_Delete(p);
            }
        }
        led_set_stage(sbrt_joined() ? LED_ONLINE : net_has_ip() ? LED_HAS_IP : LED_NO_LINK);
    }
}

static void on_broadcast(const char *event, const char *payload_json, void *ctx) {
    msg_t m;
    if (strlen(event) >= sizeof(m.event) || strlen(payload_json) >= sizeof(m.payload)) return;
    strcpy(m.event, event);
    strcpy(m.payload, payload_json);
    if (xQueueSend(s_msgq, &m, 0) != pdTRUE) ESP_LOGW(TAG, "queue full, %s dropped", event);
}

static void on_joined(void *ctx) {
    ESP_LOGI(TAG, "online in channel (free heap %lu, min %lu)",
             (unsigned long)esp_get_free_heap_size(), (unsigned long)esp_get_minimum_free_heap_size());
}

void app_start(void) {
    s_msgq = xQueueCreate(6, sizeof(msg_t));
    s_lockq = xQueueCreate(4, sizeof(int));
    xTaskCreate(lock_task, "lock", 3072, NULL, 6, NULL);
    xTaskCreate(worker_task, "app", 6144, NULL, 5, NULL);

    // Commands are refused until the clock is set; give SNTP a head start.
    net_sntp_start();
    for (int i = 0; i < 30 && !net_time_synced(); i++) vTaskDelay(pdMS_TO_TICKS(1000));
    if (!net_time_synced()) ESP_LOGW(TAG, "clock not set yet — commands refused until it is");

    char topic[48], st[220], meta[240];
    snprintf(topic, sizeof(topic), "dev:%s", g_cfg.rt_topic);
    state_fields(st, sizeof(st));
    snprintf(meta, sizeof(meta), "{%s}", st);
    sbrt_config_t c = {
        .host = SUPABASE_HOST,
        .apikey = SUPABASE_KEY,
        .topic = topic,
        .presence_key = store_device_id(),
        .presence_meta = meta,
        .on_broadcast = on_broadcast,
        .on_joined = on_joined,
    };
    ESP_ERROR_CHECK(sbrt_start(&c));
    xTaskCreate(state_task, "state", 4096, NULL, 4, NULL);
}
