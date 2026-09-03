// Wi-Fi: сканирование для мастера настройки и подключение по сохранённым кредам.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#define NET_MAX_SCAN 20
#define NET_SSID_LEN 33

typedef struct {
    char ssid[NET_SSID_LEN];
    int8_t rssi;
    bool secured;
} net_ap_t;

esp_err_t net_init(void);

// Сканирует эфир и заполняет список. Возвращает число найденных сетей.
int net_scan(net_ap_t *out, int max);

// Подключается и ждёт адрес. timeout_ms = 0 — ждать вечно не будем, вернём ошибку.
esp_err_t net_connect(const char *ssid, const char *password, uint32_t timeout_ms);

// Подключение по тому, что лежит в NVS.
esp_err_t net_connect_saved(uint32_t timeout_ms);

bool net_is_up(void);
