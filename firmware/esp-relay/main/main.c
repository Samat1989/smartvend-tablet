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

// Optional GSM (LTE) uplink via an A7670E modem over PPP (esp_modem).
#include "esp_modem_api.h"
#include "esp_netif_ppp.h"

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
#define FW_VERSION_NAME    "1.0.5"
#define FW_VERSION_CODE    10005
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

// --- GSM modem (A7670E/SIM7600 via esp_modem PPP) — alt uplink to WiFi.
// Pins/power taken from the relay board's Arduino/TinyGSM firmware (config.h):
//   ESP TX(GPIO25) -> modem RXD, ESP RX(GPIO26) <- modem TXD, 115200 8N1.
//   The modem is NOT auto-powered — its VCC/enable is gated by CELLULAR_POWER
//   (GPIO5): drive it LOW ~1 s, then HIGH and keep HIGH to switch the modem on.
// The DCE is SIM7600 (drives the A76xx AT command set).
#define GSM_UART_TX_GPIO   25
#define GSM_UART_RX_GPIO   26
#define GSM_UART_BAUD      115200
#define GSM_POWER_GPIO     5        // CELLULAR_POWER enable line (active HIGH)
#define GSM_BOOT_DELAY_MS  10000    // modem cold-boot time after power-on
#define GSM_DEFAULT_APN    "internet"
// ---------------------

// Provisioned config (loaded from NVS, or filled in by the setup portal).
static char g_netmode[8]      = "wifi"; // uplink: "wifi" | "gsm"
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
// s_wifi_eg's CONNECTED bit means "an uplink has an IP" — it is set by BOTH the
// WiFi got-IP handler and the PPP (GSM) got-IP handler, so the rest of the flow
// (MQTT start, provisioning validation) is transport-agnostic.
static EventGroupHandle_t s_wifi_eg;
#define WIFI_CONNECTED_BIT BIT0
#define WIFI_FAIL_BIT      BIT1
#define GSM_LOST_BIT       BIT2   // PPP link dropped — [gsm_link_task] restarts the modem
static int s_sta_retries = 0;

// GSM modem (esp_modem PPP) handles.
static esp_modem_dce_t *s_dce = NULL;
static esp_netif_t     *s_ppp_netif = NULL;

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

