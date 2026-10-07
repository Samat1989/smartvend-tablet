// OTA from Supabase Storage (see ota.h for the manifest) with a rollback guard.
//
// The image is streamed through esp_http_client into the next OTA slot while a
// SHA-256 of the file is computed on the way, so what lands in flash is checked
// against the manifest before the slot becomes bootable.
//
// Rollback is ours, not the bootloader's: boards that arrived from esp-pulse /
// esp-relay over the air keep the old bootloader, and one mechanism should work
// on all of them.
//   install      -> NVS ota_pend = code, ota_boots = 0, boot slot switched
//   every boot   -> ota_boots++ ; more than 4 -> roll back (crash loop)
//   in the new image, the watchdog wants 2 minutes in the Realtime channel in a
//   row within 10 minutes of boot; success clears ota_pend, failure rolls back
//   rollback     -> ota_bad_code = code, boot slot = the other one, but only if
//   that slot holds esp-rt (after a takeover it holds esp-pulse / esp-relay and
//   going back would just download esp-rt again).

#include "ota.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "app.h"
#include "cJSON.h"
#include "config.h"
#include "esp_crt_bundle.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "mbedtls/sha256.h"
#include "net.h"
#include "sb_realtime.h"
#include "store.h"

static const char *TAG = "ota";

#define MANIFEST_URL  "https://" SUPABASE_HOST "/storage/v1/object/public/updates/esp-rt-" FW_VARIANT "/manifest.json"
#define MANIFEST_CAP  6144
#define CHECK_EVERY_S (6 * 3600)
#define HEALTHY_S     120      // continuous time in the channel that proves an image
#define PROVE_WITHIN_S 600     // ... and how long it has to do it
#define MAX_BOOTS     4
#define OWN_PROJECT   "esp_rt"

static TaskHandle_t s_task;
static char s_force_id[40];          // pending server-requested check (id to answer), "" if none
static volatile bool s_busy;

typedef struct {
    int  code;
    int  size;
    char url[256];
    char sha256[65];
    char version[24];
    bool pinned;                     // came from pins[]: install even if older / marked bad
} target_t;

// ---------------- rollback guard ----------------
static void rollback(int bad_code, const char *why) {
    const esp_partition_t *run = esp_ota_get_running_partition();
    const esp_partition_t *prev = esp_ota_get_next_update_partition(run);
    esp_app_desc_t d;
    bool prev_ok = prev && esp_ota_get_partition_description(prev, &d) == ESP_OK &&
                   strcmp(d.project_name, OWN_PROJECT) == 0;
    store_erase("ota_pend");
    store_erase("ota_boots");
    if (!prev_ok) {
        ESP_LOGE(TAG, "image %d failed (%s) but the other slot is not esp-rt — staying", bad_code, why);
        return;
    }
    store_set_int("ota_bad", bad_code);
    ESP_LOGE(TAG, "image %d failed (%s) — back to %s %s", bad_code, why, d.project_name, d.version);
    if (esp_ota_set_boot_partition(prev) == ESP_OK) {
        vTaskDelay(pdMS_TO_TICKS(500));
        esp_restart();
    }
    ESP_LOGE(TAG, "could not switch the boot slot");
}

void ota_on_boot(void) {
    int pend = store_get_int("ota_pend", 0);
    if (!pend) return;
    int boots = store_get_int("ota_boots", 0) + 1;
    store_set_int("ota_boots", boots);
    ESP_LOGW(TAG, "booted a new image (code %d), start %d of %d", pend, boots, MAX_BOOTS);
    if (boots > MAX_BOOTS) rollback(pend, "restart loop");
}

static void watch_task(void *pv) {
    int pend = store_get_int("ota_pend", 0);
    int streak = 0;
    for (int t = 0; t < PROVE_WITHIN_S; t++) {
        vTaskDelay(pdMS_TO_TICKS(1000));
        streak = sbrt_joined() ? streak + 1 : 0;
        if (streak >= HEALTHY_S) {
            store_erase("ota_pend");
            store_erase("ota_boots");
            ESP_LOGI(TAG, "new image %d proved itself — kept", pend);
            vTaskDelete(NULL);
        }
    }
    rollback(pend, "no channel within 10 minutes");
    vTaskDelete(NULL);
}

// ---------------- manifest ----------------
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

