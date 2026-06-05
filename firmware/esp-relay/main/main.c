#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "esp_wifi.h"
#include "esp_system.h"
#include "nvs_flash.h"
#include "esp_event.h"
#include "esp_netif.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "freertos/queue.h"

#include "lwip/sockets.h"
#include "lwip/dns.h"
#include "lwip/netdb.h"

#include "esp_log.h"
#include "mqtt_client.h"
#include "driver/gpio.h"
#include "cJSON.h"

#include "esp_http_client.h"
#include "esp_crt_bundle.h"

static const char *TAG = "relay_mart";

// --- CONFIGURATION ---
#define WIFI_SSID      "smartvendhq"
#define WIFI_PASS      "11223344"

#define MQTT_URI       "mqtt://mqtt.smartvend.kz:14003"
#define MQTT_USER      "9e9c8221-7132-4be5-bc89-7cfd884931c5"
#define MQTT_PASS      "70852079"
#define MQTT_TOPIC     "vending/9e9c8221-7132-4be5-bc89-7cfd884931c5/in"

#define SUPABASE_FUNC_URL "https://cgvfhtvdtdjsyluhlcbq.supabase.co/functions/v1/complete-order"
#define SUPABASE_ANON_KEY "sb_publishable_84RnaNCrFwxKicybxLGL2w_StEYpHnD"

#define LOCK_GPIO      GPIO_NUM_4
#define UNLOCK_TIME_MS 3000
// ---------------------

static bool is_lock_active = false;
static char last_order_id[64] = {0};

// --- NVS: сохранить ID последнего заказа в постоянную память ---
static void save_last_order_to_nvs(const char* orderid) {
    nvs_handle_t nvs;
    esp_err_t err = nvs_open("storage", NVS_READWRITE, &nvs);
    if (err == ESP_OK) {
        nvs_set_str(nvs, "last_order", orderid);
        nvs_commit(nvs);
        nvs_close(nvs);
        ESP_LOGI(TAG, "[NVS] Saved last_order_id: %s", orderid);
    } else {
        ESP_LOGE(TAG, "[NVS] Failed to open for write: %s", esp_err_to_name(err));
    }
}

// --- NVS: загрузить ID последнего заказа при старте ---
static void load_last_order_from_nvs(void) {
    nvs_handle_t nvs;
    esp_err_t err = nvs_open("storage", NVS_READONLY, &nvs);
    if (err == ESP_OK) {
        size_t required_size = sizeof(last_order_id);
        err = nvs_get_str(nvs, "last_order", last_order_id, &required_size);
        nvs_close(nvs);
        if (err == ESP_OK) {
            ESP_LOGI(TAG, "[NVS] Loaded last_order_id: %s", last_order_id);
        } else {
            ESP_LOGI(TAG, "[NVS] No previous order found, starting fresh.");
        }
    } else {
        ESP_LOGI(TAG, "[NVS] Storage not found, starting fresh.");
    }
}

// POST { orderid } to the complete-order edge function once. The function
// re-verifies the payment with SmartVend (a ~2-3s round trip) before replying,
// so the client timeout must be generous — too short and we'd give up before
// the response even though the server still finalizes the sale.
static esp_err_t post_order_once(const char* orderid) {
    char post_data[128];
    snprintf(post_data, sizeof(post_data), "{\"orderid\":\"%s\"}", orderid);

    esp_http_client_config_t config = {
        .url = SUPABASE_FUNC_URL,
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

    // Treat a real 2xx as done; otherwise let the caller retry.
    return (err == ESP_OK && status >= 200 && status < 300) ? ESP_OK : ESP_FAIL;
}

// Runs in its own task so the lock timing stays independent of the network:
// the door opens/closes on schedule regardless of how long the POST takes.
// Retries a few times so a transient Wi-Fi/TLS hiccup doesn't lose the sale.
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
    ESP_LOGI(TAG, "🔓 TRIGGERING LOCK (GPIO 4) for %d ms", UNLOCK_TIME_MS);
    gpio_set_level(LOCK_GPIO, 1);
    vTaskDelay(pdMS_TO_TICKS(UNLOCK_TIME_MS));
    gpio_set_level(LOCK_GPIO, 0);
    ESP_LOGI(TAG, "🔒 LOCK CLOSED");
    is_lock_active = false;
    vTaskDelete(NULL);
}

