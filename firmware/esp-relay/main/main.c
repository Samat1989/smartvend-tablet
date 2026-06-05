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

static const char *TAG = "relay_mart";

// --- CONFIGURATION ---
// WiFi + machine identity are no longer hardcoded — they are provisioned over a
// SoftAP setup portal and stored in NVS. Only the cloud endpoints stay fixed.
#define MQTT_HOST      "mqtt.smartvend.kz"
#define MQTT_PORT      14003

#define SUPABASE_BASE      "https://cgvfhtvdtdjsyluhlcbq.supabase.co/functions/v1"
#define SUPABASE_ANON_KEY  "sb_publishable_84RnaNCrFwxKicybxLGL2w_StEYpHnD"

#define LOCK_GPIO         GPIO_NUM_4
#define SETUP_BUTTON_GPIO GPIO_NUM_0    // BOOT button: hold at power-on to re-provision
#define SETUP_HOLD_MS     3000
#define UNLOCK_TIME_MS    3000

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

static void trigger_lock(void *pvParameters) {
    is_lock_active = true;
    ESP_LOGI(TAG, "🔓 TRIGGERING LOCK (GPIO %d) for %d ms", LOCK_GPIO, UNLOCK_TIME_MS);
    gpio_set_level(LOCK_GPIO, 1);
    vTaskDelay(pdMS_TO_TICKS(UNLOCK_TIME_MS));
    gpio_set_level(LOCK_GPIO, 0);
    ESP_LOGI(TAG, "🔒 LOCK CLOSED");
    is_lock_active = false;
    vTaskDelete(NULL);
}

// ============================ MQTT ============================
static void mqtt_event_handler(void *handler_args, esp_event_base_t base, int32_t event_id, void *event_data) {
    esp_mqtt_event_handle_t event = event_data;
    esp_mqtt_client_handle_t client = event->client;
    int msg_id;

    switch ((esp_mqtt_event_id_t)event_id) {
        case MQTT_EVENT_CONNECTED:
            ESP_LOGI(TAG, "MQTT Connected");
            msg_id = esp_mqtt_client_subscribe(client, g_mqtt_topic, 0);
            ESP_LOGI(TAG, "Subscribed to %s, msg_id=%d", g_mqtt_topic, msg_id);
            break;
        case MQTT_EVENT_DISCONNECTED:
            ESP_LOGI(TAG, "MQTT Disconnected");
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
        esp_wifi_connect();
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
        }
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t* e = (ip_event_got_ip_t*) data;
        ESP_LOGI(TAG, "Got IP: " IPSTR, IP2STR(&e->ip_info.ip));
        s_sta_retries = 0;
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

// ============================ Setup portal (SoftAP + HTTP) ============================
static const char SETUP_PAGE[] =
    "<!DOCTYPE html><html><head><meta name=viewport content='width=device-width,initial-scale=1'>"
    "<title>SmartVend Setup</title><style>"
    "body{font-family:sans-serif;background:#1f2937;color:#fff;margin:0;padding:24px}"
    "h2{margin-top:0}label{display:block;margin:14px 0 4px;font-size:14px;opacity:.8}"
    "input{width:100%;box-sizing:border-box;padding:12px;border-radius:8px;border:none;font-size:16px}"
    "button{width:100%;margin-top:20px;padding:14px;border:none;border-radius:8px;background:#F14635;color:#fff;font-size:16px;font-weight:bold}"
    "</style></head><body><h2>SmartVend — настройка</h2>"
    "<form method=POST action=/save>"
    "<label>WiFi сеть (SSID)</label><input name=ssid required>"
    "<label>WiFi пароль</label><input name=pass type=password>"
    "<label>Номер аппарата (Machine ID)</label><input name=machid required inputmode=numeric>"
    "<button type=submit>Сохранить и подключить</button></form></body></html>";

static esp_err_t root_get_handler(httpd_req_t *req) {
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    httpd_resp_send(req, SETUP_PAGE, HTTPD_RESP_USE_STRLEN);
    return ESP_OK;
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

static void reboot_task(void *pv) {
    vTaskDelay(pdMS_TO_TICKS(2000));
    esp_restart();
}

static esp_err_t save_post_handler(httpd_req_t *req) {
    char body[256];
    int len = httpd_req_recv(req, body, sizeof(body) - 1);
    if (len <= 0) return ESP_FAIL;
    body[len] = 0;

    char ssid[64] = {0}, pass[64] = {0}, machid[16] = {0};
    form_field(body, "ssid", ssid, sizeof(ssid));
    form_field(body, "pass", pass, sizeof(pass));
    form_field(body, "machid", machid, sizeof(machid));
    if (ssid[0] == 0 || machid[0] == 0) {
        return send_msg(req, "Ошибка", "Заполните SSID и номер аппарата. <a href=/>Назад</a>");
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

    // 3) Commit WiFi + machid; reboot into normal mode.
    cfg_set("ssid", ssid);
    cfg_set("pass", pass);
    cfg_set("machid", machid);
    ESP_LOGI(TAG, "[Setup] provisioned OK, rebooting");
    send_msg(req, "Готово!", "Аппарат настроен и перезагружается.");
    xTaskCreate(reboot_task, "reboot", 2048, NULL, 5, NULL);
    return ESP_OK;
}

static void start_setup_portal(void) {
    g_provisioning = true;

    // SoftAP (open) + STA (so we can validate WiFi and reach Supabase).
    esp_netif_create_default_wifi_ap();
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_APSTA));

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
    }
}

// ============================ button ============================
static bool setup_button_held(void) {
    gpio_config_t btn = {
        .pin_bit_mask = 1ULL << SETUP_BUTTON_GPIO,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&btn);
    // BOOT button reads 0 when pressed. Require it held for SETUP_HOLD_MS.
    for (int waited = 0; waited < SETUP_HOLD_MS; waited += 100) {
        if (gpio_get_level(SETUP_BUTTON_GPIO) != 0) return false;
        vTaskDelay(pdMS_TO_TICKS(100));
    }
    return true;
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

    // Lock GPIO.
    gpio_config_t lock_cfg = {
        .pin_bit_mask = 1ULL << LOCK_GPIO,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&lock_cfg));
    gpio_set_level(LOCK_GPIO, 0);

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
    bool force_setup = setup_button_held();
    if (force_setup) {
        ESP_LOGW(TAG, "[Setup] BOOT held — clearing config and entering provisioning");
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
    ESP_LOGI(TAG, "Relay Mart System Started (GPIO%d), machid=%s", LOCK_GPIO, g_machid);
}
