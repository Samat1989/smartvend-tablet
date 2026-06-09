#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include "esp_wifi.h"
#include "esp_system.h"
#include "esp_mac.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "esp_event.h"
#include "esp_netif.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"

#include "esp_log.h"
#include "mqtt_client.h"
#include "driver/gpio.h"
#include "cJSON.h"

#include "esp_http_client.h"
#include "esp_http_server.h"
#include "esp_crt_bundle.h"
#include "esp_https_ota.h"

#include "lwip/sockets.h"

static const char *TAG = "relay_mart";

// --- CONFIGURATION ---
// WiFi + machine identity are no longer hardcoded — they are provisioned over a
// SoftAP setup portal and stored in NVS. Only the cloud endpoints stay fixed.
#define MQTT_HOST      "mqtt.smartvend.kz"
#define MQTT_PORT      14003

#define SUPABASE_BASE      "https://cgvfhtvdtdjsyluhlcbq.supabase.co/functions/v1"
#define SUPABASE_ANON_KEY  "sb_publishable_84RnaNCrFwxKicybxLGL2w_StEYpHnD"

// --- Firmware version + OTA (GitHub Releases, tag prefix "relay-v") ---
// FW_VERSION_CODE is the monotonic number compared against the release tag.
// Bump both on every release (release-relay.ps1 does this automatically).
// OTA shares the tablet's repo; firmware releases are tagged "relay-vX.Y.Z" and
// carry an asset named OTA_ASSET_NAME, so they never collide with the APK.
#define FW_VERSION_NAME    "1.0.1"
#define FW_VERSION_CODE    10001
#define OTA_OWNER_REPO     "Samat1989/smartvend-tablet"
#define OTA_TAG_PREFIX     "relay-v"
#define OTA_ASSET_NAME     "relay-mart.bin"

// Latching (bistable) relay — pins reverse-engineered from the stock firmware
// (see ../relay-test/README.md and esp32_dump/RELAY_CONTROL.md). DIR (IO2) sets
// the direction; a short pulse on PULSE (IO16) throws the relay, which then
// holds its state with no coil current.
#define RELAY_DIR_GPIO       GPIO_NUM_2    // IO2 — direction
#define RELAY_PULSE_GPIO     GPIO_NUM_16   // IO16 — coil pulse
#define RELAY_SETTLE_MS      100
#define RELAY_PULSE_MS       50
#define DEFAULT_OPEN_SECONDS 20            // relay hold time if not provisioned

// External hardware watchdog (ported from C:\smartvend\esp rtos.c): a WD chip
// reboots the board unless EXT_WD is pulsed HIGH for WD_PULSE_MS at least once
// every WD_RESET_MS. NOTE: GPIO32 exists only on classic ESP32 — build for the
// esp32 target (the relay board), not C3. Verify the pin against your wiring.
#define EXT_WD_GPIO          GPIO_NUM_32
#define WD_RESET_MS          120000        // kick interval
#define WD_PULSE_MS          500           // kick pulse width

// Network status LED (GPIO33) — background blink patterns for at-a-glance
// diagnostics: blink count encodes the connection stage. GPIO33 is classic-
// ESP32 only (like EXT_WD); build for the esp32 target.
#define STATUS_LED_GPIO      GPIO_NUM_33

// Re-provisioning trigger: within PROVISION_WINDOW_MS after power-on, tap the
// BOOT button (GPIO0) more than PROVISION_PRESS_COUNT times. (Sampling GPIO0
// here, after the chip has booted, is safe — holding it at reset instead would
// enter the ROM download mode.)
#define SETUP_BUTTON_GPIO    GPIO_NUM_0
#define PROVISION_WINDOW_MS  4000   // press-counting window after boot
#define PROVISION_PRESS_COUNT 3     // > this many presses -> provisioning

#define NVS_CFG_NS        "cfg"
// ---------------------

// Provisioned config (loaded from NVS, or filled in by the setup portal).
static char g_wifi_ssid[64]   = {0};
static char g_wifi_pass[64]   = {0};
static char g_machid[16]      = {0};
static char g_mqtt_uuid[48]   = {0};   // MQTT username / client_id
static char g_mqtt_secret[40] = {0};   // MQTT password
static char g_mqtt_topic[80]  = {0};   // vending/<uuid>/in

static bool g_provisioning = false;
static bool is_lock_active = false;
static char last_order_id[64] = {0};

// Live connection state for the diagnostic LED. The LED task derives the blink
// pattern from these flags every cycle, so it always reflects the ACTUAL state
// regardless of the order wifi/mqtt events arrive in — e.g. a WiFi drop clears
// both flags, so MQTT's later disconnect event can't leave a stale "got IP".
//   neither -> 1 blink,  has IP -> 2,  + MQTT -> 3,  provisioning -> 5 + solid.
static volatile bool g_has_ip  = false;   // WiFi associated + IP acquired
static volatile bool g_mqtt_up = false;   // MQTT session connected
static int  g_open_seconds = DEFAULT_OPEN_SECONDS;  // relay hold time (provisioned)

// WiFi STA connection signalling (used while provisioning to know if the
// entered credentials actually work before we commit them).
static EventGroupHandle_t s_wifi_eg;
#define WIFI_CONNECTED_BIT BIT0
#define WIFI_FAIL_BIT      BIT1
static int s_sta_retries = 0;

// ============================ NVS config ============================
static esp_err_t cfg_get(const char *key, char *out, size_t out_sz) {
    nvs_handle_t h;
    if (nvs_open(NVS_CFG_NS, NVS_READONLY, &h) != ESP_OK) return ESP_FAIL;
    size_t sz = out_sz;
    esp_err_t err = nvs_get_str(h, key, out, &sz);
    nvs_close(h);
    return err;
}

