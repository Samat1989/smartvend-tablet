#include "net.h"

#include <string.h>
#include <time.h>

#include "board.h"
#include "config.h"
#include "driver/gpio.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_modem_api.h"
#include "esp_netif.h"
#include "esp_netif_ppp.h"
#include "esp_netif_sntp.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/task.h"
#include "store.h"

static const char *TAG = "net";

#define IP_BIT      BIT0   // some uplink has an IP
#define FAIL_BIT    BIT1   // portal Wi-Fi test gave up
#define GSM_LOST    BIT2   // PPP dropped — gsm_link_task re-dials

static EventGroupHandle_t s_eg;
static volatile bool s_has_ip;
static bool s_portal_test;       // portal is testing credentials: bounded retries
static int  s_retries;
static esp_modem_dce_t *s_dce;
static esp_netif_t *s_ppp;

static void on_wifi(void *arg, esp_event_base_t base, int32_t id, void *data) {
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        if (!s_portal_test && strcmp(g_cfg.netmode, "wifi") == 0 && g_cfg.ssid[0]) esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        if (s_portal_test) {
            if (s_retries++ < 5) esp_wifi_connect();
            else xEventGroupSetBits(s_eg, FAIL_BIT);
            return;
        }
        s_has_ip = false;
        xEventGroupClearBits(s_eg, IP_BIT);
        led_set_stage(LED_NO_LINK);
        esp_wifi_connect();      // keep trying forever
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e = data;
        ESP_LOGI(TAG, "Wi-Fi IP " IPSTR, IP2STR(&e->ip_info.ip));
        s_retries = 0;
        s_has_ip = true;
        led_set_stage(LED_HAS_IP);
        xEventGroupSetBits(s_eg, IP_BIT);
    }
}

static void on_ppp(void *arg, esp_event_base_t base, int32_t id, void *data) {
    if (id == IP_EVENT_PPP_GOT_IP) {
        ip_event_got_ip_t *e = data;
        ESP_LOGI(TAG, "GSM IP " IPSTR, IP2STR(&e->ip_info.ip));
        s_has_ip = true;
        led_set_stage(LED_HAS_IP);
        xEventGroupSetBits(s_eg, IP_BIT);
    } else if (id == IP_EVENT_PPP_LOST_IP) {
        ESP_LOGW(TAG, "GSM lost IP");
        s_has_ip = false;
        led_set_stage(LED_NO_LINK);
        xEventGroupClearBits(s_eg, IP_BIT);
        xEventGroupSetBits(s_eg, GSM_LOST);
    }
}

void net_init(void) {
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();
    wifi_init_config_t wc = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&wc));
    esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, on_wifi, NULL, NULL);
    esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP, on_wifi, NULL, NULL);
    s_eg = xEventGroupCreate();
}

// ---- GSM ----
// Power the modem (GPIO5 LOW 1 s, then HIGH), let it boot, sync AT and enter
// PPP data mode. The A7670E survives an ESP-only reset and may still sit in
// data mode, so each attempt builds a fresh DCE and tries a +++ escape.
static bool gsm_start(void) {
    gpio_config_t pw = { .pin_bit_mask = 1ULL << GSM_POWER_GPIO, .mode = GPIO_MODE_OUTPUT };
    gpio_config(&pw);
    gpio_set_level(GSM_POWER_GPIO, 0);
    vTaskDelay(pdMS_TO_TICKS(1000));
    gpio_set_level(GSM_POWER_GPIO, 1);
    ESP_LOGI(TAG, "GSM power on, booting %d ms", GSM_BOOT_DELAY_MS);
    vTaskDelay(pdMS_TO_TICKS(GSM_BOOT_DELAY_MS));

    if (!s_ppp) {
        esp_netif_config_t pc = ESP_NETIF_DEFAULT_PPP();
        s_ppp = esp_netif_new(&pc);
        if (!s_ppp) return false;
        esp_event_handler_instance_register(IP_EVENT, IP_EVENT_PPP_GOT_IP, on_ppp, NULL, NULL);
        esp_event_handler_instance_register(IP_EVENT, IP_EVENT_PPP_LOST_IP, on_ppp, NULL, NULL);
    }

    for (int attempt = 1; attempt <= 5; attempt++) {
        esp_modem_dte_config_t dte = ESP_MODEM_DTE_DEFAULT_CONFIG();
        dte.uart_config.tx_io_num = GSM_UART_TX_GPIO;
        dte.uart_config.rx_io_num = GSM_UART_RX_GPIO;
        dte.uart_config.rts_io_num = -1;
        dte.uart_config.cts_io_num = -1;
        dte.uart_config.flow_control = ESP_MODEM_FLOW_CONTROL_NONE;
        dte.uart_config.baud_rate = GSM_UART_BAUD;
        esp_modem_dce_config_t dce = ESP_MODEM_DCE_DEFAULT_CONFIG(GSM_DEFAULT_APN);
        s_dce = esp_modem_new_dev(ESP_MODEM_DCE_SIM7600, &dte, &dce, s_ppp);
        if (!s_dce) { vTaskDelay(pdMS_TO_TICKS(2000)); continue; }

        esp_err_t err = esp_modem_sync(s_dce);
        if (err != ESP_OK) {
            esp_modem_set_mode(s_dce, ESP_MODEM_MODE_COMMAND);
            vTaskDelay(pdMS_TO_TICKS(2000));
            err = esp_modem_sync(s_dce);
        }
        if (err == ESP_OK) {
            esp_modem_at(s_dce, "AT+CNMP=2", NULL, 1000);
            if (esp_modem_set_mode(s_dce, ESP_MODEM_MODE_DATA) == ESP_OK) {
                ESP_LOGI(TAG, "GSM data mode, waiting for IP");
                return true;
            }
        }
        esp_modem_destroy(s_dce);
        s_dce = NULL;
        ESP_LOGW(TAG, "GSM attempt %d failed", attempt);
        vTaskDelay(pdMS_TO_TICKS(3000));
    }
    return false;
}

