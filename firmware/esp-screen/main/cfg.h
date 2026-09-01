// Настройки, пережившие перезагрузку: Wi-Fi, номер аппарата, секрет машины.
//
// Секрет сюда попадает не руками, а из device-provision по номеру аппарата —
// монтажник его не видит и не вводит (docs/esp-screen-micromarket.md §5a).
#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "esp_err.h"

esp_err_t cfg_init(void);

// Возвращают ESP_ERR_NVS_NOT_FOUND, если ключа нет.
esp_err_t cfg_get(const char *key, char *out, size_t out_size);
esp_err_t cfg_set(const char *key, const char *value);
esp_err_t cfg_erase(const char *key);

// Машина привязана: есть и номер аппарата, и секрет.
bool cfg_is_paired(void);
