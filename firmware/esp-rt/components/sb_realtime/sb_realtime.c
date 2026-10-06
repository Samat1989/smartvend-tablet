// Supabase Realtime (Phoenix v1 JSON protocol) for one channel.
//
// Frames, all JSON text:
//   join      {"topic":"realtime:T","event":"phx_join","ref":R,"join_ref":R,
//              "payload":{"config":{"broadcast":{"self":false},"presence":{"key":K},
//              "private":false},"access_token":APIKEY}}
//   track     {"topic":"realtime:T","event":"presence","ref":R,"join_ref":J,
//              "payload":{"type":"presence","event":"track","payload":META}}
//   broadcast {"topic":"realtime:T","event":"broadcast","ref":R,"join_ref":J,
//              "payload":{"type":"broadcast","event":E,"payload":P}}
//   heartbeat {"topic":"phoenix","event":"heartbeat","payload":{},"ref":R}
//
// Realtime closes a socket that sends no heartbeat for ~60 s; we send one every
// 25 s. The other direction matters as much: a GSM link can die without a TCP
// reset, and the socket then looks open forever. If no heartbeat reply comes
// back for HB_DEAD_MS we tear the client down and start it again.

#include "sb_realtime.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "esp_crt_bundle.h"
#include "esp_log.h"
#include "esp_websocket_client.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

static const char *TAG = "sbrt";

#define HB_EVERY_MS   25000
#define HB_DEAD_MS    70000
#define RX_BUF_SZ     4096
#define TX_BUF_SZ     1024

static esp_websocket_client_handle_t s_client;
static SemaphoreHandle_t s_tx_lock;
static sbrt_config_t s_cfg;
static char s_topic[96];        // "realtime:<topic>"
static char s_join_ref[12];
static unsigned s_ref;
static volatile bool s_joined;
static volatile TickType_t s_last_reply;

static char s_rx[RX_BUF_SZ];
static int  s_rx_len;
static bool s_rx_overflow;

static char *dupstr(const char *s) { return s ? strdup(s) : strdup(""); }

// Sends one frame. `join_ref` may be NULL (heartbeat).
static esp_err_t send_frame(const char *topic, const char *event, const char *payload_json,
                            const char *join_ref, char *ref_out, size_t ref_out_sz) {
    if (!s_client || !esp_websocket_client_is_connected(s_client)) return ESP_ERR_INVALID_STATE;
    static char buf[TX_BUF_SZ];
    xSemaphoreTake(s_tx_lock, portMAX_DELAY);
    char ref[12];
    snprintf(ref, sizeof(ref), "%u", ++s_ref);
    // Before sending: the reply can arrive before send_text returns.
    if (ref_out) strlcpy(ref_out, ref, ref_out_sz);
    int n;
    if (join_ref) {
        n = snprintf(buf, sizeof(buf),
                     "{\"topic\":\"%s\",\"event\":\"%s\",\"ref\":\"%s\",\"join_ref\":\"%s\",\"payload\":%s}",
                     topic, event, ref, join_ref, payload_json);
    } else {
        n = snprintf(buf, sizeof(buf),
                     "{\"topic\":\"%s\",\"event\":\"%s\",\"ref\":\"%s\",\"payload\":%s}",
                     topic, event, ref, payload_json);
    }
    esp_err_t err = ESP_FAIL;
    if (n > 0 && n < (int)sizeof(buf)) {
        int w = esp_websocket_client_send_text(s_client, buf, n, pdMS_TO_TICKS(5000));
        err = (w == n) ? ESP_OK : ESP_FAIL;
    } else {
        ESP_LOGE(TAG, "frame too large (%d B)", n);
    }
    xSemaphoreGive(s_tx_lock);
    return err;
}