static void cfg_set(const char *key, const char *val) {
    nvs_handle_t h;
    if (nvs_open(NVS_CFG_NS, NVS_READWRITE, &h) == ESP_OK) {
        nvs_set_str(h, key, val);
        nvs_commit(h);
        nvs_close(h);
    }
}

static void cfg_erase(void) {
    nvs_handle_t h;
    if (nvs_open(NVS_CFG_NS, NVS_READWRITE, &h) == ESP_OK) {
        nvs_erase_all(h);
        nvs_commit(h);
        nvs_close(h);
    }
    ESP_LOGI(TAG, "[CFG] erased");
}

// Returns true when a complete config is present (wifi + machine identity).
static bool cfg_load(void) {
    char osbuf[8];
    if (cfg_get("opensec", osbuf, sizeof(osbuf)) == ESP_OK) {
        int v = atoi(osbuf);
        if (v >= 1 && v <= 600) g_open_seconds = v;
    }
    if (cfg_get("ssid", g_wifi_ssid, sizeof(g_wifi_ssid)) != ESP_OK) return false;
    cfg_get("pass", g_wifi_pass, sizeof(g_wifi_pass));   // empty pass allowed
    if (cfg_get("machid", g_machid, sizeof(g_machid)) != ESP_OK) return false;
    if (cfg_get("uuid", g_mqtt_uuid, sizeof(g_mqtt_uuid)) != ESP_OK) return false;
    if (cfg_get("secret", g_mqtt_secret, sizeof(g_mqtt_secret)) != ESP_OK) return false;
    if (g_wifi_ssid[0] == 0 || g_mqtt_uuid[0] == 0 || g_mqtt_secret[0] == 0) return false;
    snprintf(g_mqtt_topic, sizeof(g_mqtt_topic), "vending/%s/in", g_mqtt_uuid);
    return true;
}

// ============================ NVS: last order (idempotency across reboots) ===
static void save_last_order_to_nvs(const char* orderid) {
    nvs_handle_t nvs;
    if (nvs_open("storage", NVS_READWRITE, &nvs) == ESP_OK) {
        nvs_set_str(nvs, "last_order", orderid);
        nvs_commit(nvs);
        nvs_close(nvs);
        ESP_LOGI(TAG, "[NVS] Saved last_order_id: %s", orderid);
    }
}

static void load_last_order_from_nvs(void) {
    nvs_handle_t nvs;
    if (nvs_open("storage", NVS_READONLY, &nvs) == ESP_OK) {
        size_t sz = sizeof(last_order_id);
        if (nvs_get_str(nvs, "last_order", last_order_id, &sz) == ESP_OK) {
            ESP_LOGI(TAG, "[NVS] Loaded last_order_id: %s", last_order_id);
        }
        nvs_close(nvs);
    }
}

// ============================ complete-order notify ============================
static esp_err_t post_order_once(const char* orderid) {
    char url[96];
    snprintf(url, sizeof(url), "%s/complete-order", SUPABASE_BASE);
    char post_data[128];
    snprintf(post_data, sizeof(post_data), "{\"orderid\":\"%s\"}", orderid);

    esp_http_client_config_t config = {
        .url = url,
        .method = HTTP_METHOD_POST,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .timeout_ms = 15000,
    };
    esp_http_client_handle_t client = esp_http_client_init(&config);
    esp_http_client_set_header(client, "Content-Type", "application/json");
    esp_http_client_set_header(client, "apikey", SUPABASE_ANON_KEY);
    esp_http_client_set_header(client, "Authorization", "Bearer " SUPABASE_ANON_KEY);
    esp_http_client_set_post_field(client, post_data, strlen(post_data));

    esp_err_t err = esp_http_client_perform(client);
    int status = esp_http_client_get_status_code(client);
    if (err == ESP_OK) {
        ESP_LOGI(TAG, "HTTP POST Status = %d", status);
    } else {
        ESP_LOGE(TAG, "HTTP POST request failed: %s", esp_err_to_name(err));
    }
    esp_http_client_cleanup(client);
    return (err == ESP_OK && status >= 200 && status < 300) ? ESP_OK : ESP_FAIL;
}

// Own task so lock timing stays independent of the network; retries on failure.
static void notify_task(void *pvParameters) {
    char* orderid = (char*)pvParameters;
    if (orderid) {
        for (int attempt = 1; attempt <= 3; attempt++) {
            if (post_order_once(orderid) == ESP_OK) break;
            ESP_LOGW(TAG, "complete-order notify attempt %d failed, retrying...", attempt);
            vTaskDelay(pdMS_TO_TICKS(3000));
        }
        free(orderid);
    }
    vTaskDelete(NULL);
}

// ============================ Relay (latching) ============================
// Configure both relay pins as outputs, driven low. Safe to call once at boot.
static void relay_pins_init(void) {
    gpio_config_t io = {
        .pin_bit_mask = (1ULL << RELAY_DIR_GPIO) | (1ULL << RELAY_PULSE_GPIO),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&io);
    gpio_set_level(RELAY_DIR_GPIO, 0);
    gpio_set_level(RELAY_PULSE_GPIO, 0);
}

// Latching ACTIVATE: DIR HIGH, settle, pulse coil, settle, DIR LOW.
static void relay_on(void) {
    gpio_set_level(RELAY_DIR_GPIO, 1);   vTaskDelay(pdMS_TO_TICKS(RELAY_SETTLE_MS));
    gpio_set_level(RELAY_PULSE_GPIO, 1); vTaskDelay(pdMS_TO_TICKS(RELAY_PULSE_MS));
    gpio_set_level(RELAY_PULSE_GPIO, 0); vTaskDelay(pdMS_TO_TICKS(RELAY_SETTLE_MS));
    gpio_set_level(RELAY_DIR_GPIO, 0);
}

