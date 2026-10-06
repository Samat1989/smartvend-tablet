// Same mechanism as esp-pulse: the name-only /tags list picks the newest tag
// with our prefix, then that one release gives the asset URL. Two small
// requests instead of the full /releases JSON, which the tablet's releases in
// the shared repo would overflow.

#include "ota.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "config.h"
#include "esp_crt_bundle.h"
#include "esp_http_client.h"
#include "esp_https_ota.h"
#include "esp_log.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "net.h"

static const char *TAG = "ota";

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

static char *http_get(const char *url, int cap, int *status) {
    char *body = malloc(cap);
    if (!body) return NULL;
    acc_t acc = { .buf = body, .len = 0, .cap = cap };
    esp_http_client_config_t c = {
        .url = url,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .event_handler = on_http,
        .user_data = &acc,
        .timeout_ms = 15000,
    };
    esp_http_client_handle_t cli = esp_http_client_init(&c);
    esp_http_client_set_header(cli, "Accept", "application/vnd.github+json");
    esp_http_client_set_header(cli, "User-Agent", "esp-rt-ota");
    esp_err_t err = esp_http_client_perform(cli);
    *status = esp_http_client_get_status_code(cli);
    esp_http_client_cleanup(cli);
    if (err != ESP_OK) { free(body); return NULL; }
    body[acc.len] = 0;
    return body;
}

// "esp-rt-pulse-v1.2.3" -> 10203; "...+10203" -> 10203; other prefixes -> -1.
static long tag_code(const char *tag) {
    size_t pl = strlen(OTA_TAG_PREFIX);
    if (strncmp(tag, OTA_TAG_PREFIX, pl) != 0) return -1;
    const char *v = tag + pl;
    const char *plus = strchr(v, '+');
    if (plus) return atol(plus + 1);
    int a = 0, b = 0, c = 0;
    sscanf(v, "%d.%d.%d", &a, &b, &c);
    return (long)a * 10000 + b * 100 + c;
}

static bool find_update(char *url_out, size_t url_sz) {
    int status = 0;
    char *body = http_get("https://api.github.com/repos/" OTA_OWNER_REPO "/tags?per_page=100", 32768, &status);
    if (!body) return false;
    char best_tag[48] = {0};
    long best = FW_VERSION_CODE;
    cJSON *root = status == 200 ? cJSON_Parse(body) : NULL;
    const cJSON *t;
    cJSON_ArrayForEach(t, root) {
        const cJSON *nm = cJSON_GetObjectItem(t, "name");
        if (!cJSON_IsString(nm)) continue;
        long code = tag_code(nm->valuestring);
        if (code > best) { best = code; strlcpy(best_tag, nm->valuestring, sizeof(best_tag)); }
    }
    cJSON_Delete(root);
    free(body);
    if (!best_tag[0]) return false;
    ESP_LOGI(TAG, "newer release %s (code %ld > %d)", best_tag, best, FW_VERSION_CODE);

    char enc[72];
    int ei = 0;
    for (int i = 0; best_tag[i] && ei < (int)sizeof(enc) - 4; i++) {
        if (best_tag[i] == '+') { enc[ei++] = '%'; enc[ei++] = '2'; enc[ei++] = 'B'; }
        else enc[ei++] = best_tag[i];
    }
    enc[ei] = 0;
    char rurl[200];
    snprintf(rurl, sizeof(rurl), "https://api.github.com/repos/" OTA_OWNER_REPO "/releases/tags/%s", enc);
    char *rbody = http_get(rurl, 12288, &status);
    if (!rbody) return false;
    bool found = false;
    cJSON *rel = status == 200 ? cJSON_Parse(rbody) : NULL;
    const cJSON *as;
    cJSON_ArrayForEach(as, cJSON_GetObjectItem(rel, "assets")) {
        const cJSON *nm = cJSON_GetObjectItem(as, "name");
        const cJSON *u = cJSON_GetObjectItem(as, "browser_download_url");
        if (cJSON_IsString(nm) && cJSON_IsString(u) && strcmp(nm->valuestring, OTA_ASSET_NAME) == 0) {
            strlcpy(url_out, u->valuestring, url_sz);
            found = true;
            break;
        }
    }
    cJSON_Delete(rel);
    free(rbody);
    return found;
}

static void apply(const char *url) {
    ESP_LOGW(TAG, "flashing %s", url);
    esp_http_client_config_t http = {
        .url = url,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .timeout_ms = 30000,
        .keep_alive_enable = true,
        .buffer_size = 2048,       // GitHub redirects to a very long URL
        .buffer_size_tx = 4096,
    };
    esp_https_ota_config_t ota = { .http_config = &http };
    if (esp_https_ota(&ota) == ESP_OK) {
        ESP_LOGW(TAG, "OTA OK — rebooting");
        esp_restart();
    }
    ESP_LOGE(TAG, "OTA failed — keeping current firmware");
}

static void ota_task(void *pv) {
    vTaskDelay(pdMS_TO_TICKS(60000));   // let the channel come up first
    while (true) {
        if (net_has_ip()) {
            char url[256];
            if (find_update(url, sizeof(url))) apply(url);
            else ESP_LOGI(TAG, "v%s is current", FW_VERSION_NAME);
        }
        // A day in hourly steps: 24 h in one pdMS_TO_TICKS overflows 32 bits.
        for (int h = 0; h < 24; h++) vTaskDelay(pdMS_TO_TICKS(3600 * 1000));
    }
}

void ota_start(void) {
    xTaskCreate(ota_task, "ota", 10240, NULL, 3, NULL);
}
