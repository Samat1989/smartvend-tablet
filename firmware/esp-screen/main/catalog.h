// Каталог машины: то, из чего покупатель выбирает на нумпаде.
//
// Контракт — docs/esp-screen-micromarket.md §5a. Устройство читает инвентарь
// прямым анонимным select и хранит его в разделе `storage`, чтобы короткий
// обрыв связи не гасил витрину.
#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "esp_err.h"

#define CATALOG_MAX_ITEMS 90     // ячейки 10..99, больше нумпад не наберёт
#define CATALOG_NAME_LEN 48
#define CATALOG_UUID_LEN 37

typedef struct {
    int cell;                        // номер ячейки, он же inventory.motor_id
    char id[CATALOG_UUID_LEN];       // uuid строки инвентаря — им платим
    char name[CATALOG_NAME_LEN];
    int price;
    int stock;
} catalog_item_t;

// Поднимает кэш с флеша. Ошибка — просто пустой каталог, это не авария.
esp_err_t catalog_init(void);

// Перечитывает каталог с сервера и обновляет кэш. `digest` — отпечаток, при
// котором эти данные получены; он ложится рядом и переживает перезагрузку.
esp_err_t catalog_refresh(const char *digest);

// Отпечаток, при котором собран нынешний кэш. Пустая строка — кэша нет.
const char *catalog_digest(void);

int catalog_count(void);

// Товар по номеру ячейки — копией, а не ссылкой: каталог переписывает фоновая
// задача, и указатель в чужие руки отдавать нельзя. false — номера нет.
bool catalog_get(int cell, catalog_item_t *out);
