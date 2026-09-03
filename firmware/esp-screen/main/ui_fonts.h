// Шрифты интерфейса: DejaVu Sans с кириллицей, казахскими буквами (ә, ғ, қ, ң,
// ө, ұ, ү, һ, і) и знаком тенге ₸.
//
// Встроенные в LVGL Montserrat содержат только латиницу — на них русские
// надписи превращаются в пустоту, и заметить это можно только глазами.
// Сгенерированы lv_font_conv из /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf,
// команда записана в README.
#pragma once

#include "lvgl.h"

LV_FONT_DECLARE(ui_font_20)   // обычный текст
LV_FONT_DECLARE(ui_font_28)   // название товара на витрине
LV_FONT_DECLARE(ui_font_40)   // номер ячейки и суммы — видно от кассы

// Значок корзины (FontAwesome shopping-cart, U+F07A). В наборе символов LVGL
// его нет, поэтому вшит отдельно и объявлен здесь же, чтобы не разъехался с
// шрифтом.
#define UI_SYMBOL_CART "\xEF\x81\xBA"