// Latching DEACTIVATE: DIR(IO2) LOW, settle, pulse coil. Leaves DIR low.
static void relay_off(void) {
    gpio_set_level(RELAY_DIR_GPIO, 0);   vTaskDelay(pdMS_TO_TICKS(RELAY_SETTLE_MS));
    gpio_set_level(RELAY_PULSE_GPIO, 1); vTaskDelay(pdMS_TO_TICKS(RELAY_PULSE_MS));
    gpio_set_level(RELAY_PULSE_GPIO, 0);
}

// Open the relay for the provisioned hold time, then latch it closed.
static void trigger_lock(void *pvParameters) {
    is_lock_active = true;
    ESP_LOGI(TAG, "🔓 RELAY ON (DIR IO%d / PULSE IO%d) for %d s",
             RELAY_DIR_GPIO, RELAY_PULSE_GPIO, g_open_seconds);
    relay_on();
    vTaskDelay(pdMS_TO_TICKS((uint32_t)g_open_seconds * 1000));
    relay_off();
    ESP_LOGI(TAG, "🔒 RELAY OFF");
    is_lock_active = false;
    vTaskDelete(NULL);
}

// ============================ External watchdog ============================
// Keep the hardware WD chip satisfied so it never reboots the board: every
// WD_RESET_MS drive EXT_WD HIGH for WD_PULSE_MS, then back LOW.
static void ext_wd_task(void *arg) {
    const TickType_t reset_ticks = pdMS_TO_TICKS(WD_RESET_MS);
    const TickType_t pulse_ticks = pdMS_TO_TICKS(WD_PULSE_MS);
    TickType_t last_reset = xTaskGetTickCount();
    TickType_t last_pulse = last_reset;
    bool wd_high = false;

    gpio_set_level(EXT_WD_GPIO, 0);

    while (1) {
        TickType_t now = xTaskGetTickCount();

        if (!wd_high && (now - last_reset) >= reset_ticks) {
            gpio_set_level(EXT_WD_GPIO, 1);
            ESP_LOGI(TAG, "ext wd reset, level HIGH");
            last_pulse = now;
            last_reset = now;
            wd_high = true;
        }

        if (wd_high && (now - last_pulse) >= pulse_ticks) {
            gpio_set_level(EXT_WD_GPIO, 0);
            ESP_LOGI(TAG, "ext wd level LOW");
            wd_high = false;
        }

        vTaskDelay(pdMS_TO_TICKS(50));
    }
}

// Configure EXT_WD, give a boot kick, and start the keep-alive task. Must run in
// every mode (incl. provisioning) or the WD reboots the board mid-setup.
static void ext_wd_start(void) {
    gpio_config_t io = {
        .pin_bit_mask = 1ULL << EXT_WD_GPIO,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&io);
    gpio_set_level(EXT_WD_GPIO, 0);

    // Initial kick so the WD doesn't fire while we boot.
    gpio_set_level(EXT_WD_GPIO, 1);
    vTaskDelay(pdMS_TO_TICKS(WD_PULSE_MS));
    gpio_set_level(EXT_WD_GPIO, 0);
    ESP_LOGI(TAG, "ext wd boot kick: HIGH then LOW");

    xTaskCreate(ext_wd_task, "ext_wd", 2048, NULL, 5, NULL);
}

// ============================ Network status LED ============================
static void led_blink(int times, int on_ms, int off_ms) {
    for (int i = 0; i < times; i++) {
        gpio_set_level(STATUS_LED_GPIO, 1);
        vTaskDelay(pdMS_TO_TICKS(on_ms));
        gpio_set_level(STATUS_LED_GPIO, 0);
        if (off_ms) vTaskDelay(pdMS_TO_TICKS(off_ms));
    }
}

// Background diagnostics LED: the blink count tells the connection stage at a
// glance — 1 = no link, 2 = got IP, 3 = MQTT up (each + 1 s pause). During
// provisioning: 5 fast blinks once, then the LED stays solid ON.
static void status_led_task(void *arg) {
    gpio_config_t io = {
        .pin_bit_mask = 1ULL << STATUS_LED_GPIO,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&io);
    gpio_set_level(STATUS_LED_GPIO, 0);

    bool prev_provision = false;
    while (1) {
        if (g_provisioning) {
            if (!prev_provision) led_blink(5, 80, 80);  // announce entry once
            prev_provision = true;
            gpio_set_level(STATUS_LED_GPIO, 1);         // solid ON during setup
            vTaskDelay(pdMS_TO_TICKS(300));
            continue;
        }
        prev_provision = false;
        // Blink count = live connection stage, recomputed every cycle.
        int n = g_mqtt_up ? 3 : g_has_ip ? 2 : 1;
        led_blink(n, 100, 150);
        vTaskDelay(pdMS_TO_TICKS(1500));                // 1.5 s pause between groups
    }
}

