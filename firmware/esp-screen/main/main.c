// esp-screen — микромаркет с экраном на самом автомате.
//
// Замысел, контракт с бэкендом и порядок работ: docs/esp-screen-micromarket.md.
// Каркас взят от firmware/esp-pulse (замок, provisioning, watchdog), но MQTT
// оттуда не переносится: об оплате устройство узнаёт само, дёргая complete-order
// по своему orderid.
//
// Сделано: панель и тач (F2), сеть и привязка через мастер на экране (F3).
// Дальше — каталог по отпечатку (F4) и экраны покупки (F5).

#include <inttypes.h>

#include "board.h"
#include "catalog.h"
#include "cfg.h"
#include "display.h"
#include "heartbeat.h"
#include "net.h"
#include "ui_home.h"
#include "ui_setup.h"
#include "ui_shop.h"

#include "esp_app_desc.h"
#include "esp_chip_info.h"
#include "esp_flash.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_psram.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "spi_flash_mmap.h"

static const char *TAG = "screen";

// Печатаем то, из-за чего этот вариант когда-то и откладывали: хватит ли
// памяти. Если PSRAM не поднялась (не та плата, не тот режим шины), лучше
// узнать это на первой секунде, а не когда LVGL попросит буфер кадра.
static void log_hardware(void)
{
    esp_chip_info_t chip;
    esp_chip_info(&chip);

    uint32_t flash_size = 0;
    if (esp_flash_get_size(NULL, &flash_size) != ESP_OK) {
        flash_size = 0;
    }

    const esp_app_desc_t *app = esp_app_get_description();

    ESP_LOGI(TAG, "версия прошивки: %s (idf %s)", app->version, app->idf_ver);
    ESP_LOGI(TAG, "чип: %s, ядер %d, ревизия v%d.%d", CONFIG_IDF_TARGET, chip.cores,
             chip.revision / 100, chip.revision % 100);
    ESP_LOGI(TAG, "флеш: %" PRIu32 " МБ", flash_size / (1024 * 1024));

    if (esp_psram_is_initialized()) {
        ESP_LOGI(TAG, "PSRAM: %u КБ, свободно %u КБ",
                 (unsigned)(esp_psram_get_size() / 1024),
                 (unsigned)(heap_caps_get_free_size(MALLOC_CAP_SPIRAM) / 1024));
    } else {
        ESP_LOGE(TAG, "PSRAM не инициализирована — LVGL негде будет держать буферы");
    }

    ESP_LOGI(TAG, "внутренняя куча: %u КБ свободно, самый большой блок %u КБ",
             (unsigned)(heap_caps_get_free_size(MALLOC_CAP_INTERNAL) / 1024),
             (unsigned)(heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL) / 1024));

    const esp_partition_t *running = esp_ota_get_running_partition();
    if (running) {
        ESP_LOGI(TAG, "загрузились из раздела %s (%" PRIu32 " КБ по адресу 0x%" PRIx32 ")",
                 running->label, running->size / 1024, running->address);
    }
}

void app_main(void)
{
    ESP_ERROR_CHECK(cfg_init());

    log_hardware();

    esp_err_t err = display_start();
    if (err != ESP_OK) {
        // Без экрана продавать нечем: это вся витрина. Не уходим в перезагрузку
        // по кругу, а оставляем плату с внятным логом — на месте по нему видно,
        // что чинить.
        ESP_LOGE(TAG, "экран не поднялся: %s", esp_err_to_name(err));
        return;
    }

    ESP_ERROR_CHECK(net_init());

    if (!cfg_is_paired()) {
        // Первое включение: сеть и номер аппарата спрашиваем на самом экране.
        ESP_LOGI(TAG, "аппарат не привязан — показываем мастер настройки");
        display_lock(0);
        ui_setup_show();
        display_unlock();
    } else {
        ESP_LOGI(TAG, "аппарат привязан, поднимаем сеть");
        if (net_connect_saved(20000) != ESP_OK) {
            ESP_LOGW(TAG, "сеть недоступна — продолжаем, подключение повторится само");
        }
        // Каталог сначала из кэша — витрина оживает мгновенно и переживает
        // отсутствие сети; свежесть догонит первое же биение.
        catalog_init();

        display_lock(0);
        if (catalog_count() > 0) {
            ui_shop_start();
        } else {
            // Каталог пуст: продавать нечего, но и пугать покупателя нечем —
            // показываем спокойный экран ожидания, пока владелец не заведёт
            // позиции в панели.
            ui_home_show();
        }
        display_unlock();

        heartbeat_start();
    }

    // Живой лог: сразу видно, стоит плата или перезагружается по кругу.
    for (uint32_t tick = 0;; tick++) {
        ESP_LOGI(TAG, "жив, %" PRIu32 " с, сеть %s, свободно внутренней %u КБ, PSRAM %u КБ",
                 tick * 30, net_is_up() ? "есть" : "нет",
                 (unsigned)(heap_caps_get_free_size(MALLOC_CAP_INTERNAL) / 1024),
                 (unsigned)(heap_caps_get_free_size(MALLOC_CAP_SPIRAM) / 1024));
        vTaskDelay(pdMS_TO_TICKS(30000));
    }
}