// Returns true when a complete config is present (wifi + machine identity).
static bool cfg_load(void) {
    char osbuf[8];
    if (cfg_get("opensec", osbuf, sizeof(osbuf)) == ESP_OK) {
        int v = atoi(osbuf);
        if (v >= 1 && v <= 600) g_open_seconds = v;
    }
    cfg_get("netmode", g_netmode, sizeof(g_netmode));
    if (g_netmode[0] == 0) strcpy(g_netmode, "wifi");
    bool gsm = (strcmp(g_netmode, "gsm") == 0);
    cfg_get("ssid", g_wifi_ssid, sizeof(g_wifi_ssid));
    cfg_get("pass", g_wifi_pass, sizeof(g_wifi_pass));   // empty pass allowed
    if (cfg_get("machid", g_machid, sizeof(g_machid)) != ESP_OK) return false;
    if (cfg_get("uuid", g_mqtt_uuid, sizeof(g_mqtt_uuid)) != ESP_OK) return false;
    if (cfg_get("secret", g_mqtt_secret, sizeof(g_mqtt_secret)) != ESP_OK) return false;
    if (g_mqtt_uuid[0] == 0 || g_mqtt_secret[0] == 0) return false;
    if (!gsm && g_wifi_ssid[0] == 0) return false;   // WiFi mode needs an SSID
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

// Confirm the order with Supabase FIRST, then open the relay ONLY on HTTP 200.
// [orderid] is a heap copy this task owns and frees. Runs off the MQTT task so
// the confirm + door timing don't block MQTT. On failure (no 200 after retries)
// the relay stays closed and the order is NOT recorded, so an MQTT redelivery
// can retry it. [is_lock_active] is set by the caller and cleared here.
static void handle_order_task(void *pvParameters) {
    char* orderid = (char*)pvParameters;
    bool confirmed = false;
    for (int attempt = 1; attempt <= 3; attempt++) {
        if (post_order_once(orderid) == ESP_OK) { confirmed = true; break; }
        ESP_LOGW(TAG, "complete-order attempt %d failed (no 200), retrying...", attempt);
        vTaskDelay(pdMS_TO_TICKS(3000));
    }

    if (confirmed) {
        // Server confirmed the sale (HTTP 200) — remember the order (idempotency)
        // and open the door for the provisioned hold time.
        strncpy(last_order_id, orderid, sizeof(last_order_id) - 1);
        save_last_order_to_nvs(last_order_id);
        ESP_LOGI(TAG, "🔓 RELAY ON (order %s confirmed 200, DIR IO%d/PULSE IO%d) for %d s",
                 orderid, RELAY_DIR_GPIO, RELAY_PULSE_GPIO, g_open_seconds);
        relay_on();
        vTaskDelay(pdMS_TO_TICKS((uint32_t)g_open_seconds * 1000));
        relay_off();
        ESP_LOGI(TAG, "🔒 RELAY OFF");
    } else {
        ESP_LOGE(TAG, "❌ order %s NOT confirmed by server — relay stays CLOSED", orderid);
    }

    is_lock_active = false;
    free(orderid);
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
                                ESP_LOGI(TAG, "✅ New payment MQTT for order %s — confirming with server",
                                         orderid->valuestring);
                                // Claim the slot before the task runs (the MQTT task
                                // is serial, so this is atomic vs the is_lock_active
                                // check above). The order is confirmed with Supabase
                                // and the relay opens ONLY on HTTP 200 — see
                                // handle_order_task; last_order is committed there,
                                // only after a confirmed open, so an unconfirmed
                                // order can be retried on MQTT redelivery.
                                is_lock_active = true;
                                char* id_copy = strdup(orderid->valuestring);
                                if (!id_copy ||
                                    xTaskCreate(handle_order_task, "order_task", 8192,
                                                (void*)id_copy, 5, NULL) != pdPASS) {
                                    ESP_LOGE(TAG, "failed to start order task");
                                    if (id_copy) free(id_copy);
                                    is_lock_active = false;
                                }
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

// ============================ GSM modem (PPP uplink) ============================
static void ppp_ip_event_handler(void *arg, esp_event_base_t base, int32_t id, void *data) {
    if (id == IP_EVENT_PPP_GOT_IP) {
        ip_event_got_ip_t *e = (ip_event_got_ip_t *) data;
        ESP_LOGI(TAG, "[GSM] PPP got IP: " IPSTR, IP2STR(&e->ip_info.ip));
        g_has_ip = true;
        if (s_wifi_eg) xEventGroupSetBits(s_wifi_eg, WIFI_CONNECTED_BIT);
    } else if (id == IP_EVENT_PPP_LOST_IP) {
        ESP_LOGW(TAG, "[GSM] PPP lost IP");
        g_has_ip = false;
        g_mqtt_up = false;
        if (s_wifi_eg) xEventGroupSetBits(s_wifi_eg, GSM_LOST_BIT);
    }
}

// Bring up the A7670E over PPP. Blocking through modem sync (~10 s incl. the
// boot delay); the PPP IP arrives asynchronously and is signalled via the
// shared [s_wifi_eg] CONNECTED bit. Returns true once the modem is in data mode.
static bool gsm_start(void) {
    ESP_LOGI(TAG, "[GSM] start: APN=%s UART tx=%d rx=%d @%d",
             GSM_DEFAULT_APN, GSM_UART_TX_GPIO, GSM_UART_RX_GPIO, GSM_UART_BAUD);

    // Power the modem on (the relay board gates modem VCC via GPIO5): drive it
    // LOW, wait, then HIGH and keep it HIGH — matches the Arduino firmware's
    // CELLULAR_POWER sequence. Without this the modem never boots -> AT timeout.
    gpio_config_t pw = { .pin_bit_mask = 1ULL << GSM_POWER_GPIO,
                         .mode = GPIO_MODE_OUTPUT };
    gpio_config(&pw);
    gpio_set_level(GSM_POWER_GPIO, 0);
    vTaskDelay(pdMS_TO_TICKS(1000));
    gpio_set_level(GSM_POWER_GPIO, 1);
    ESP_LOGI(TAG, "[GSM] modem power ON (GPIO%d HIGH), booting %d ms",
             GSM_POWER_GPIO, GSM_BOOT_DELAY_MS);
    vTaskDelay(pdMS_TO_TICKS(GSM_BOOT_DELAY_MS));

    if (!s_ppp_netif) {
        esp_netif_config_t ppp_cfg = ESP_NETIF_DEFAULT_PPP();
        s_ppp_netif = esp_netif_new(&ppp_cfg);
        if (!s_ppp_netif) { ESP_LOGE(TAG, "[GSM] esp_netif_new failed"); return false; }
        esp_event_handler_instance_register(IP_EVENT, IP_EVENT_PPP_GOT_IP,
                                            &ppp_ip_event_handler, NULL, NULL);
        esp_event_handler_instance_register(IP_EVENT, IP_EVENT_PPP_LOST_IP,
                                            &ppp_ip_event_handler, NULL, NULL);
    }

    // The A7670E stays powered across an ESP-only reset (no PWRKEY here), so it
    // may still be in PPP/DATA mode from a prior session and won't answer "AT".
    // Recreating the DCE each round (like the cloudcore firmware's retry loop)
    // resets the DTE state and recovers; the extra tries also cover a slow first
    // sync right after modem boot.
    for (int attempt = 1; attempt <= 5; attempt++) {
        esp_modem_dte_config_t dte = ESP_MODEM_DTE_DEFAULT_CONFIG();
        dte.uart_config.tx_io_num    = GSM_UART_TX_GPIO;
        dte.uart_config.rx_io_num    = GSM_UART_RX_GPIO;
        dte.uart_config.rts_io_num   = -1;
        dte.uart_config.cts_io_num   = -1;
        dte.uart_config.flow_control = ESP_MODEM_FLOW_CONTROL_NONE;
        dte.uart_config.baud_rate    = GSM_UART_BAUD;
        // A7670E is SIMCom; the generic SIM7600 DCE drives the A76xx AT set.
        esp_modem_dce_config_t dce = ESP_MODEM_DCE_DEFAULT_CONFIG(GSM_DEFAULT_APN);

        s_dce = esp_modem_new_dev(ESP_MODEM_DCE_SIM7600, &dte, &dce, s_ppp_netif);
        if (!s_dce) {
            ESP_LOGE(TAG, "[GSM] esp_modem_new_dev failed (attempt %d)", attempt);
            vTaskDelay(pdMS_TO_TICKS(2000));
            continue;
        }

        esp_err_t err = esp_modem_sync(s_dce);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "[GSM] AT sync #%d failed (%s); +++ escape and retry",
                     attempt, esp_err_to_name(err));
            esp_modem_set_mode(s_dce, ESP_MODEM_MODE_COMMAND);
            vTaskDelay(pdMS_TO_TICKS(2000));
            err = esp_modem_sync(s_dce);
        }
        if (err == ESP_OK) {
            esp_modem_at(s_dce, "AT+CNMP=2", NULL, 1000);   // network mode: auto
            err = esp_modem_set_mode(s_dce, ESP_MODEM_MODE_DATA);
            if (err == ESP_OK) {
                ESP_LOGI(TAG, "[GSM] PPP data mode; waiting for IP");
                return true;
            }
            ESP_LOGE(TAG, "[GSM] enter DATA mode failed: %s", esp_err_to_name(err));
        }
        // Failed this round — tear the DCE down and retry with a fresh one.
        esp_modem_destroy(s_dce);
        s_dce = NULL;
        ESP_LOGW(TAG, "[GSM] attempt %d failed, retrying in 3s", attempt);
        vTaskDelay(pdMS_TO_TICKS(3000));
    }
    ESP_LOGE(TAG, "[GSM] modem not responding — check UART wiring/power/SIM");
    return false;
}