// ============================ MQTT ============================
static void mqtt_event_handler(void *handler_args, esp_event_base_t base, int32_t event_id, void *event_data) {
    esp_mqtt_event_handle_t event = event_data;
    esp_mqtt_client_handle_t client = event->client;
    int msg_id;

    switch ((esp_mqtt_event_id_t)event_id) {
        case MQTT_EVENT_CONNECTED:
            ESP_LOGI(TAG, "MQTT Connected");
            g_mqtt_up = true;
            msg_id = esp_mqtt_client_subscribe(client, g_mqtt_topic, 0);
            ESP_LOGI(TAG, "Subscribed to %s, msg_id=%d", g_mqtt_topic, msg_id);
            break;
        case MQTT_EVENT_DISCONNECTED:
            ESP_LOGI(TAG, "MQTT Disconnected");
            g_mqtt_up = false;
            break;
        case MQTT_EVENT_DATA: {
            cJSON *json = cJSON_ParseWithLength(event->data, event->data_len);
            if (json) {
                cJSON *msg = cJSON_GetObjectItem(json, "msg");
                cJSON *code = cJSON_GetObjectItem(json, "code");
                cJSON *orderid = cJSON_GetObjectItem(json, "orderid");

                if (msg && cJSON_IsString(msg) && strcmp(msg->valuestring, "Processed order") == 0) {
                    if (code && cJSON_IsNumber(code) && code->valueint == 1) {
                        if (is_lock_active) {
                            ESP_LOGI(TAG, "Already opening... ignoring request.");
                            cJSON_Delete(json);
                            return;
                        }
                        if (orderid && cJSON_IsString(orderid)) {
                            if (strcmp(last_order_id, orderid->valuestring) == 0) {
                                ESP_LOGI(TAG, "Duplicate order ID detected (%s). Skipping.", last_order_id);
                            } else {
                                ESP_LOGI(TAG, "✅ New Payment confirmed! Order: %s", orderid->valuestring);
                                strncpy(last_order_id, orderid->valuestring, sizeof(last_order_id) - 1);
                                save_last_order_to_nvs(last_order_id);

                                // Open the lock and notify the server on separate
                                // tasks: door timing must not wait on the network,
                                // and the HTTPS/TLS POST needs a larger stack.
                                xTaskCreate(trigger_lock, "lock_task", 4096, NULL, 5, NULL);
                                char* id_copy = strdup(orderid->valuestring);
                                xTaskCreate(notify_task, "notify_task", 8192, (void*)id_copy, 5, NULL);
                            }
                        }
                    }
                }
                cJSON_Delete(json);
            }
            break;
        }
        case MQTT_EVENT_ERROR:
            ESP_LOGI(TAG, "MQTT Error");
            break;
        default:
            break;
    }
}

static void mqtt_start(void) {
    char uri[64];
    snprintf(uri, sizeof(uri), "mqtt://%s:%d", MQTT_HOST, MQTT_PORT);
    esp_mqtt_client_config_t mqtt_cfg = {
        .broker.address.uri = uri,
        .credentials.username = g_mqtt_uuid,
        .credentials.client_id = g_mqtt_uuid,
        .credentials.authentication.password = g_mqtt_secret,
        .session.keepalive = 30,
    };
    esp_mqtt_client_handle_t client = esp_mqtt_client_init(&mqtt_cfg);
    esp_mqtt_client_register_event(client, ESP_EVENT_ANY_ID, mqtt_event_handler, NULL);
    esp_mqtt_client_start(client);
    ESP_LOGI(TAG, "MQTT started for machid=%s (%s)", g_machid, g_mqtt_uuid);
}

// ============================ WiFi ============================
static void wifi_event_handler(void* arg, esp_event_base_t base, int32_t id, void* data) {
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        if (!g_provisioning) esp_wifi_connect();   // in setup we connect only after creds are entered
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        if (g_provisioning) {
            // Bounded retries so a wrong password reports back instead of looping.
            if (s_sta_retries < 5) {
                s_sta_retries++;
                esp_wifi_connect();
            } else {
                xEventGroupSetBits(s_wifi_eg, WIFI_FAIL_BIT);
            }
        } else {
            esp_wifi_connect();   // normal mode: keep trying forever
            ESP_LOGI(TAG, "Retry connecting to WiFi...");
            // Lost link: clear both flags. MQTT's own disconnect event will also
            // fire, but order no longer matters — the LED drops to 1 blink.
            g_has_ip = false;
            g_mqtt_up = false;
        }
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t* e = (ip_event_got_ip_t*) data;
        ESP_LOGI(TAG, "Got IP: " IPSTR, IP2STR(&e->ip_info.ip));
        s_sta_retries = 0;
        g_has_ip = true;
        if (s_wifi_eg) xEventGroupSetBits(s_wifi_eg, WIFI_CONNECTED_BIT);
    }
}

// Connect STA to the given credentials; returns true on GOT_IP within timeout.
static bool wifi_sta_try(const char* ssid, const char* pass) {
    s_sta_retries = 0;
    xEventGroupClearBits(s_wifi_eg, WIFI_CONNECTED_BIT | WIFI_FAIL_BIT);

    wifi_config_t sta = {0};
    strncpy((char*)sta.sta.ssid, ssid, sizeof(sta.sta.ssid) - 1);
    strncpy((char*)sta.sta.password, pass, sizeof(sta.sta.password) - 1);
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &sta));
    esp_wifi_connect();

    EventBits_t bits = xEventGroupWaitBits(s_wifi_eg, WIFI_CONNECTED_BIT | WIFI_FAIL_BIT,
                                           pdFALSE, pdFALSE, pdMS_TO_TICKS(20000));
    return (bits & WIFI_CONNECTED_BIT) != 0;
}

static void wifi_start_normal(void) {
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    wifi_config_t sta = {0};
    strncpy((char*)sta.sta.ssid, g_wifi_ssid, sizeof(sta.sta.ssid) - 1);
    strncpy((char*)sta.sta.password, g_wifi_pass, sizeof(sta.sta.password) - 1);
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &sta));
    ESP_ERROR_CHECK(esp_wifi_start());
}