static void mqtt_event_handler(void *handler_args, esp_event_base_t base, int32_t event_id, void *event_data) {
    esp_mqtt_event_handle_t event = event_data;
    esp_mqtt_client_handle_t client = event->client;
    int msg_id;

    switch ((esp_mqtt_event_id_t)event_id) {
        case MQTT_EVENT_CONNECTED:
            ESP_LOGI(TAG, "MQTT Connected");
            msg_id = esp_mqtt_client_subscribe(client, MQTT_TOPIC, 0);
            ESP_LOGI(TAG, "Subscribed to %s, msg_id=%d", MQTT_TOPIC, msg_id);
            break;
        case MQTT_EVENT_DISCONNECTED:
            ESP_LOGI(TAG, "MQTT Disconnected");
            break;
        case MQTT_EVENT_DATA:
            // Parse JSON
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
                                save_last_order_to_nvs(last_order_id); // Сохраняем в постоянную память
                                
                                // Open the lock and notify the server on
                                // separate tasks: the door timing must not wait
                                // on the network, and the HTTPS/TLS POST needs a
                                // larger stack than the lock task.
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

        case MQTT_EVENT_ERROR:
            ESP_LOGI(TAG, "MQTT Error");
            break;
        default:
            break;
    }
}

static void wifi_event_handler(void* arg, esp_event_base_t event_base, int32_t event_id, void* event_data) {
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        esp_wifi_connect();
        ESP_LOGI(TAG, "Retry connecting to WiFi...");
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t* event = (ip_event_got_ip_t*) event_data;
        ESP_LOGI(TAG, "Got IP: " IPSTR, IP2STR(&event->ip_info.ip));
    }
}

void app_main(void) {
    // 1. Initialize NVS
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
      ESP_ERROR_CHECK(nvs_flash_erase());
      ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);
    
    // Загружаем последний orderid из постоянной памяти
    load_last_order_from_nvs();

    // 2. Initialize GPIO
    gpio_config_t lock_cfg = {
        .pin_bit_mask = 1ULL << LOCK_GPIO,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&lock_cfg));
    gpio_set_level(LOCK_GPIO, 0);

    // 3. Initialize Networking
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    esp_event_handler_instance_t instance_any_id;
    esp_event_handler_instance_t instance_got_ip;
    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &wifi_event_handler, NULL, &instance_any_id));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &wifi_event_handler, NULL, &instance_got_ip));

    wifi_config_t wifi_config = {
        .sta = {
            .ssid = WIFI_SSID,
            .password = WIFI_PASS,
        },
    };
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi_config));
    ESP_ERROR_CHECK(esp_wifi_start());

    // 4. Initialize MQTT
    esp_mqtt_client_config_t mqtt_cfg = {
        .broker.address.uri = MQTT_URI,
        .credentials.username = MQTT_USER,
        .credentials.client_id = MQTT_USER, // Set ClientId same as UUID
        .credentials.authentication.password = MQTT_PASS,
        .session.keepalive = 30, // Keep-alive 30 seconds
    };
    esp_mqtt_client_handle_t client = esp_mqtt_client_init(&mqtt_cfg);
    esp_mqtt_client_register_event(client, ESP_EVENT_ANY_ID, mqtt_event_handler, NULL);
    esp_mqtt_client_start(client);
    
    ESP_LOGI(TAG, "Relay Mart System Started (GPIO%d)", LOCK_GPIO);
}
