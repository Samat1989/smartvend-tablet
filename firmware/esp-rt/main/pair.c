#include "pair.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "config.h"
#include "esp_crt_bundle.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "store.h"

static const char *TAG = "pair";

typedef struct { char *buf; int len; int cap; } acc_t;

static esp_err_t on_http(esp_http_client_event_t *e) {
    if (e->event_id == HTTP_EVENT_ON_DATA && e->user_data) {
        acc_t *a = e->user_data;
        if (a->len + e->data_len < a->cap) {
            memcpy(a->buf + a->len, e->data, e->data_len);
            a->len += e->data_len;
        }
    }
    return ESP_OK;
}

// POST /rest/v1/rpc/<name> with the publishable key. resp is NUL-terminated.
esp_err_t rpc_post(const char *name, const char *body, char *resp, int cap, int *status) {
    char url[96];
    snprintf(url, sizeof(url), "https://" SUPABASE_HOST "/rest/v1/rpc/%s", name);
    acc_t acc = { .buf = resp, .len = 0, .cap = cap };
    esp_http_client_config_t c = {
        .url = url,
        .method = HTTP_METHOD_POST,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .event_handler = on_http,
        .user_data = &acc,
        .timeout_ms = 20000,
    };
    esp_http_client_handle_t cli = esp_http_client_init(&c);
    if (!cli) return ESP_FAIL;
    esp_http_client_set_header(cli, "apikey", SUPABASE_KEY);
    esp_http_client_set_header(cli, "Authorization", "Bearer " SUPABASE_KEY);
    esp_http_client_set_header(cli, "Content-Type", "application/json");
    esp_http_client_set_post_field(cli, body, strlen(body));
    esp_err_t err = esp_http_client_perform(cli);
    *status = esp_http_client_get_status_code(cli);
    esp_http_client_cleanup(cli);
    resp[acc.len] = 0;
    return err;
}

// Parse {ok, topic, key} and store the channel. Shared by pair and migrate.
pair_result_t pair_store_reply(const char *resp, const char *what) {
    pair_result_t res = PAIR_REFUSED;
    cJSON *root = cJSON_Parse(resp);
    const cJSON *ok = cJSON_GetObjectItem(root, "ok");
    const cJSON *topic = cJSON_GetObjectItem(root, "topic");
    const cJSON *key = cJSON_GetObjectItem(root, "key");
    if (cJSON_IsTrue(ok) && cJSON_IsString(topic) && cJSON_IsString(key)) {
        strlcpy(g_cfg.rt_topic, topic->valuestring, sizeof(g_cfg.rt_topic));
        strlcpy(g_cfg.rt_key, key->valuestring, sizeof(g_cfg.rt_key));
        store_set_str("rt_topic", g_cfg.rt_topic);
        store_set_str("rt_key", g_cfg.rt_key);
        ESP_LOGI(TAG, "%s ok: board %s, topic %s", what, store_device_id(), g_cfg.rt_topic);
        res = PAIR_OK;
    } else {
        const cJSON *e = cJSON_GetObjectItem(root, "error");
        const char *err = cJSON_IsString(e) ? e->valuestring : resp;
        ESP_LOGW(TAG, "%s refused: %s", what, err);
        // A shared limit is a wait, not a verdict on the code or secret.
        if (strcmp(err, "rate_limited") == 0) res = PAIR_NET_ERR;
    }
    cJSON_Delete(root);
    return res;
}

// device_pair {p_code, p_device_id} -> {ok:true, topic, key} | {ok:false, error}
// The code was issued in the panel for one machine, so the server finds the
// machine by it; the board sends only the code and its own ID.
pair_result_t pair_device(void) {
    char body[96];
    snprintf(body, sizeof(body), "{\"p_code\":\"%s\",\"p_device_id\":\"%s\"}",
             g_cfg.code, store_device_id());

    char resp[512];
    int status = 0;
    esp_err_t err = rpc_post("device_pair", body, resp, sizeof(resp), &status);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "device_pair transport error: %s", esp_err_to_name(err));
        return PAIR_NET_ERR;
    }
    if (status != 200) {
        // 4xx: the request itself is wrong, retrying will not fix it.
        // 5xx: the server's problem — retry.
        ESP_LOGW(TAG, "device_pair HTTP %d: %s", status, resp);
        return status >= 500 ? PAIR_NET_ERR : PAIR_REFUSED;
    }
    return pair_store_reply(resp, "pairing");
}