// ============================ device-provision fetch ============================
// GET /device-provision?machid=<machid> -> { uuid, secret, name }. Fills the
// globals + persists to NVS. Returns true on success.
static bool provision_fetch_and_store(const char* machid) {
    char url[128];
    snprintf(url, sizeof(url), "%s/device-provision?machid=%s", SUPABASE_BASE, machid);

    esp_http_client_config_t config = {
        .url = url,
        .method = HTTP_METHOD_GET,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .timeout_ms = 15000,
    };
    esp_http_client_handle_t client = esp_http_client_init(&config);
    esp_http_client_set_header(client, "apikey", SUPABASE_ANON_KEY);
    esp_http_client_set_header(client, "Authorization", "Bearer " SUPABASE_ANON_KEY);

    bool ok = false;
    if (esp_http_client_open(client, 0) == ESP_OK) {
        esp_http_client_fetch_headers(client);
        char buf[512] = {0};
        int rd = esp_http_client_read_response(client, buf, sizeof(buf) - 1);
        int status = esp_http_client_get_status_code(client);
        ESP_LOGI(TAG, "[Provision] status=%d body=%s", status, buf);
        if (status == 200 && rd > 0) {
            cJSON *j = cJSON_Parse(buf);
            if (j) {
                cJSON *uuid = cJSON_GetObjectItem(j, "uuid");
                cJSON *secret = cJSON_GetObjectItem(j, "secret");
                if (cJSON_IsString(uuid) && cJSON_IsString(secret) &&
                    uuid->valuestring[0] && secret->valuestring[0]) {
                    strncpy(g_mqtt_uuid, uuid->valuestring, sizeof(g_mqtt_uuid) - 1);
                    strncpy(g_mqtt_secret, secret->valuestring, sizeof(g_mqtt_secret) - 1);
                    cfg_set("uuid", g_mqtt_uuid);
                    cfg_set("secret", g_mqtt_secret);
                    ok = true;
                }
                cJSON_Delete(j);
            }
        }
    }
    esp_http_client_cleanup(client);
    return ok;
}

// ============================ OTA (GitHub Releases) ============================
// Accumulate an HTTP response body into a bounded heap buffer.
typedef struct { char *buf; int len; int cap; } http_accum_t;
static esp_err_t ota_http_accum(esp_http_client_event_t *e) {
    if (e->event_id == HTTP_EVENT_ON_DATA && e->user_data) {
        http_accum_t *a = e->user_data;
        if (a->len + e->data_len < a->cap) {
            memcpy(a->buf + a->len, e->data, e->data_len);
            a->len += e->data_len;
        }
    }
    return ESP_OK;
}

// Parse a version code from a tag like "relay-v1.2.3" or "relay-v1.2.3+10203".
// Returns -1 if the tag doesn't carry our prefix.
static long ota_tag_code(const char *tag) {
    size_t pl = strlen(OTA_TAG_PREFIX);
    if (strncmp(tag, OTA_TAG_PREFIX, pl) != 0) return -1;
    const char *v = tag + pl;
    const char *plus = strchr(v, '+');
    if (plus) return atol(plus + 1);             // explicit +<code>
    int a = 0, b = 0, c = 0;                      // else derive X.Y.Z -> X*10000+Y*100+Z
    sscanf(v, "%d.%d.%d", &a, &b, &c);
    return (long)a * 10000 + b * 100 + c;
}

// Query GitHub for the newest "relay-v*" release. If its code beats ours, copy
// the OTA_ASSET_NAME download URL into url_out and return true.
static bool ota_find_update(char *url_out, size_t url_sz) {
    char api[160];
    snprintf(api, sizeof(api),
             "https://api.github.com/repos/%s/releases?per_page=20", OTA_OWNER_REPO);

    const int cap = 24576;
    char *body = malloc(cap);
    if (!body) return false;
    http_accum_t acc = { .buf = body, .len = 0, .cap = cap };

    esp_http_client_config_t cfg = {
        .url = api,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .event_handler = ota_http_accum,
        .user_data = &acc,
        .timeout_ms = 15000,
    };
    esp_http_client_handle_t cli = esp_http_client_init(&cfg);
    esp_http_client_set_header(cli, "Accept", "application/vnd.github+json");
    esp_http_client_set_header(cli, "User-Agent", "esp-relay-ota");
    esp_err_t err = esp_http_client_perform(cli);
    int status = esp_http_client_get_status_code(cli);
    esp_http_client_cleanup(cli);

    bool found = false;
    if (err == ESP_OK && status == 200) {
        acc.buf[acc.len < cap ? acc.len : cap - 1] = 0;
        cJSON *root = cJSON_Parse(acc.buf);
        if (root && cJSON_IsArray(root)) {
            long best = FW_VERSION_CODE;
            cJSON *rel;
            cJSON_ArrayForEach(rel, root) {
                cJSON *tag = cJSON_GetObjectItem(rel, "tag_name");
                cJSON *pre = cJSON_GetObjectItem(rel, "prerelease");
                if (!cJSON_IsString(tag) || cJSON_IsTrue(pre)) continue;
                long code = ota_tag_code(tag->valuestring);
                if (code <= best) continue;
                cJSON *assets = cJSON_GetObjectItem(rel, "assets");
                cJSON *as;
                cJSON_ArrayForEach(as, assets) {
                    cJSON *nm = cJSON_GetObjectItem(as, "name");
                    cJSON *u  = cJSON_GetObjectItem(as, "browser_download_url");
                    if (cJSON_IsString(nm) && cJSON_IsString(u) &&
                        strcmp(nm->valuestring, OTA_ASSET_NAME) == 0) {
                        strncpy(url_out, u->valuestring, url_sz - 1);
                        url_out[url_sz - 1] = 0;
                        best = code;
                        found = true;
                        ESP_LOGI(TAG, "OTA: found %s (code %ld)", tag->valuestring, code);
                        break;
                    }
                }
            }
        }
        if (root) cJSON_Delete(root);
    } else {
        ESP_LOGW(TAG, "OTA check failed: err=%s status=%d", esp_err_to_name(err), status);
    }
    free(body);
    return found;
}