static void gsm_drop(void) {
    if (s_dce) { esp_modem_destroy(s_dce); s_dce = NULL; }
}

// Owns the modem: dial, and re-dial (with a power cycle) whenever PPP drops.
static void gsm_link_task(void *pv) {
    while (true) {
        xEventGroupClearBits(s_eg, IP_BIT | GSM_LOST);
        if (!gsm_start()) {
            gsm_drop();
            vTaskDelay(pdMS_TO_TICKS(10000));
            continue;
        }
        if (!net_wait_ip(60000)) {
            ESP_LOGW(TAG, "GSM no IP — restarting modem");
            gsm_drop();
            vTaskDelay(pdMS_TO_TICKS(3000));
            continue;
        }
        esp_netif_set_default_netif(s_ppp);
        xEventGroupWaitBits(s_eg, GSM_LOST, pdTRUE, pdFALSE, portMAX_DELAY);
        ESP_LOGW(TAG, "GSM link down — restarting modem");
        gsm_drop();
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
}

void net_start(void) {
    if (strcmp(g_cfg.netmode, "wifi") == 0) {
        ESP_LOGI(TAG, "uplink Wi-Fi '%s'", g_cfg.ssid);
        ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
        wifi_config_t sta = {0};
        strlcpy((char *)sta.sta.ssid, g_cfg.ssid, sizeof(sta.sta.ssid));
        strlcpy((char *)sta.sta.password, g_cfg.pass, sizeof(sta.sta.password));
        ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &sta));
        ESP_ERROR_CHECK(esp_wifi_start());
    } else {
        ESP_LOGI(TAG, "uplink GSM (APN %s)", GSM_DEFAULT_APN);
        xTaskCreate(gsm_link_task, "gsm_link", 6144, NULL, 5, NULL);
    }
}

bool net_wait_ip(int timeout_ms) {
    EventBits_t b = xEventGroupWaitBits(s_eg, IP_BIT, pdFALSE, pdFALSE, pdMS_TO_TICKS(timeout_ms));
    return (b & IP_BIT) != 0;
}

bool net_has_ip(void) { return s_has_ip; }

void net_portal_mode(void) { s_portal_test = true; }

// Portal only: the AP is already up in APSTA mode.
bool net_wifi_try(const char *ssid, const char *pass) {
    s_portal_test = true;
    s_retries = 0;
    xEventGroupClearBits(s_eg, IP_BIT | FAIL_BIT);
    wifi_config_t sta = {0};
    strlcpy((char *)sta.sta.ssid, ssid, sizeof(sta.sta.ssid));
    strlcpy((char *)sta.sta.password, pass, sizeof(sta.sta.password));
    esp_wifi_set_config(WIFI_IF_STA, &sta);
    esp_wifi_connect();
    EventBits_t b = xEventGroupWaitBits(s_eg, IP_BIT | FAIL_BIT, pdFALSE, pdFALSE, pdMS_TO_TICKS(20000));
    esp_wifi_disconnect();
    return (b & IP_BIT) != 0;
}

int net_rssi(void) {
    if (strcmp(g_cfg.netmode, "wifi") != 0) return 0;
    wifi_ap_record_t ap;
    return esp_wifi_sta_get_ap_info(&ap) == ESP_OK ? ap.rssi : 0;
}

// Signed commands carry an expiry, so the board needs real time.
void net_sntp_start(void) {
    esp_sntp_config_t c = ESP_NETIF_SNTP_DEFAULT_CONFIG_MULTIPLE(2,
        ESP_SNTP_SERVER_LIST("pool.ntp.org", "time.google.com"));
    esp_netif_sntp_init(&c);
}

bool net_time_synced(void) {
    return time(NULL) > 1700000000;   // after Nov 2023: the clock has been set
}
