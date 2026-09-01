#include "lock.h"

#include "board.h"
#include "driver/gpio.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "lock";

void lock_init(void)
{
    if (PIN_LOCK < 0) {
        ESP_LOGW(TAG, "нога замка не назначена — открывать нечем (см. board.h)");
        return;
    }
    const gpio_config_t cfg = {
        .pin_bit_mask = 1ULL << PIN_LOCK,
        .mode = GPIO_MODE_OUTPUT,
        .pull_down_en = GPIO_PULLDOWN_ENABLE,
    };
    gpio_config(&cfg);
    // Парковка в закрытое состояние на старте: перезагрузка не должна
    // открывать дверь.
    gpio_set_level(PIN_LOCK, 0);
    ESP_LOGI(TAG, "замок на GPIO%d, удержание %d с", PIN_LOCK, LOCK_OPEN_SECONDS);
}

bool lock_open(void)
{
    if (PIN_LOCK < 0) {
        ESP_LOGW(TAG, "замок открыть нечем: нога не назначена");
        return false;
    }
    ESP_LOGI(TAG, "открываю на %d с", LOCK_OPEN_SECONDS);
    gpio_set_level(PIN_LOCK, 1);
    vTaskDelay(pdMS_TO_TICKS(LOCK_OPEN_SECONDS * 1000));
    gpio_set_level(PIN_LOCK, 0);
    ESP_LOGI(TAG, "закрыт");
    return true;
}
