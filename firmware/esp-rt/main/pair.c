#include "pair.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "config.h"
#include "esp_crt_bundle.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "esp_mac.h"
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

// POST /rest/v1/rpc/device_pair {p_machid, p_code, p_device_id}
//   -> {ok:true, topic, key} | {ok:false, error}
pair_result_t pair_device(void) {
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    char body[160];
    snprintf(body, sizeof(body),
             "{\"p_machid\":%s,\"p_code\":\"%s\",\"p_device_id\":\"%02X%02X%02X%02X%02X%02X\"}",
             g_cfg.machid, g_cfg.code, mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);

    char resp[512];
    acc_t acc = { .buf = resp, .len = 0, .cap = sizeof(resp) };
    esp_http_client_config_t c = {
        .url = "https://" SUPABASE_HOST "/rest/v1/rpc/device_pair",
        .method = HTTP_METHOD_POST,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .event_handler = on_http,
        .user_data = &acc,
        .timeout_ms = 20000,
    };
    esp_http_client_handle_t cli = esp_http_client_init(&c);
    esp_http_client_set_header(cli, "apikey", SUPABASE_KEY);
    esp_http_client_set_header(cli, "Authorization", "Bearer " SUPABASE_KEY);
    esp_http_client_set_header(cli, "Content-Type", "application/json");
    esp_http_client_set_post_field(cli, body, strlen(body));
    esp_err_t err = esp_http_client_perform(cli);
    int status = esp_http_client_get_status_code(cli);
    esp_http_client_cleanup(cli);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "device_pair transport error: %s", esp_err_to_name(err));
        return PAIR_NET_ERR;
    }
    resp[acc.len] = 0;
    if (status != 200) {
        // 4xx here means the request itself is wrong (e.g. machid not a number)
        // — retrying will not fix it. 5xx is the server's problem: retry.
        ESP_LOGW(TAG, "device_pair HTTP %d: %s", status, resp);
        return status >= 500 ? PAIR_NET_ERR : PAIR_REFUSED;
    }

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
        ESP_LOGI(TAG, "paired machid=%s topic=%s", g_cfg.machid, g_cfg.rt_topic);
        res = PAIR_OK;
    } else {
        const cJSON *e = cJSON_GetObjectItem(root, "error");
        ESP_LOGW(TAG, "pairing refused: %s", cJSON_IsString(e) ? e->valuestring : resp);
    }
    cJSON_Delete(root);
    return res;
}
