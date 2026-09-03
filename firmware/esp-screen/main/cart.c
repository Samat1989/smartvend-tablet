#include "cart.h"

#include <string.h>

static cart_line_t s_lines[CART_MAX_LINES];
static int s_count;

static cart_line_t *find(int cell)
{
    for (int i = 0; i < s_count; i++) {
        if (s_lines[i].cell == cell) {
            return &s_lines[i];
        }
    }
    return NULL;
}

bool cart_add(int cell)
{
    catalog_item_t item;
    if (!catalog_get(cell, &item)) {
        return false;
    }

    cart_line_t *line = find(cell);
    const int have = line ? line->count : 0;
    // Больше остатка не набираем. Кэш может врать в меньшую сторону, но сервер
    // всё равно проверит при оплате — отказать сразу честнее, чем на экране QR.
    if (have >= item.stock) {
        return false;
    }
    if (line) {
        line->count++;
        return true;
    }
    if (s_count >= CART_MAX_LINES) {
        return false;
    }
    s_lines[s_count++] = (cart_line_t){ .cell = cell, .count = 1 };
    return true;
}

void cart_set_count(int cell, int count)
{
    cart_line_t *line = find(cell);
    if (!line) {
        return;
    }
    catalog_item_t item;
    if (catalog_get(cell, &item) && count > item.stock) {
        count = item.stock;
    }
    if (count <= 0) {
        cart_remove(cell);
        return;
    }
    line->count = count;
}

void cart_remove(int cell)
{
    for (int i = 0; i < s_count; i++) {
        if (s_lines[i].cell == cell) {
            memmove(&s_lines[i], &s_lines[i + 1], (size_t)(s_count - i - 1) * sizeof(cart_line_t));
            s_count--;
            return;
        }
    }
}

void cart_clear(void)
{
    s_count = 0;
}

int cart_lines(void)
{
    return s_count;
}

const cart_line_t *cart_line(int index)
{
    return (index >= 0 && index < s_count) ? &s_lines[index] : NULL;
}

int cart_count_of(int cell)
{
    const cart_line_t *line = find(cell);
    return line ? line->count : 0;
}

int cart_total_items(void)
{
    int n = 0;
    for (int i = 0; i < s_count; i++) {
        n += s_lines[i].count;
    }
    return n;
}

int cart_total_price(void)
{
    int sum = 0;
    for (int i = 0; i < s_count; i++) {
        catalog_item_t item;
        if (catalog_get(s_lines[i].cell, &item)) {
            sum += item.price * s_lines[i].count;
        }
    }
    return sum;
}

bool cart_is_empty(void)
{
    return s_count == 0;
}
