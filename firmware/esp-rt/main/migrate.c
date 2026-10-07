#include "migrate.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "config.h"
#include "esp_log.h"
#include "nvs.h"
#include "pair.h"
#include "store.h"

static const char *TAG = "migrate";
#define OLD_NS "cfg"

static bool old_get(const char *key, char *out, size_t sz) {
    nvs_handle_t h;
    if (nvs_open(OLD_NS, NVS_READONLY, &h) != ESP_OK) return false;
    size_t n = sz;
    esp_err_t e = nvs_get_str(h, key, out, &n);
    nvs_close(h);
    if (e != ESP_OK) out[0] = 0;
    return e == ESP_OK;
}

bool migrate_pending(void) {
    char machid[16], secret[48];
    return old_get("machid", machid, sizeof(machid)) && old_get("secret", secret, sizeof(secret))
        && atol(machid) > 0 && secret[0];
}

long migrate_machid(void) {
    char machid[16];
    return old_get("machid", machid, sizeof(machid)) ? atol(machid) : 0;
}

void migrate_import_network(void) {
    if (store_has_network()) return;   // already set up in "rt": keep it
    char mode[8] = "gsm", ssid[64], pass[64];
    old_get("netmode", mode, sizeof(mode));
    if (!mode[0]) strcpy(mode, "gsm");
    old_get("ssid", ssid, sizeof(ssid));
    old_get("pass", pass, sizeof(pass));
    store_set_str("netmode", mode);
    store_set_str("ssid", ssid);
    store_set_str("pass", pass);
    store_load();
    ESP_LOGI(TAG, "network imported from the old config: %s%s%s", mode, ssid[0] ? " / " : "", ssid);
}

// SmartVend credentials are not needed on the board once it is paired.
void migrate_wipe(void) {
    nvs_handle_t h;
    if (nvs_open(OLD_NS, NVS_READWRITE, &h) != ESP_OK) return;
    nvs_erase_all(h);
    nvs_commit(h);
    nvs_close(h);
}

pair_result_t migrate_device(void) {
    char machid[16], secret[48], opensec[8];
    if (!old_get("machid", machid, sizeof(machid)) || !old_get("secret", secret, sizeof(secret)))
        return PAIR_REFUSED;
    int os = old_get("opensec", opensec, sizeof(opensec)) ? atoi(opensec) : 0;

    char body[200];
    int n = snprintf(body, sizeof(body),
                     "{\"p_machid\":%ld,\"p_secret\":\"%s\",\"p_device_id\":\"%s\"",
                     atol(machid), secret, store_device_id());
    if (os >= 1 && os <= 600) n += snprintf(body + n, sizeof(body) - n, ",\"p_open_seconds\":%d", os);
    snprintf(body + n, sizeof(body) - n, "}");

    char resp[512];
    int status = 0;
    esp_err_t err = rpc_post("device_migrate", body, resp, sizeof(resp), &status);
    memset(body, 0, sizeof(body));   // the secret should not linger on the stack
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "device_migrate transport error: %s", esp_err_to_name(err));
        return PAIR_NET_ERR;
    }
    if (status != 200) {
        ESP_LOGW(TAG, "device_migrate HTTP %d: %s", status, resp);
        return status >= 500 ? PAIR_NET_ERR : PAIR_REFUSED;
    }
    pair_result_t r = pair_store_reply(resp, "migration");
    if (r == PAIR_OK) migrate_wipe();
    return r;
}