// Download + flash the firmware at `url` via esp_https_ota; reboots on success.
static void ota_apply(const char *url) {
    ESP_LOGW(TAG, "OTA: downloading & flashing %s", url);
    esp_http_client_config_t http = {
        .url = url,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .timeout_ms = 30000,
        .keep_alive_enable = true,
    };
    esp_https_ota_config_t ota = { .http_config = &http };
    esp_err_t err = esp_https_ota(&ota);
    if (err == ESP_OK) {
        ESP_LOGW(TAG, "OTA OK — rebooting into new firmware");
        esp_restart();
    } else {
        ESP_LOGE(TAG, "OTA failed: %s — keeping current firmware", esp_err_to_name(err));
    }
}

// Check GitHub for a newer firmware and apply it. Requires WiFi up. Returns to
// the caller only when there is no update (or it failed); reboots on success.
static void ota_check_and_update(void) {
    char url[256];
    ESP_LOGI(TAG, "OTA: current v%s (code %d), checking %s ...",
             FW_VERSION_NAME, FW_VERSION_CODE, OTA_OWNER_REPO);
    if (ota_find_update(url, sizeof(url))) {
        ota_apply(url);            // reboots on success
    } else {
        ESP_LOGI(TAG, "OTA: already up to date");
    }
}

// ============================ Setup portal (SoftAP + HTTP) ============================
// Page split around the SSID <select> so a fresh WiFi scan can be injected as
// <option>s (a visible dropdown). A separate text field allows a hidden SSID.
static const char PAGE_HEAD[] =
    "<!DOCTYPE html><html><head><meta name=viewport content='width=device-width,initial-scale=1'>"
    "<title>SmartVend Setup</title><style>"
    "body{font-family:sans-serif;background:#1f2937;color:#fff;margin:0;padding:24px}"
    "h2{margin-top:0}label{display:block;margin:14px 0 4px;font-size:14px;opacity:.8}"
    "input,select{width:100%;box-sizing:border-box;padding:12px;border-radius:8px;border:none;font-size:16px}"
    "button{width:100%;margin-top:20px;padding:14px;border:none;border-radius:8px;background:#F14635;color:#fff;font-size:16px;font-weight:bold}"
    "</style></head><body><h2>SmartVend — настройка</h2>"
    "<form method=POST action=/save>"
    "<label>WiFi сеть</label><select name=ssid><option value=''>— выберите сеть —</option>";
static const char PAGE_TAIL_A[] =
    "</select>"
    "<label>Скрытая сеть? Имя вручную</label><input name=ssid2 autocomplete=off placeholder='(необязательно)'>"
    "<label>WiFi пароль</label><input name=pass type=password>"
    "<label>Номер аппарата (Machine ID)</label><input name=machid required inputmode=numeric>"
    "<label>Время включения реле, сек</label>"
    "<input name=opensec type=number min=1 max=600 inputmode=numeric value='";
static const char PAGE_TAIL_B[] =
    "'><button type=submit>Сохранить и подключить</button></form></body></html>";

static esp_err_t root_get_handler(httpd_req_t *req) {
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    httpd_resp_sendstr_chunk(req, PAGE_HEAD);

    // Scan nearby networks and offer them as datalist options.
    wifi_scan_config_t sc = { .show_hidden = false };
    if (esp_wifi_scan_start(&sc, true) == ESP_OK) {
        uint16_t n = 0;
        esp_wifi_scan_get_ap_num(&n);
        if (n > 20) n = 20;
        wifi_ap_record_t recs[20];
        uint16_t got = n;
        if (esp_wifi_scan_get_ap_records(&got, recs) == ESP_OK) {
            for (uint16_t i = 0; i < got; i++) {
                if (recs[i].ssid[0] == 0) continue;
                char opt[80];
                snprintf(opt, sizeof(opt), "<option>%s</option>", (char*)recs[i].ssid);
                httpd_resp_sendstr_chunk(req, opt);
            }
        }
    }

    httpd_resp_sendstr_chunk(req, PAGE_TAIL_A);
    char osval[8];
    snprintf(osval, sizeof(osval), "%d", g_open_seconds);
    httpd_resp_sendstr_chunk(req, osval);
    httpd_resp_sendstr_chunk(req, PAGE_TAIL_B);
    httpd_resp_sendstr_chunk(req, NULL);   // end response
    return ESP_OK;
}

// Captive-portal: any unknown URL (OS connectivity probes) → redirect to the
// setup form, so the captive sheet pops open automatically.
static esp_err_t captive_redirect(httpd_req_t *req, httpd_err_code_t err) {
    httpd_resp_set_status(req, "302 Found");
    httpd_resp_set_hdr(req, "Location", "http://192.168.4.1/");
    httpd_resp_send(req, NULL, 0);
    return ESP_OK;
}

// Minimal DNS server: answer every A query with the AP IP (192.168.4.1) so the
// phone resolves all probe domains to us and triggers the captive portal.
static void dns_hijack_task(void *pv) {
    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
    if (sock < 0) { vTaskDelete(NULL); return; }
    struct sockaddr_in sa = { .sin_family = AF_INET, .sin_port = htons(53), .sin_addr.s_addr = htonl(INADDR_ANY) };
    if (bind(sock, (struct sockaddr*)&sa, sizeof(sa)) < 0) { close(sock); vTaskDelete(NULL); return; }

    uint8_t buf[512];
    while (1) {
        struct sockaddr_in client;
        socklen_t cl = sizeof(client);
        int len = recvfrom(sock, buf, sizeof(buf), 0, (struct sockaddr*)&client, &cl);
        if (len < 12 || (size_t)len + 16 > sizeof(buf)) continue;   // need room for the answer
        buf[2] = 0x81; buf[3] = 0x80;   // flags: standard query response, no error
        buf[6] = 0x00; buf[7] = 0x01;   // ANCOUNT = 1
        // Append an A answer pointing the queried name at 192.168.4.1.
        uint8_t ans[16] = { 0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C,
                            0x00, 0x04, 192, 168, 4, 1 };
        memcpy(buf + len, ans, sizeof(ans));
        sendto(sock, buf, len + sizeof(ans), 0, (struct sockaddr*)&client, cl);
    }
}

