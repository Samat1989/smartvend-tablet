#include "heartbeat.h"

#include <stdio.h>
#include <string.h>

#include "catalog.h"
#include "cfg.h"
#include "cloud.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "net.h"
#include "ui_home.h"
#include "ui_shop.h"
#include "ui_setup.h"

static const char *TAG = "heartbeat";

// Пять минут, как у планшета: сервер считает машину живой пятнадцать минут,
// то есть переживает три пропущенных биения.
#define PING_INTERVAL_MS (5 * 60 * 1000)

// Полчаса без единого успешного биения — перезагрузка.
//
// Автомат стоит без людей, и самая частая причина «висит, но не продаёт» — это
// не логика, а залипший стек: Wi-Fi не переподключается, TLS не поднимается,
// сокеты кончились. Перезагрузка чинит всё это за десять секунд, а покупатель
// в это время всё равно ничего не купил бы. Каталог и привязка переживают
// перезагрузку, так что цена такого лечения — только время загрузки.
#define OFFLINE_REBOOT_US ((int64_t)30 * 60 * 1000 * 1000)

static void status_line(void)
{
    char text[64];
    snprintf(text, sizeof(text), "%s, позиций: %d",
             net_is_up() ? "сеть есть" : "сети нет", catalog_count());
    ui_home_set_status(text);
}

static void unpaired(const char *why)
{
    // Машину забрали в панели владельца. Стираем привязку и возвращаем мастер:
    // держать каталог чужой машины и тем более продавать по нему нельзя.
    ESP_LOGW(TAG, "привязка снята: %s", why);
    cfg_erase("machid");
    cfg_erase("secret");
    ui_setup_show();
}

static void heartbeat_task(void *arg)
{
    (void)arg;
    int64_t last_ok = esp_timer_get_time();


    // Первый заход сразу: панель владельца должна увидеть машину живой, не
    // дожидаясь пяти минут, да и каталог нужен покупателю сейчас.
    while (true) {
        if (esp_timer_get_time() - last_ok > OFFLINE_REBOOT_US) {
            ESP_LOGE(TAG, "полчаса без связи с сервером — перезагружаюсь");
            esp_restart();
        }

        if (!net_is_up()) {
            ESP_LOGW(TAG, "сети нет — биение пропущено");
            status_line();
            vTaskDelay(pdMS_TO_TICKS(30000));
            continue;
        }

        claim_state_t claim = CLAIM_OK;
        char digest[64] = {0};
        if (cloud_ping(&claim, digest, sizeof(digest)) == ESP_OK) {
            last_ok = esp_timer_get_time();
        } else {
            ESP_LOGW(TAG, "сервер не ответил на биение");
            status_line();
            vTaskDelay(pdMS_TO_TICKS(60000));
            continue;
        }

        if (claim == CLAIM_LOST) {
            unpaired("машину занял другой аппарат");
            vTaskDelete(NULL);
            return;
        }
        if (claim == CLAIM_RELEASED) {
            unpaired("владелец отвязал машину в панели");
            vTaskDelete(NULL);
            return;
        }

        // Правило расхождения ровно такое же, как в планшете: пустой отпечаток
        // (старый сервер) ничего не перезагружает, любой другой — только если
        // отличается от того, при котором собран кэш.
        if (digest[0] && strcmp(digest, catalog_digest()) != 0) {
            ESP_LOGI(TAG, "каталог изменился, перечитываем");
            if (catalog_refresh(digest) == ESP_OK) {
                ui_shop_catalog_changed();
            }
        }

        status_line();
        vTaskDelay(pdMS_TO_TICKS(PING_INTERVAL_MS));
    }
}

void heartbeat_start(void)
{
    // 12 КБ: столько же, сколько задаче привязки — тот же TLS-обмен с Supabase.
    xTaskCreate(heartbeat_task, "heartbeat", 12288, NULL, 4, NULL);
}