static void send_join(void) {
    char payload[512];
    snprintf(payload, sizeof(payload),
             "{\"config\":{\"broadcast\":{\"self\":false,\"ack\":false},"
             "\"presence\":{\"key\":\"%s\"},\"private\":false},\"access_token\":\"%s\"}",
             s_cfg.presence_key, s_cfg.apikey);
    s_joined = false;
    // Phoenix v1: the join's ref doubles as the join_ref of every later frame.
    if (send_frame(s_topic, "phx_join", payload, NULL, s_join_ref, sizeof(s_join_ref)) != ESP_OK) {
        ESP_LOGW(TAG, "join send failed");
    }
}

static void send_track(void) {
    char payload[384];
    snprintf(payload, sizeof(payload),
             "{\"type\":\"presence\",\"event\":\"track\",\"payload\":%s}",
             s_cfg.presence_meta[0] ? s_cfg.presence_meta : "{}");
    send_frame(s_topic, "presence", payload, s_join_ref, NULL, 0);
}

static void handle_message(const char *json) {
    cJSON *root = cJSON_Parse(json);
    if (!root) { ESP_LOGW(TAG, "bad json"); return; }
    const cJSON *topic = cJSON_GetObjectItem(root, "topic");
    const cJSON *event = cJSON_GetObjectItem(root, "event");
    const cJSON *ref   = cJSON_GetObjectItem(root, "ref");
    const cJSON *pl    = cJSON_GetObjectItem(root, "payload");
    if (!cJSON_IsString(event)) goto done;

    if (strcmp(event->valuestring, "phx_reply") == 0) {
        s_last_reply = xTaskGetTickCount();
        const cJSON *status = cJSON_GetObjectItem(pl, "status");
        bool is_join = cJSON_IsString(ref) && strcmp(ref->valuestring, s_join_ref) == 0 &&
                       cJSON_IsString(topic) && strcmp(topic->valuestring, s_topic) == 0;
        if (is_join) {
            if (cJSON_IsString(status) && strcmp(status->valuestring, "ok") == 0) {
                ESP_LOGI(TAG, "joined %s", s_topic);
                send_track();
                s_joined = true;
                if (s_cfg.on_joined) s_cfg.on_joined(s_cfg.ctx);
            } else {
                char *dump = cJSON_PrintUnformatted(pl);
                ESP_LOGE(TAG, "join refused: %s", dump ? dump : "?");
                free(dump);
            }
        }
    } else if (strcmp(event->valuestring, "broadcast") == 0) {
        const cJSON *ev = cJSON_GetObjectItem(pl, "event");
        const cJSON *inner = cJSON_GetObjectItem(pl, "payload");
        if (cJSON_IsString(ev) && s_cfg.on_broadcast) {
            char *pj = inner ? cJSON_PrintUnformatted(inner) : NULL;
            s_cfg.on_broadcast(ev->valuestring, pj ? pj : "{}", s_cfg.ctx);
            free(pj);
        }
    } else if (strcmp(event->valuestring, "phx_error") == 0 ||
               strcmp(event->valuestring, "phx_close") == 0) {
        // Server dropped our channel (not the socket): join again.
        ESP_LOGW(TAG, "channel %s: %s — rejoining", s_topic, event->valuestring);
        s_joined = false;
        send_join();
    } else if (strcmp(event->valuestring, "system") == 0) {
        // Informational ({"status":"ok","extension":"..."}); nothing to do.
    }
done:
    cJSON_Delete(root);
}

