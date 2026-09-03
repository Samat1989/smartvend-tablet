#include "net.h"

#include <string.h>

#include "cfg.h"
#include "esp_check.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"

static const char *TAG = "net";

#define BIT_GOT_IP BIT0
#define BIT_FAILED BIT1

#define RECONNECT_DELAY_US (5 * 1000 * 1000)

static EventGroupHandle_t s_events;
static bool s_up;
static esp_timer_handle_t s_retry;

static void retry_connect(void *arg)
{
    (void)arg;
    esp_wifi_connect();
}

static void on_wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    (void)data;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        s_up = false;
        // Переподключаемся молча: точка могла моргнуть питанием, и это не повод
        // тревожить покупателя. Мастер настройки о неудаче узнает по таймауту.
        //
        // Пробуем через таймер, а не сразу: когда точка выключена совсем,
        // немедленный повтор превращается в плотный цикл, который греет радио и
        // забивает лог сотнями строк в минуту.
        if (s_retry) {
            esp_timer_start_once(s_retry, RECONNECT_DELAY_US);
        }
        xEventGroupSetBits(s_events, BIT_FAILED);
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        s_up = true;
        xEventGroupSetBits(s_events, BIT_GOT_IP);
    }
}

esp_err_t net_init(void)
{
    s_events = xEventGroupCreate();
    ESP_RETURN_ON_FALSE(s_events != NULL, ESP_ERR_NO_MEM, TAG, "события");

    ESP_RETURN_ON_ERROR(esp_netif_init(), TAG, "netif");
    ESP_RETURN_ON_ERROR(esp_event_loop_create_default(), TAG, "event loop");
    esp_netif_create_default_wifi_sta();

    const wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_RETURN_ON_ERROR(esp_wifi_init(&cfg), TAG, "wifi init");
    ESP_RETURN_ON_ERROR(esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                                            on_wifi_event, NULL, NULL),
                        TAG, "обработчик wifi");
    ESP_RETURN_ON_ERROR(esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                                            on_wifi_event, NULL, NULL),
                        TAG, "обработчик ip");
    const esp_timer_create_args_t retry = {
        .callback = retry_connect,
        .name = "wifi_retry",
    };
    ESP_RETURN_ON_ERROR(esp_timer_create(&retry, &s_retry), TAG, "таймер переподключения");

    ESP_RETURN_ON_ERROR(esp_wifi_set_mode(WIFI_MODE_STA), TAG, "режим");
    ESP_RETURN_ON_ERROR(esp_wifi_set_storage(WIFI_STORAGE_RAM), TAG, "хранение");
    return esp_wifi_start();
}

int net_scan(net_ap_t *out, int max)
{
    if (esp_wifi_scan_start(NULL, true) != ESP_OK) {
        return 0;
    }
    uint16_t found = 0;
    esp_wifi_scan_get_ap_num(&found);
    if (found == 0) {
        return 0;
    }
    if (found > NET_MAX_SCAN) {
        found = NET_MAX_SCAN;
    }

    wifi_ap_record_t records[NET_MAX_SCAN];
    if (esp_wifi_scan_get_ap_records(&found, records) != ESP_OK) {
        return 0;
    }

    int n = 0;
    for (int i = 0; i < found && n < max; i++) {
        if (records[i].ssid[0] == 0) {
            continue;   // скрытые сети выбрать всё равно нельзя
        }
        bool dup = false;
        for (int j = 0; j < n; j++) {
            if (strcmp(out[j].ssid, (const char *)records[i].ssid) == 0) {
                dup = true;   // одна сеть на нескольких точках — показываем раз
                break;
            }
        }
        if (dup) {
            continue;
        }
        strncpy(out[n].ssid, (const char *)records[i].ssid, NET_SSID_LEN - 1);
        out[n].ssid[NET_SSID_LEN - 1] = 0;
        out[n].rssi = records[i].rssi;
        out[n].secured = records[i].authmode != WIFI_AUTH_OPEN;
        n++;
    }
    return n;
}

esp_err_t net_connect(const char *ssid, const char *password, uint32_t timeout_ms)
{
    wifi_config_t sta = {0};
    strncpy((char *)sta.sta.ssid, ssid, sizeof(sta.sta.ssid) - 1);
    if (password) {
        strncpy((char *)sta.sta.password, password, sizeof(sta.sta.password) - 1);
    }

    ESP_RETURN_ON_ERROR(esp_wifi_set_config(WIFI_IF_STA, &sta), TAG, "конфиг");
    xEventGroupClearBits(s_events, BIT_GOT_IP | BIT_FAILED);
    esp_wifi_disconnect();
    ESP_RETURN_ON_ERROR(esp_wifi_connect(), TAG, "подключение");

    const EventBits_t bits = xEventGroupWaitBits(s_events, BIT_GOT_IP, pdFALSE, pdFALSE,
                                                 pdMS_TO_TICKS(timeout_ms ? timeout_ms : 20000));
    if (!(bits & BIT_GOT_IP)) {
        ESP_LOGW(TAG, "«%s» не отвечает", ssid);
        return ESP_ERR_TIMEOUT;
    }
    ESP_LOGI(TAG, "подключены к «%s»", ssid);
    return ESP_OK;
}

esp_err_t net_connect_saved(uint32_t timeout_ms)
{
    char ssid[NET_SSID_LEN] = {0};
    char pass[65] = {0};
    ESP_RETURN_ON_ERROR(cfg_get("ssid", ssid, sizeof(ssid)), TAG, "нет сохранённой сети");
    cfg_get("pass", pass, sizeof(pass));   // открытая сеть — пароля может не быть
    return net_connect(ssid, pass, timeout_ms);
}

bool net_is_up(void)
{
    return s_up;
}
