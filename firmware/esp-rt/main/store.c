#include "store.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "config.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "nvs.h"
#include "nvs_flash.h"

static const char *TAG = "store";
#define NS "rt"
#define SEEN_N   8
#define SEEN_LEN 64

rt_config_t g_cfg;

static char s_seen[SEEN_N][SEEN_LEN];
static int  s_seen_next;

void store_init(void) {
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);
}

static void get_str(nvs_handle_t h, const char *key, char *out, size_t sz) {
    size_t n = sz;
    if (nvs_get_str(h, key, out, &n) != ESP_OK) out[0] = 0;
}

void store_load(void) {
    memset(&g_cfg, 0, sizeof(g_cfg));
    strcpy(g_cfg.netmode, "gsm");
    nvs_handle_t h;
    if (nvs_open(NS, NVS_READONLY, &h) != ESP_OK) return;
    get_str(h, "netmode", g_cfg.netmode, sizeof(g_cfg.netmode));
    if (!g_cfg.netmode[0]) strcpy(g_cfg.netmode, "gsm");
    get_str(h, "ssid", g_cfg.ssid, sizeof(g_cfg.ssid));
    get_str(h, "pass", g_cfg.pass, sizeof(g_cfg.pass));
    get_str(h, "code", g_cfg.code, sizeof(g_cfg.code));
    get_str(h, "rt_topic", g_cfg.rt_topic, sizeof(g_cfg.rt_topic));
    get_str(h, "rt_key", g_cfg.rt_key, sizeof(g_cfg.rt_key));
    uint8_t pe = 0;
    if (nvs_get_u8(h, "pairerr", &pe) == ESP_OK) g_cfg.pair_error = pe != 0;
    size_t sz = sizeof(s_seen);
    if (nvs_get_blob(h, "seen", s_seen, &sz) != ESP_OK) memset(s_seen, 0, sizeof(s_seen));
    int32_t nx = 0;
    if (nvs_get_i32(h, "seen_nx", &nx) == ESP_OK && nx >= 0 && nx < SEEN_N) s_seen_next = nx;
    nvs_close(h);
}

void store_set_str(const char *key, const char *val) {
    nvs_handle_t h;
    if (nvs_open(NS, NVS_READWRITE, &h) != ESP_OK) return;
    nvs_set_str(h, key, val);
    nvs_commit(h);
    nvs_close(h);
}

void store_set_int(const char *key, int val) {
    nvs_handle_t h;
    if (nvs_open(NS, NVS_READWRITE, &h) != ESP_OK) return;
    if (strcmp(key, "pairerr") == 0) nvs_set_u8(h, key, (uint8_t)val);
    else nvs_set_i32(h, key, val);
    nvs_commit(h);
    nvs_close(h);
}

void store_erase(const char *key) {
    nvs_handle_t h;
    if (nvs_open(NS, NVS_READWRITE, &h) != ESP_OK) return;
    nvs_erase_key(h, key);
    nvs_commit(h);
    nvs_close(h);
}

bool store_has_network(void) {
    if (strcmp(g_cfg.netmode, "wifi") == 0) return g_cfg.ssid[0] != 0;
    return strcmp(g_cfg.netmode, "gsm") == 0;
}

bool store_paired(void) {
    return g_cfg.rt_topic[0] && g_cfg.rt_key[0];
}

const char *store_device_id(void) {
    static char id[13];
    if (!id[0]) {
        uint8_t mac[6];
        esp_read_mac(mac, ESP_MAC_WIFI_STA);
        snprintf(id, sizeof(id), "%02X%02X%02X%02X%02X%02X",
                 mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    }
    return id;
}

bool seen_has(const char *id) {
    for (int i = 0; i < SEEN_N; i++) {
        if (s_seen[i][0] && strncmp(s_seen[i], id, SEEN_LEN - 1) == 0) return true;
    }
    return false;
}

void seen_add(const char *id) {
    strlcpy(s_seen[s_seen_next], id, SEEN_LEN);
    s_seen_next = (s_seen_next + 1) % SEEN_N;
    nvs_handle_t h;
    if (nvs_open(NS, NVS_READWRITE, &h) != ESP_OK) { ESP_LOGW(TAG, "seen not persisted"); return; }
    nvs_set_blob(h, "seen", s_seen, sizeof(s_seen));
    nvs_set_i32(h, "seen_nx", s_seen_next);
    nvs_commit(h);
    nvs_close(h);
}