static void ws_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    esp_websocket_event_data_t *d = (esp_websocket_event_data_t *)data;
    switch (id) {
    case WEBSOCKET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "socket connected");
        s_last_reply = xTaskGetTickCount();
        s_rx_len = 0;
        send_join();
        break;
    case WEBSOCKET_EVENT_DISCONNECTED:
    case WEBSOCKET_EVENT_CLOSED:
        if (s_joined) ESP_LOGW(TAG, "socket lost");
        s_joined = false;
        break;
    case WEBSOCKET_EVENT_DATA:
        if (d->op_code != 0x1 && d->op_code != 0x0) break;   // text + continuation only
        if (d->payload_offset == 0) { s_rx_len = 0; s_rx_overflow = false; }
        if (s_rx_len + d->data_len >= RX_BUF_SZ) {
            s_rx_overflow = true;
        } else {
            memcpy(s_rx + s_rx_len, d->data_ptr, d->data_len);
            s_rx_len += d->data_len;
        }
        if (d->payload_offset + d->data_len >= d->payload_len) {
            if (s_rx_overflow) {
                ESP_LOGW(TAG, "message over %d B dropped", RX_BUF_SZ);
            } else {
                s_rx[s_rx_len] = 0;
                handle_message(s_rx);
            }
            s_rx_len = 0;
        }
        break;
    case WEBSOCKET_EVENT_ERROR:
        ESP_LOGW(TAG, "socket error");
        break;
    default:
        break;
    }
}

static void heartbeat_task(void *pv) {
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(HB_EVERY_MS));
        if (!esp_websocket_client_is_connected(s_client)) continue;
        send_frame("phoenix", "heartbeat", "{}", NULL, NULL, 0);
        if (xTaskGetTickCount() - s_last_reply > pdMS_TO_TICKS(HB_DEAD_MS)) {
            ESP_LOGW(TAG, "no reply for %d s — restarting socket", HB_DEAD_MS / 1000);
            s_joined = false;
            esp_websocket_client_stop(s_client);
            vTaskDelay(pdMS_TO_TICKS(1000));
            s_last_reply = xTaskGetTickCount();
            esp_websocket_client_start(s_client);
        }
    }
}

esp_err_t sbrt_start(const sbrt_config_t *cfg) {
    if (s_client) return ESP_ERR_INVALID_STATE;
    s_cfg = *cfg;
    s_cfg.host = dupstr(cfg->host);
    s_cfg.apikey = dupstr(cfg->apikey);
    s_cfg.topic = dupstr(cfg->topic);
    s_cfg.presence_key = dupstr(cfg->presence_key);
    s_cfg.presence_meta = dupstr(cfg->presence_meta);
    snprintf(s_topic, sizeof(s_topic), "realtime:%s", s_cfg.topic);
    s_tx_lock = xSemaphoreCreateMutex();

    char *uri = NULL;
    if (asprintf(&uri, "wss://%s/realtime/v1/websocket?apikey=%s&vsn=1.0.0",
                 s_cfg.host, s_cfg.apikey) < 0) return ESP_ERR_NO_MEM;

    esp_websocket_client_config_t wc = {
        .uri = uri,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .reconnect_timeout_ms = 5000,
        .network_timeout_ms = 15000,
        .task_stack = 6144,
        .buffer_size = 2048,
        // Phoenix heartbeat already keeps the socket warm; WS pings on top of
        // it would only spend metered GSM traffic.
        .ping_interval_sec = 120,
    };
    s_client = esp_websocket_client_init(&wc);
    free(uri);   // the client keeps its own copy
    if (!s_client) return ESP_FAIL;
    esp_websocket_register_events(s_client, WEBSOCKET_EVENT_ANY, ws_event, NULL);
    esp_err_t err = esp_websocket_client_start(s_client);
    if (err != ESP_OK) return err;
    xTaskCreate(heartbeat_task, "sbrt_hb", 3072, NULL, 5, NULL);
    return ESP_OK;
}

esp_err_t sbrt_send(const char *event, const char *payload_json) {
    if (!s_joined) return ESP_ERR_INVALID_STATE;
    char payload[640];
    int n = snprintf(payload, sizeof(payload),
                     "{\"type\":\"broadcast\",\"event\":\"%s\",\"payload\":%s}", event, payload_json);
    if (n <= 0 || n >= (int)sizeof(payload)) return ESP_ERR_INVALID_SIZE;
    return send_frame(s_topic, "broadcast", payload, s_join_ref, NULL, 0);
}

bool sbrt_joined(void) { return s_joined; }