// URL-decode src into dst (handles %XX and '+').
static void url_decode(const char *src, char *dst, size_t dst_sz) {
    size_t di = 0;
    for (size_t i = 0; src[i] && di + 1 < dst_sz; i++) {
        if (src[i] == '%' && src[i+1] && src[i+2]) {
            char hex[3] = { src[i+1], src[i+2], 0 };
            dst[di++] = (char) strtol(hex, NULL, 16);
            i += 2;
        } else if (src[i] == '+') {
            dst[di++] = ' ';
        } else {
            dst[di++] = src[i];
        }
    }
    dst[di] = 0;
}

// Extract field `name` from an application/x-www-form-urlencoded body.
static bool form_field(const char *body, const char *name, char *out, size_t out_sz) {
    char key[24];
    snprintf(key, sizeof(key), "%s=", name);
    const char *p = strstr(body, key);
    if (!p) return false;
    p += strlen(key);
    const char *end = strchr(p, '&');
    size_t len = end ? (size_t)(end - p) : strlen(p);
    char raw[96];
    if (len >= sizeof(raw)) len = sizeof(raw) - 1;
    memcpy(raw, p, len);
    raw[len] = 0;
    url_decode(raw, out, out_sz);
    return true;
}

static esp_err_t send_msg(httpd_req_t *req, const char *title, const char *body) {
    char page[512];
    snprintf(page, sizeof(page),
        "<!DOCTYPE html><html><head><meta name=viewport content='width=device-width,initial-scale=1'>"
        "<style>body{font-family:sans-serif;background:#1f2937;color:#fff;padding:24px;text-align:center}"
        "a{color:#F14635}</style></head><body><h2>%s</h2><p>%s</p></body></html>", title, body);
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    httpd_resp_send(req, page, HTTPD_RESP_USE_STRLEN);
    return ESP_OK;
}

// After provisioning: let the reply flush, then check for a firmware update
// (WiFi is already connected at this point). esp_https_ota reboots into the new
// image on success; otherwise we reboot into normal mode. Needs a big stack for
// the TLS + OTA download.
static void provision_finish_task(void *pv) {
    vTaskDelay(pdMS_TO_TICKS(2000));   // let the "Готово" page reach the phone
    ota_check_and_update();             // reboots if a newer firmware is flashed
    esp_restart();                      // no update -> reboot into normal mode
}

static esp_err_t save_post_handler(httpd_req_t *req) {
    char body[512];
    int len = httpd_req_recv(req, body, sizeof(body) - 1);
    if (len <= 0) return ESP_FAIL;
    body[len] = 0;

    char ssid[64] = {0}, ssid2[64] = {0}, pass[64] = {0}, machid[16] = {0}, opensec[8] = {0};
    form_field(body, "ssid", ssid, sizeof(ssid));
    form_field(body, "ssid2", ssid2, sizeof(ssid2));   // manual / hidden SSID
    form_field(body, "pass", pass, sizeof(pass));
    form_field(body, "machid", machid, sizeof(machid));
    form_field(body, "opensec", opensec, sizeof(opensec));
    if (ssid2[0]) strncpy(ssid, ssid2, sizeof(ssid) - 1);   // manual entry overrides dropdown
    if (ssid[0] == 0 || machid[0] == 0) {
        return send_msg(req, "Ошибка", "Выберите сеть (или впишите вручную) и номер аппарата. <a href=/>Назад</a>");
    }
    ESP_LOGI(TAG, "[Setup] ssid=%s machid=%s", ssid, machid);

    // 1) Try the WiFi credentials before committing.
    if (!wifi_sta_try(ssid, pass)) {
        return send_msg(req, "WiFi не подключился", "Проверьте сеть и пароль. <a href=/>Назад</a>");
    }

    // 2) Look up this machine's MQTT identity by machid.
    if (!provision_fetch_and_store(machid)) {
        return send_msg(req, "Аппарат не найден",
                        "Номер не найден в системе или нет связи. <a href=/>Назад</a>");
    }

    // 3) Commit WiFi + machid + relay hold time; reboot into normal mode.
    int osv = atoi(opensec);
    if (osv < 1 || osv > 600) osv = DEFAULT_OPEN_SECONDS;
    g_open_seconds = osv;
    char osstr[8];
    snprintf(osstr, sizeof(osstr), "%d", osv);
    cfg_set("ssid", ssid);
    cfg_set("pass", pass);
    cfg_set("machid", machid);
    cfg_set("opensec", osstr);
    ESP_LOGI(TAG, "[Setup] provisioned OK — checking firmware update, then rebooting");
    send_msg(req, "Готово!", "Аппарат настроен. Проверяю обновление прошивки и перезагружаюсь.");
    xTaskCreate(provision_finish_task, "provfin", 10240, NULL, 5, NULL);
    return ESP_OK;
}

