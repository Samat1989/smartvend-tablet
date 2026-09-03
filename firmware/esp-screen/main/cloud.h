// Обращения к Supabase. Контракт целиком — docs/esp-screen-micromarket.md §5a.
#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "esp_err.h"

// Результат привязки: что показать монтажнику на экране.
typedef enum {
    PAIR_OK,              // машина наша, секрет сохранён
    PAIR_NOT_FOUND,       // такого номера нет в списке SmartVend
    PAIR_WRONG_KIND,      // машина есть, но это не микромаркет с экраном
    PAIR_TAKEN,           // машину уже держит другое устройство
    PAIR_NETWORK,         // сеть или сервер не ответили
} pair_result_t;

// Полный цикл привязки по одному номеру аппарата:
// device-provision → verify_pairing → claim_machine, с записью в NVS.
pair_result_t cloud_pair(const char *machid);

// Биение раз в пять минут. Возвращает отпечаток каталога в catalog_out
// (строка md5 или пустая) и сообщает, не отвязали ли машину в панели.
typedef enum { CLAIM_OK, CLAIM_LOST, CLAIM_RELEASED } claim_state_t;
esp_err_t cloud_ping(claim_state_t *claim_out, char *catalog_out, size_t catalog_size);

// POST в Supabase с anon-ключом: путь от корня, тело — JSON. Возвращает код
// ответа (или -1, если запрос вовсе не ушёл) и кладёт тело в out.
int cloud_post(const char *path, const char *body, char *out, size_t out_size);

// Каталог машины прямым анонимным select: только позиции с номером ячейки,
// по возрастанию номера. Тот же фильтр, по которому сервер считает отпечаток.
esp_err_t cloud_fetch_catalog(char *out, size_t out_size);
