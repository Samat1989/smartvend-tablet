// Экраны покупки: нумпад → корзина → QR → выдача.
//
// Раскладка и правила поведения — docs/esp-screen-micromarket.md §4a.
#pragma once

void ui_shop_start(void);

// Обновить витрину после того, как приехал новый каталог.
void ui_shop_catalog_changed(void);