static void start_setup_portal(void) {
    g_provisioning = true;   // LED task picks this up: 5 fast blinks, then solid ON

    // SoftAP (open) + STA (so we can validate WiFi and reach Supabase).
    esp_netif_t *ap_netif = esp_netif_create_default_wifi_ap();
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_APSTA));

    // Hand out our own IP as the DNS server so every lookup hits the hijack
    // server below → the phone's captive-portal check opens the setup page.
    esp_netif_dns_info_t dns = {0};
    dns.ip.type = ESP_IPADDR_TYPE_V4;
    esp_ip4_addr_t apip;
    esp_netif_str_to_ip4("192.168.4.1", &apip);
    dns.ip.u_addr.ip4.addr = apip.addr;
    esp_netif_dhcps_stop(ap_netif);
    esp_netif_set_dns_info(ap_netif, ESP_NETIF_DNS_MAIN, &dns);
    uint8_t offer_dns = 0x02;   // dhcps_offer_t OFFER_DNS — advertise DNS via DHCP
    esp_netif_dhcps_option(ap_netif, ESP_NETIF_OP_SET, ESP_NETIF_DOMAIN_NAME_SERVER, &offer_dns, sizeof(offer_dns));
    esp_netif_dhcps_start(ap_netif);

    uint8_t mac[6];
    esp_wifi_get_mac(WIFI_IF_AP, mac);
    wifi_config_t ap = {0};
    snprintf((char*)ap.ap.ssid, sizeof(ap.ap.ssid), "SmartVend-Setup-%02X%02X", mac[4], mac[5]);
    ap.ap.ssid_len = strlen((char*)ap.ap.ssid);
    ap.ap.authmode = WIFI_AUTH_OPEN;   // open AP (per setup decision)
    ap.ap.max_connection = 2;
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &ap));
    ESP_ERROR_CHECK(esp_wifi_start());
    ESP_LOGI(TAG, "[Setup] AP '%s' up — connect and open http://192.168.4.1", ap.ap.ssid);

    httpd_config_t hcfg = HTTPD_DEFAULT_CONFIG();
    hcfg.stack_size = 12288;           // TLS client runs inside the POST handler
    httpd_handle_t server = NULL;
    if (httpd_start(&server, &hcfg) == ESP_OK) {
        httpd_uri_t root = { .uri = "/", .method = HTTP_GET, .handler = root_get_handler };
        httpd_uri_t save = { .uri = "/save", .method = HTTP_POST, .handler = save_post_handler };
        httpd_register_uri_handler(server, &root);
        httpd_register_uri_handler(server, &save);
        // Redirect all other paths (OS probe URLs) to the form.
        httpd_register_err_handler(server, HTTPD_404_NOT_FOUND, captive_redirect);
    }

    // DNS hijack so probe domains resolve to us (captive portal trigger).
    xTaskCreate(dns_hijack_task, "dns_hijack", 4096, NULL, 5, NULL);
}

// ============================ button provisioning trigger ============================
// Count debounced BOOT (GPIO0) presses during a `window_ms` window after
// power-on. A press = a released→pressed transition that stays stable for the
// debounce time. Returns the number of presses seen.
static int button_press_count(int window_ms) {
    gpio_config_t btn = {
        .pin_bit_mask = 1ULL << SETUP_BUTTON_GPIO,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&btn);
    ESP_LOGI(TAG, "[Setup] tap BOOT >%d times within %d s to (re)provision...",
             PROVISION_PRESS_COUNT, window_ms / 1000);

    const int step = 20;          // sample period, ms
    const int debounce = 40;      // a level must hold this long to count, ms
    int count = 0;
    int pressed = 0;              // debounced state: 1 = pressed (pin low)
    int last_raw = 0;            // last raw reading (1 = pressed)
    int stable = 0;

    for (int t = 0; t < window_ms; t += step) {
        int raw = (gpio_get_level(SETUP_BUTTON_GPIO) == 0) ? 1 : 0;  // pull-up: low = pressed
        if (raw == last_raw) {
            stable += step;
            if (stable >= debounce && raw != pressed) {
                pressed = raw;
                if (pressed) {                       // released -> pressed edge
                    count++;
                    ESP_LOGI(TAG, "[Setup] BOOT press %d", count);
                }
            }
        } else {
            last_raw = raw;
            stable = 0;
        }
        vTaskDelay(pdMS_TO_TICKS(step));
    }
    return count;
}

// ============================ app_main ============================
void app_main(void) {
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    load_last_order_from_nvs();

    // Relay pins + force the relay OFF on every boot. The relay is bistable, so
    // it powers up in whatever state it was left in — we always latch it closed
    // at startup (DIR=IO2 low, then an off pulse) so a reboot never leaves the
    // door open.
    relay_pins_init();
    relay_off();
    ESP_LOGI(TAG, "[Boot] relay forced OFF (DIR IO%d low)", RELAY_DIR_GPIO);

    // External hardware watchdog — start early and keep it alive in all modes
    // (provisioning included), or the WD reboots the board mid-operation.
    ext_wd_start();

    // Network status LED — background diagnostics, runs through every mode.
    xTaskCreate(status_led_task, "status_led", 2048, NULL, 4, NULL);

    // Networking stack.
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &wifi_event_handler, NULL, NULL));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &wifi_event_handler, NULL, NULL));
    s_wifi_eg = xEventGroupCreate();

    bool have_cfg = cfg_load();

    // 4 s window after power-on: more than PROVISION_PRESS_COUNT BOOT(GPIO0)
    // taps forces (re)provisioning, even on an already-configured device. The
    // portal then writes a fresh config (overwriting any existing one).
    int presses = button_press_count(PROVISION_WINDOW_MS);
    if (presses > PROVISION_PRESS_COUNT) {
        ESP_LOGW(TAG, "[Setup] %d BOOT presses — clearing config, entering provisioning", presses);
        cfg_erase();
        have_cfg = false;
    }

    if (!have_cfg) {
        start_setup_portal();          // stays here serving the portal
        ESP_LOGI(TAG, "Provisioning mode — waiting for setup");
        return;
    }

    // Normal operation.
    wifi_start_normal();
    mqtt_start();
    ESP_LOGI(TAG, "Relay Mart System Started (DIR IO%d/PULSE IO%d, open %ds), machid=%s",
             RELAY_DIR_GPIO, RELAY_PULSE_GPIO, g_open_seconds, g_machid);
}
