// esp-rt — firmware for static-QR lock boards on Supabase Realtime.
//
// Boot:
//   1. lock parked closed, external watchdog and status LED running;
//   2. setup portal if there is no config, if pairing was refused, or if BOOT
//      was tapped more than 3 times within 4 s of power-on;
//   3. otherwise bring up Wi-Fi or GSM; pair once if a code is waiting;
//   4. join the Realtime channel and serve ping / open / service-open.
//
// No MQTT, no device-provision, no SmartVend uuid/secret on the board: the
// payment is run by Supabase (create-payment), the board only proves it is
// online (Presence, pong) and opens on a signed command.

#include <string.h>

#include "app.h"
#include "board.h"
#include "config.h"
#include "esp_log.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "net.h"
#include "ota.h"
#include "pair.h"
#include "portal.h"
#include "store.h"

static const char *TAG = "esp-rt";

void app_main(void) {
    store_init();
    store_load();
    lock_init();
    ext_wd_start();
    led_start();
    net_init();
    ESP_LOGI(TAG, "esp-rt %s v%s, board %s, %s", FW_VARIANT, FW_VERSION_NAME,
             store_device_id(), store_paired() ? "paired" : "not paired");

    bool configured = store_has_network() && (store_paired() || g_cfg.code[0]);
    int presses = button_press_count(PROVISION_WINDOW_MS);
    if (!configured || g_cfg.pair_error || presses > PROVISION_PRESS_COUNT) {
        // A refused code has nothing to fall back to — rebooting would only
        // refuse it again — so that portal waits for the owner indefinitely.
        if (g_cfg.pair_error) led_set_pair_error(true);
        portal_start(configured && !g_cfg.pair_error);
        return;
    }

    net_start();
    if (!net_wait_ip(90000)) ESP_LOGW(TAG, "no IP after 90 s, carrying on — the uplink keeps retrying");

    if (!store_paired()) {
        while (true) {
            while (!net_wait_ip(60000)) {}
            pair_result_t r = pair_device();
            if (r == PAIR_OK) {
                store_erase("code");
                break;
            }
            if (r == PAIR_REFUSED) {
                store_erase("code");
                store_set_int("pairerr", 1);
                ESP_LOGE(TAG, "pairing code refused — rebooting into the setup portal");
                vTaskDelay(pdMS_TO_TICKS(1000));
                esp_restart();
            }
            ESP_LOGW(TAG, "pairing: no connection to the server, retry in 10 s");
            vTaskDelay(pdMS_TO_TICKS(10000));
        }
    }

    app_start();
    ota_start();
    ESP_LOGI(TAG, "running; free heap %lu B", (unsigned long)esp_get_free_heap_size());
}