// Wait up to [timeout_ms] for any uplink (WiFi or GSM) to acquire an IP.
static bool net_wait_ip(int timeout_ms) {
    if (!s_wifi_eg) return false;
    EventBits_t b = xEventGroupWaitBits(s_wifi_eg, WIFI_CONNECTED_BIT,
                                        pdFALSE, pdFALSE, pdMS_TO_TICKS(timeout_ms));
    return (b & WIFI_CONNECTED_BIT) != 0;
}

// Owns the GSM link in normal operation: brings PPP up and, whenever it drops
// (SIM pulled, signal lost, network reset), restarts the modem and re-dials.
// Without this a dropped PPP session never recovers — MQTT just spins forever on
// getaddrinfo. Re-powering the modem on each cycle also lets a re-inserted SIM
// be re-read.
static void gsm_link_task(void *pv) {
    while (true) {
        xEventGroupClearBits(s_wifi_eg, WIFI_CONNECTED_BIT | GSM_LOST_BIT);
        if (!gsm_start()) {
            ESP_LOGW(TAG, "[GSM] bring-up failed — retry in 10 s");
            if (s_dce) { esp_modem_destroy(s_dce); s_dce = NULL; }
            vTaskDelay(pdMS_TO_TICKS(10000));
            continue;
        }
        // Entered data mode; wait (bounded) for the PPP IP. If it never comes
        // (no SIM / no network), restart the modem rather than sit forever.
        if (!net_wait_ip(60000)) {
            ESP_LOGW(TAG, "[GSM] no IP after data mode — restarting modem");
            if (s_dce) { esp_modem_destroy(s_dce); s_dce = NULL; }
            vTaskDelay(pdMS_TO_TICKS(3000));
            continue;
        }
        ESP_LOGI(TAG, "[GSM] link up");
        // Block until PPP reports the link is gone, then cycle the modem.
        xEventGroupWaitBits(s_wifi_eg, GSM_LOST_BIT, pdTRUE, pdFALSE, portMAX_DELAY);
        ESP_LOGW(TAG, "[GSM] PPP down — restarting modem");
        g_has_ip = false;
        g_mqtt_up = false;
        if (s_dce) { esp_modem_destroy(s_dce); s_dce = NULL; }
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
}

// Portal GSM path: bring the modem up, fetch the machine identity over PPP, and
// on success commit the config + reboot. Runs in the background so the HTTP
// handler returns a "please wait" page instead of blocking for ~30-45 s. Set by
// [save_post_handler] before the task is spawned.
static char g_pend_machid[16] = {0};
static int  g_pend_opensec    = DEFAULT_OPEN_SECONDS;

static void gsm_provision_task(void *pv) {
    xEventGroupClearBits(s_wifi_eg, WIFI_CONNECTED_BIT);
    // Bring the modem up with the radio quiet (like the cloudcore firmware): the
    // wait-page is already delivered, so we can drop the SoftAP now. This also
    // rules out any Wi-Fi/modem contention during PPP negotiation.
    esp_wifi_stop();
    if (!gsm_start() || !net_wait_ip(60000)) {
        ESP_LOGE(TAG, "[Setup/GSM] modem/IP failed — rebooting to portal");
        vTaskDelay(pdMS_TO_TICKS(1500));
        esp_restart();
    }
    esp_netif_set_default_netif(s_ppp_netif);
    if (!provision_fetch_and_store(g_pend_machid)) {
        ESP_LOGE(TAG, "[Setup/GSM] machid lookup failed — rebooting to portal");
        vTaskDelay(pdMS_TO_TICKS(1500));
        esp_restart();
    }
    char osstr[8];
    snprintf(osstr, sizeof(osstr), "%d", g_pend_opensec);
    cfg_set("netmode", "gsm");
    cfg_set("machid", g_pend_machid);
    cfg_set("opensec", osstr);
    ESP_LOGI(TAG, "[Setup/GSM] provisioned OK, rebooting");
    vTaskDelay(pdMS_TO_TICKS(800));
    esp_restart();
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

// One-shot GitHub GET into a heap accumulator. Returns the malloc'd, null-
// terminated body (caller frees) or NULL. *out_status gets the HTTP status.
static char *ota_http_get(const char *url, int cap, int *out_status) {
    char *body = malloc(cap);
    if (!body) { ESP_LOGE(TAG, "OTA: no heap (%d B)", cap); return NULL; }
    http_accum_t acc = { .buf = body, .len = 0, .cap = cap };
    esp_http_client_config_t cfg = {
        .url = url,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .event_handler = ota_http_accum,
        .user_data = &acc,
        .timeout_ms = 15000,
    };
    esp_http_client_handle_t cli = esp_http_client_init(&cfg);
    esp_http_client_set_header(cli, "Accept", "application/vnd.github+json");
    esp_http_client_set_header(cli, "User-Agent", "esp-relay-ota");
    esp_err_t err = esp_http_client_perform(cli);
    *out_status = esp_http_client_get_status_code(cli);
    esp_http_client_cleanup(cli);
    if (err != ESP_OK) { ESP_LOGW(TAG, "OTA GET failed: %s", esp_err_to_name(err)); free(body); return NULL; }
    acc.buf[acc.len < cap ? acc.len : cap - 1] = 0;
    return body;
}

// Find the newest "relay-v*" release whose code beats ours and return its
// OTA_ASSET_NAME download URL. Two steps because the releases repo is SHARED
// with the tablet app: the full /releases JSON (many verbose v1.1.x entries)
// overflowed our buffer, so the relay-v* entries never parsed. Instead we pull
// the name-only /tags list (tiny) to pick the winning tag, then fetch just that
// one release for the asset URL — both fit in small buffers regardless of how
// many tablet releases exist.
static bool ota_find_update(char *url_out, size_t url_sz) {
    // --- 1) newest relay-v* tag from the lightweight /tags list ---
    char api[160];
    snprintf(api, sizeof(api),
             "https://api.github.com/repos/%s/tags?per_page=100", OTA_OWNER_REPO);
    int status = 0;
    char *body = ota_http_get(api, 32768, &status);
    if (!body) return false;

    char best_tag[48] = {0};
    long best = FW_VERSION_CODE;
    if (status == 200) {
        cJSON *root = cJSON_Parse(body);
        if (root && cJSON_IsArray(root)) {
            cJSON *t;
            cJSON_ArrayForEach(t, root) {
                cJSON *nm = cJSON_GetObjectItem(t, "name");
                if (!cJSON_IsString(nm)) continue;
                long code = ota_tag_code(nm->valuestring);   // -1 if not relay-v*
                if (code > best) {
                    best = code;
                    strncpy(best_tag, nm->valuestring, sizeof(best_tag) - 1);
                    best_tag[sizeof(best_tag) - 1] = 0;
                }
            }
        } else {
            ESP_LOGW(TAG, "OTA: failed to parse tag list");
        }
        if (root) cJSON_Delete(root);
    } else {
        ESP_LOGW(TAG, "OTA tags fetch status=%d", status);
    }
    free(body);

    if (best_tag[0] == 0) return false;   // nothing newer than us
    ESP_LOGI(TAG, "OTA: newest relay tag %s (code %ld) > current %d",
             best_tag, best, FW_VERSION_CODE);

    // --- 2) fetch that release by tag for the .bin asset URL ---
    // URL-encode '+' in the tag (relay-vX.Y.Z+CODE) as %2B for the path.
    char enc[72];
    int ei = 0;
    for (int i = 0; best_tag[i] && ei < (int)sizeof(enc) - 4; i++) {
        if (best_tag[i] == '+') { enc[ei++] = '%'; enc[ei++] = '2'; enc[ei++] = 'B'; }
        else enc[ei++] = best_tag[i];
    }
    enc[ei] = 0;

    char rapi[220];
    snprintf(rapi, sizeof(rapi),
             "https://api.github.com/repos/%s/releases/tags/%s", OTA_OWNER_REPO, enc);
    int rstatus = 0;
    char *rbody = ota_http_get(rapi, 12288, &rstatus);
    if (!rbody) return false;

    bool found = false;
    if (rstatus == 200) {
        cJSON *rel = cJSON_Parse(rbody);
        if (rel) {
            cJSON *assets = cJSON_GetObjectItem(rel, "assets");
            cJSON *as;
            cJSON_ArrayForEach(as, assets) {
                cJSON *nm = cJSON_GetObjectItem(as, "name");
                cJSON *u  = cJSON_GetObjectItem(as, "browser_download_url");
                if (cJSON_IsString(nm) && cJSON_IsString(u) &&
                    strcmp(nm->valuestring, OTA_ASSET_NAME) == 0) {
                    strncpy(url_out, u->valuestring, url_sz - 1);
                    url_out[url_sz - 1] = 0;
                    found = true;
                    ESP_LOGI(TAG, "OTA: asset %s -> %s", OTA_ASSET_NAME, url_out);
                    break;
                }
            }
            cJSON_Delete(rel);
        } else {
            ESP_LOGW(TAG, "OTA: failed to parse release for %s", best_tag);
        }
    } else {
        ESP_LOGW(TAG, "OTA release-by-tag status=%d", rstatus);
    }
    free(rbody);
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
        // GitHub 302-redirects to a very long objects.githubusercontent.com URL;
        // the default 512 B TX buffer can't hold that request line ("Out of
        // buffer"). Enlarge RX/TX so the redirected GET fits.
        .buffer_size = 2048,
        .buffer_size_tx = 4096,
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

// Startup OTA check: wait (bounded) for WiFi, then check once. Runs in the
// background so MQTT/relay stay responsive; reboots into new firmware if any.
static void ota_boot_task(void *pv) {
    for (int i = 0; i < 60 && !g_has_ip; i++) vTaskDelay(pdMS_TO_TICKS(1000));
    if (g_has_ip) ota_check_and_update();   // reboots on success; returns otherwise
    vTaskDelete(NULL);
}

// ============================ Setup portal (SoftAP + HTTP) ============================
// The page is sent in three chunks: PAGE_HEAD (styles + the network list opens),
// then one row per scanned network (radio + signal bars), then PAGE_TAIL_*
// (password / machine id / relay time / submit).
static const char PAGE_HEAD[] =
    "<!DOCTYPE html><html><head><meta name=viewport content='width=device-width,initial-scale=1'>"
    "<title>SmartVend Setup</title><style>"
    "*{box-sizing:border-box}"
    "body{font-family:system-ui,-apple-system,sans-serif;background:#0f172a;color:#e2e8f0;margin:0 auto;padding:22px;max-width:460px}"
    "h2{font-size:19px;font-weight:600;margin:0 0 18px}"
    ".lbl{display:block;margin:16px 0 6px;font-size:13px;color:#94a3b8}"
    "input{width:100%;padding:12px;border-radius:10px;border:1px solid #334155;background:#1e293b;color:#fff;font-size:16px}"
    "#nets{display:flex;flex-direction:column;gap:8px}"
    ".net{display:flex;align-items:center;gap:12px;padding:12px 14px;border:1px solid #334155;border-radius:10px;background:#1e293b;cursor:pointer}"
    ".net input{display:none}"
    ".net:has(:checked){border-color:#F14635;background:#3a2020}"
    ".net .nm{flex:1;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;font-size:15px}"
    ".bars{display:flex;align-items:flex-end;gap:2px;height:16px}"
    ".bars i{width:4px;border-radius:1px;background:#475569}"
    ".bars i.on{background:#22c55e}"
    ".bars i:nth-child(1){height:6px}.bars i:nth-child(2){height:10px}"
    ".bars i:nth-child(3){height:13px}.bars i:nth-child(4){height:16px}"
    "button{width:100%;margin-top:22px;padding:14px;border:none;border-radius:10px;background:#F14635;color:#fff;font-size:16px;font-weight:600}"
    "</style></head><body><h2>SmartVend — настройка</h2>"
    "<form method=POST action=/save>"
    "<span class=lbl>Способ связи</span><div id=modes>"
    "<label class=net><input type=radio name=netmode value=wifi checked onclick=selMode()><span class=nm>WiFi</span></label>"
    "<label class=net><input type=radio name=netmode value=gsm onclick=selMode()><span class=nm>GSM (SIM / LTE)</span></label>"
    "</div>"
    "<div id=wifiblk>"
    "<span class=lbl>WiFi сеть</span><div id=nets>";
static const char PAGE_TAIL_A[] =
    "</div>"
    "<span class=lbl>WiFi пароль</span><input name=pass type=password>"
    "</div>"  // /wifiblk
    "<div id=gsmblk style=display:none>"
    "<span class=lbl>GSM (LTE): вставьте SIM с интернетом — APN определяется автоматически.</span>"
    "</div>"
    "<span class=lbl>Номер аппарата (Machine ID)</span>"
    "<input name=machid required inputmode=numeric value=\"";
// machine id (prefilled from the saved config) goes here, then:
static const char PAGE_TAIL_MID[] =
    "\">"
    "<span class=lbl>Время включения реле, сек</span>"
    "<input name=opensec type=number min=1 max=600 inputmode=numeric value='";
static const char PAGE_TAIL_B[] =
    "'><button type=submit>Сохранить и подключить</button></form>"
    "<script>function selMode(){var g=document.querySelector('input[name=netmode]:checked').value=='gsm';"
    "document.getElementById('wifiblk').style.display=g?'none':'';"
    "document.getElementById('gsmblk').style.display=g?'':'none';"
    "document.querySelectorAll('#nets input').forEach(function(x){x.required=!g});}</script>"
    "</body></html>";

static esp_err_t root_get_handler(httpd_req_t *req) {
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    httpd_resp_sendstr_chunk(req, PAGE_HEAD);

    // Scan nearby networks (returned strongest-first) and render each as a
    // selectable row with 4 signal bars filled by RSSI.
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
                int r = recs[i].rssi;
                int lvl = r >= -55 ? 4 : r >= -65 ? 3 : r >= -72 ? 2 : 1;
                char row[320];
                snprintf(row, sizeof(row),
                    "<label class=net><input type=radio name=ssid value=\"%s\" required>"
                    "<span class=nm>%s</span><span class=bars>"
                    "<i class=\"%s\"></i><i class=\"%s\"></i><i class=\"%s\"></i><i class=\"%s\"></i>"
                    "</span></label>",
                    (char*)recs[i].ssid, (char*)recs[i].ssid,
                    lvl >= 1 ? "on" : "", lvl >= 2 ? "on" : "",
                    lvl >= 3 ? "on" : "", lvl >= 4 ? "on" : "");
                httpd_resp_sendstr_chunk(req, row);
            }
        }
    }

    httpd_resp_sendstr_chunk(req, PAGE_TAIL_A);
    httpd_resp_sendstr_chunk(req, g_machid);   // prefill the saved machine id
    httpd_resp_sendstr_chunk(req, PAGE_TAIL_MID);
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

// After provisioning: let the reply reach the phone, then reboot into normal
// mode. The firmware update check runs there (ota_boot_task), not here.
static void provision_finish_task(void *pv) {
    vTaskDelay(pdMS_TO_TICKS(2000));
    esp_restart();
}

static esp_err_t save_post_handler(httpd_req_t *req) {
    char body[512];
    int len = httpd_req_recv(req, body, sizeof(body) - 1);
    if (len <= 0) return ESP_FAIL;
    body[len] = 0;

    char ssid[64] = {0}, pass[64] = {0}, machid[16] = {0}, opensec[8] = {0};
    char netmode[8] = {0};
    form_field(body, "ssid", ssid, sizeof(ssid));
    form_field(body, "pass", pass, sizeof(pass));
    form_field(body, "machid", machid, sizeof(machid));
    form_field(body, "opensec", opensec, sizeof(opensec));
    form_field(body, "netmode", netmode, sizeof(netmode));
    if (netmode[0] == 0) strcpy(netmode, "wifi");
    bool gsm = (strcmp(netmode, "gsm") == 0);

    if (machid[0] == 0) {
        return send_msg(req, "Ошибка", "Впишите номер аппарата. <a href=/>Назад</a>");
    }
    int osv = atoi(opensec);
    if (osv < 1 || osv > 600) osv = DEFAULT_OPEN_SECONDS;
    g_open_seconds = osv;

    // --- GSM: modem bring-up is slow (~30-60 s), so validate + fetch identity in
    // the background and return a wait page instead of blocking the handler.
    if (gsm) {
        strncpy(g_pend_machid, machid, sizeof(g_pend_machid) - 1);
        g_pend_opensec = osv;
        ESP_LOGI(TAG, "[Setup] GSM machid=%s", machid);
        send_msg(req, "Подключение по GSM…",
                 "Модем поднимается, это ~30-60 секунд, затем аппарат перезагрузится сам. "
                 "Если через минуту снова откроется эта настройка — проверьте SIM / APN / антенну.");
        xTaskCreate(gsm_provision_task, "gsmprov", 8192, NULL, 5, NULL);
        return ESP_OK;
    }

    // --- WiFi: fast — validate synchronously, then commit + reboot.
    if (ssid[0] == 0) {
        return send_msg(req, "Ошибка", "Выберите сеть. <a href=/>Назад</a>");
    }
    ESP_LOGI(TAG, "[Setup] WiFi ssid=%s machid=%s", ssid, machid);
    if (!wifi_sta_try(ssid, pass)) {
        return send_msg(req, "WiFi не подключился", "Проверьте сеть и пароль. <a href=/>Назад</a>");
    }
    if (!provision_fetch_and_store(machid)) {
        return send_msg(req, "Аппарат не найден",
                        "Номер не найден в системе или нет связи. <a href=/>Назад</a>");
    }
    char osstr[8];
    snprintf(osstr, sizeof(osstr), "%d", osv);
    cfg_set("netmode", "wifi");
    cfg_set("ssid", ssid);
    cfg_set("pass", pass);
    cfg_set("machid", machid);
    cfg_set("opensec", osstr);
    ESP_LOGI(TAG, "[Setup] provisioned OK, rebooting");
    send_msg(req, "Готово!", "Аппарат настроен и перезагружается.");
    xTaskCreate(provision_finish_task, "provfin", 2048, NULL, 5, NULL);
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
    // taps forces (re)provisioning even on a configured device. We DON'T erase
    // the stored config — the globals (machid, opensec, netmode) stay loaded so
    // the portal can prefill them; the operator just re-submits, overwriting
    // only what they change.
    int presses = button_press_count(PROVISION_WINDOW_MS);
    bool force_portal = presses > PROVISION_PRESS_COUNT;
    if (force_portal) {
        ESP_LOGW(TAG, "[Setup] %d BOOT presses — entering provisioning (machid=%s prefilled)",
                 presses, g_machid);
    }

    if (!have_cfg || force_portal) {
        start_setup_portal();          // stays here serving the portal
        ESP_LOGI(TAG, "Provisioning mode — waiting for setup");
        return;
    }

    // Normal operation — bring up the configured uplink, then MQTT + OTA.
    if (strcmp(g_netmode, "gsm") == 0) {
        ESP_LOGI(TAG, "[Boot] uplink = GSM (APN=%s)", GSM_DEFAULT_APN);
        // Task owns the modem: initial dial + auto-restart on any PPP drop.
        xTaskCreate(gsm_link_task, "gsm_link", 6144, NULL, 5, NULL);
    } else {
        ESP_LOGI(TAG, "[Boot] uplink = WiFi (ssid=%s)", g_wifi_ssid);
        wifi_start_normal();
    }

    // Don't touch the network before we actually have an IP — otherwise MQTT and
    // the OTA check race the uplink and log getaddrinfo failures. Bounded wait
    // (GSM registration can take a while); if it's slow we proceed anyway since
    // MQTT keeps retrying on its own.
    if (net_wait_ip(90000)) {
        ESP_LOGI(TAG, "[Boot] uplink has IP — starting MQTT + OTA");
        vTaskDelay(pdMS_TO_TICKS(1500));   // let DHCP/PPP DNS settle before resolving
    } else {
        ESP_LOGW(TAG, "[Boot] no IP after 90 s — starting MQTT anyway (will retry)");
    }
    mqtt_start();

    // Check for a firmware update once at startup (background, non-blocking).
    xTaskCreate(ota_boot_task, "ota_boot", 10240, NULL, 4, NULL);

    ESP_LOGI(TAG, "Relay Mart System Started (DIR IO%d/PULSE IO%d, open %ds), machid=%s",
             RELAY_DIR_GPIO, RELAY_PULSE_GPIO, g_open_seconds, g_machid);
}
