// Платёжный контур: создать заказ и дождаться подтверждения.
//
// Поток целиком — docs/esp-screen-micromarket.md §4. Главное правило: замок
// открывается только по HTTP 200 от complete-order, то есть после того, как
// сервер подтвердил оплату в шлюзе и записал продажу.
#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "esp_err.h"

#define PAYMENT_URL_LEN 320
#define PAYMENT_ORDERID_LEN 64

typedef struct {
    char url[PAYMENT_URL_LEN];        // строка для QR, её рисуем на экране
    char orderid[PAYMENT_ORDERID_LEN];
} payment_t;

// Создаёт заказ по текущей корзине. Сумму считает сервер по своему инвентарю.
esp_err_t payment_create(payment_t *out);

typedef enum {
    PAYMENT_PAID,       // 200: деньги захвачены, продажа записана — можно открывать
    PAYMENT_WAITING,    // 503: покупатель ещё не заплатил
    PAYMENT_UNKNOWN,    // 404: заказа нет в базе — в журнал и назад в корзину
    PAYMENT_ERROR,      // сеть или сервер
} payment_state_t;

// Один вызов complete-order. Он сам делает четыре попытки по 3 с и отвечает
// 503, пока оплаты нет, — то есть занимает около двенадцати секунд и сам
// задаёт ритм опроса.
payment_state_t payment_poll(const char *orderid);