static char *fetch_manifest(void) {
    char *body = malloc(MANIFEST_CAP);
    if (!body) return NULL;
    acc_t acc = { .buf = body, .len = 0, .cap = MANIFEST_CAP };
    esp_http_client_config_t c = {
        .url = MANIFEST_URL,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .event_handler = on_http,
        .user_data = &acc,
        .timeout_ms = 15000,
    };
    esp_http_client_handle_t cli = esp_http_client_init(&c);
    if (!cli) { free(body); return NULL; }
    esp_err_t err = esp_http_client_perform(cli);
    int status = esp_http_client_get_status_code(cli);
    esp_http_client_cleanup(cli);
    if (err != ESP_OK || status != 200) {
        ESP_LOGW(TAG, "manifest: %s, HTTP %d", esp_err_to_name(err), status);
        free(body);
        return NULL;
    }
    body[acc.len] = 0;
    return body;
}

static bool read_target(const cJSON *o, target_t *t) {
    const cJSON *code = cJSON_GetObjectItem(o, "code");
    const cJSON *url = cJSON_GetObjectItem(o, "url");
    const cJSON *sha = cJSON_GetObjectItem(o, "sha256");
    const cJSON *size = cJSON_GetObjectItem(o, "size");
    const cJSON *ver = cJSON_GetObjectItem(o, "version");
    if (!cJSON_IsNumber(code) || !cJSON_IsString(url) || !cJSON_IsString(sha) ||
        strlen(sha->valuestring) != 64 || !cJSON_IsNumber(size)) return false;
    memset(t, 0, sizeof(*t));
    t->code = code->valueint;
    t->size = size->valueint;
    strlcpy(t->url, url->valuestring, sizeof(t->url));
    strlcpy(t->sha256, sha->valuestring, sizeof(t->sha256));
    if (cJSON_IsString(ver)) strlcpy(t->version, ver->valuestring, sizeof(t->version));
    return true;
}

typedef enum { CHK_CURRENT, CHK_SKIPPED, CHK_UPDATE, CHK_FAILED } chk_t;

// Decide what this board should run. `pins` first (exact build, any direction),
// then the general release, which only counts when it is newer, not marked bad,
// and either has no `devices` list or lists this board.
static chk_t decide(const char *manifest, target_t *t) {
    cJSON *root = cJSON_Parse(manifest);
    if (!root) { ESP_LOGW(TAG, "manifest is not JSON"); return CHK_FAILED; }
    chk_t res = CHK_FAILED;
    const cJSON *pin = cJSON_GetObjectItem(cJSON_GetObjectItem(root, "pins"), store_device_id());
    if (pin) {
        if (!read_target(pin, t)) goto out;
        t->pinned = true;
        res = t->code == FW_VERSION_CODE ? CHK_CURRENT : CHK_UPDATE;
        goto out;
    }
    if (!read_target(root, t)) goto out;
    const cJSON *devs = cJSON_GetObjectItem(root, "devices");
    if (cJSON_IsArray(devs)) {
        bool listed = false;
        const cJSON *d;
        cJSON_ArrayForEach(d, devs)
            if (cJSON_IsString(d) && strcasecmp(d->valuestring, store_device_id()) == 0) listed = true;
        if (!listed) { res = CHK_CURRENT; goto out; }
    }
    if (t->code <= FW_VERSION_CODE) res = CHK_CURRENT;
    else if (t->code == store_get_int("ota_bad", 0)) res = CHK_SKIPPED;
    else res = CHK_UPDATE;
out:
    cJSON_Delete(root);
    return res;
}

