// Корзина покупателя. Живёт только в памяти: незаконченная покупка не должна
// пережить перезагрузку и достаться следующему человеку.
#pragma once

#include <stdbool.h>

#include "catalog.h"

#define CART_MAX_LINES 12

typedef struct {
    int cell;
    int count;
} cart_line_t;

// Добавляет одну штуку. Повторный ввод того же номера увеличивает количество,
// а не заводит вторую строку. Возвращает false, если больше остатка.
bool cart_add(int cell);

void cart_set_count(int cell, int count);
void cart_remove(int cell);
void cart_clear(void);

int cart_lines(void);
const cart_line_t *cart_line(int index);
int cart_count_of(int cell);
int cart_total_items(void);
int cart_total_price(void);
bool cart_is_empty(void);
