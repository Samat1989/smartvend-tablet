// Распиновка Guition JC3248W535 (ESP32-S3R8, 3.5" 320×480, AXS15231B).
//
// Экран висит на QSPI, тач — на I2C, и оба обслуживает один и тот же чип
// AXS15231B. Значения сверены по вендорскому демо и по конфигурации из
// lvgl_micropython; при смене платы проверять заново — молчаливый чёрный экран
// это единственное, что даёт неверная нога.
#pragma once

#define BOARD_NAME "Guition JC3248W535"

#define LCD_H_RES 320
#define LCD_V_RES 480

#define LCD_SPI_HOST SPI2_HOST

#define PIN_LCD_CS    45
#define PIN_LCD_PCLK  47
#define PIN_LCD_D0    21
#define PIN_LCD_D1    48
#define PIN_LCD_D2    40
#define PIN_LCD_D3    39
#define PIN_LCD_TE    38   // пока не используем: обновляем экран целиком
#define PIN_LCD_RST   (-1) // ноги сброса у панели нет, сброс идёт командой
#define PIN_LCD_BL    1

// Тач на той же микросхеме, но по своей шине.
//
// Осторожно: вендорский заголовок объявляет GPIO8 как «QSPI DC». В QSPI-режиме
// команда и данные различаются самой посылкой, отдельная нога DC не нужна, и
// эта же нога разведена на SCL тача. Отдать её под DC — потерять тач.
#define PIN_TOUCH_SCL 8
#define PIN_TOUCH_SDA 4
#define PIN_TOUCH_INT (-1)
#define PIN_TOUCH_RST (-1)
#define TOUCH_I2C_PORT I2C_NUM_0
#define TOUCH_I2C_HZ 400000

// Замок. Пока -1: реле к плате не подключено, и гонять неизвестную ногу до
// стенда нельзя — на JC3248W535 свободных выводов мало, и половина занята
// QSPI, PSRAM и USB. Значение ставится по схеме конкретной сборки; драйвер до
// тех пор честно пишет в лог, что открывать нечем.
//
// Требование к обвязке то же, что в esp-pulse: активный HIGH и подтяжка к
// земле, чтобы замок не открывался сам в момент перезагрузки.
#define PIN_LOCK (-1)
#define LOCK_OPEN_SECONDS 20