// ---------------- install ----------------
static bool install(const target_t *t) {
    const esp_partition_t *slot = esp_ota_get_next_update_partition(NULL);
    if (!slot || t->size <= 0 || (size_t)t->size > slot->size) {
        ESP_LOGE(TAG, "image of %d B does not fit the slot", t->size);
        return false;
    }
    esp_http_client_config_t c = {
        .url = t->url,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .timeout_ms = 30000,
        .buffer_size = 2048,
    };
    esp_http_client_handle_t cli = esp_http_client_init(&c);
    if (!cli) return false;
    bool ok = false;
    esp_ota_handle_t oh = 0;
    bool began = false;
    uint8_t *buf = malloc(2048);
    mbedtls_sha256_context sha;
    mbedtls_sha256_init(&sha);
    if (!buf) goto done;
    if (esp_http_client_open(cli, 0) != ESP_OK) { ESP_LOGE(TAG, "download: connect failed"); goto done; }
    int clen = esp_http_client_fetch_headers(cli);
    int status = esp_http_client_get_status_code(cli);
    if (status != 200 || (clen > 0 && clen != t->size)) {
        ESP_LOGE(TAG, "download: HTTP %d, length %d (expected %d)", status, clen, t->size);
        goto done;
    }
    if (esp_ota_begin(slot, t->size, &oh) != ESP_OK) { ESP_LOGE(TAG, "esp_ota_begin failed"); goto done; }
    began = true;
    mbedtls_sha256_starts(&sha, 0);
    int got = 0, last_pct = -1;
    while (got < t->size) {
        int n = esp_http_client_read(cli, (char *)buf, 2048);
        if (n < 0) { ESP_LOGE(TAG, "download: read error at %d B", got); goto done; }
        if (n == 0) {
            if (!esp_http_client_is_complete_data_received(cli)) { ESP_LOGE(TAG, "download: cut at %d B", got); goto done; }
            break;
        }
        if (got + n > t->size) { ESP_LOGE(TAG, "download: longer than the manifest says"); goto done; }
        mbedtls_sha256_update(&sha, buf, n);
        if (esp_ota_write(oh, buf, n) != ESP_OK) { ESP_LOGE(TAG, "flash write failed"); goto done; }
        got += n;
        int pct = got * 100 / t->size;
        if (pct / 20 != last_pct / 20) { last_pct = pct; ESP_LOGI(TAG, "downloaded %d%%", pct); }
    }
    if (got != t->size) { ESP_LOGE(TAG, "download: %d of %d B", got, t->size); goto done; }
    uint8_t dig[32];
    mbedtls_sha256_finish(&sha, dig);
    char hex[65];
    for (int i = 0; i < 32; i++) sprintf(hex + i * 2, "%02x", dig[i]);
    if (strcasecmp(hex, t->sha256) != 0) { ESP_LOGE(TAG, "SHA-256 mismatch — not installing"); goto done; }
    began = false;
    if (esp_ota_end(oh) != ESP_OK) { ESP_LOGE(TAG, "image failed validation"); goto done; }
    // Pending state first: if power dies after the slot switch, the new image
    // still starts under the guard.
    store_set_int("ota_pend", t->code);
    store_set_int("ota_boots", 0);
    if (esp_ota_set_boot_partition(slot) != ESP_OK) {
        store_erase("ota_pend");
        ESP_LOGE(TAG, "could not switch the boot slot");
        goto done;
    }
    ok = true;
done:
    if (began) esp_ota_abort(oh);
    mbedtls_sha256_free(&sha);
    free(buf);
    esp_http_client_close(cli);
    esp_http_client_cleanup(cli);
    return ok;
}

static void report(const char *id, const char *status, int code) {
    if (!id[0]) return;
    char p[120];
    snprintf(p, sizeof(p), "{\"id\":\"%s\",\"status\":\"%s\",\"code\":%d,\"ver\":\"%s\"}",
             id, status, code, FW_VERSION_NAME);
    sbrt_send("ota", p);
}

static void check_once(const char *id) {
    s_busy = true;
    char *manifest = fetch_manifest();
    if (!manifest) { report(id, "failed", 0); s_busy = false; return; }
    target_t t;
    chk_t r = decide(manifest, &t);
    free(manifest);
    switch (r) {
    case CHK_CURRENT:
        ESP_LOGI(TAG, "v%s is current", FW_VERSION_NAME);
        report(id, "current", FW_VERSION_CODE);
        break;
    case CHK_SKIPPED:
        ESP_LOGW(TAG, "release %d failed on this board before — skipped", t.code);
        report(id, "skipped", t.code);
        break;
    case CHK_FAILED:
        report(id, "failed", 0);
        break;
    case CHK_UPDATE:
        ESP_LOGW(TAG, "%s %s (code %d) -> %d", t.pinned ? "pinned to" : "new release", t.version, t.code, FW_VERSION_CODE);
        report(id, "updating", t.code);
        if (!install(&t)) { report(id, "failed", t.code); break; }
        // Booted slot is switched; restart only when nobody is at the door.
        ESP_LOGW(TAG, "installed — restarting when the lock is idle");
        while (!app_idle()) vTaskDelay(pdMS_TO_TICKS(5000));
        esp_restart();
    }
    s_busy = false;
}

static void ota_task(void *pv) {
    for (int i = 0; i < 60; i++) {                 // let the channel come up first
        if (ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1000))) break;
    }
    while (true) {
        char id[sizeof(s_force_id)];
        strlcpy(id, s_force_id, sizeof(id));
        s_force_id[0] = 0;
        if (net_has_ip()) check_once(id);
        else report(id, "failed", 0);
        // Sleep in 1 s steps so a server request wakes us at once.
        for (int s = 0; s < CHECK_EVERY_S; s++) {
            if (ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1000))) break;
        }
    }
}

void ota_check_now(const char *id) {
    if (s_busy) { report(id, "updating", 0); return; }
    strlcpy(s_force_id, id, sizeof(s_force_id));
    if (s_task) xTaskNotifyGive(s_task);
}

void ota_start(void) {
    if (store_get_int("ota_pend", 0)) xTaskCreate(watch_task, "ota_watch", 3072, NULL, 3, NULL);
    xTaskCreate(ota_task, "ota", 10240, NULL, 3, &s_task);
}
