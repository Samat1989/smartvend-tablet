#include "panel_qspi.h"

#include <string.h>

#include "board.h"
#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "init_180640.inc.h"

static const char *TAG = "panel";

static spi_device_handle_t s_spi;

// Постоянный кусок внутренней памяти, через который кадр уходит на панель.
//
// SPI-драйвер не умеет читать DMA прямо из PSRAM и на каждую посылку заводит
// временную копию во внутренней памяти. Когда рядом поднимается TLS, крупного
// свободного блока не остаётся, и кадры начинают падать с ESP_ERR_NO_MEM —
// ровно в момент оплаты. Свой буфер снимает вопрос: он выделен один раз на
// старте, и больше никто ни у кого память не отнимает.
#define CHUNK_BYTES (16 * 1024)
static uint8_t *s_chunk;

// CS дёргаем сами, как в Arduino_GFX (spics_io_num = -1). Иначе драйвер снимает
// CS между кусками кадра, а панель ждёт одну непрерывную посылку.
static inline void cs_low(void) { gpio_set_level(PIN_LCD_CS, 0); }
static inline void cs_high(void) { gpio_set_level(PIN_LCD_CS, 1); }

// Команда с параметрами: 0x02 в фазе команды, номер команды в адресе, и то и
// другое по четырём линиям. Параметры идут следом по одной линии.
static esp_err_t lcd_cmd(uint8_t cmd, const uint8_t *data, size_t len)
{
    spi_transaction_ext_t t = {
        .base = {
            .flags = SPI_TRANS_MULTILINE_CMD | SPI_TRANS_MULTILINE_ADDR,
            .cmd = 0x02,
            .addr = (uint32_t)cmd << 8,
            .tx_buffer = len ? data : NULL,
            .length = len * 8,
        },
    };
    cs_low();
    const esp_err_t err = spi_device_polling_transmit(s_spi, &t.base);
    cs_high();
    return err;
}

esp_err_t panel_qspi_draw_frame(const void *pixels)
{
    // Окно по горизонтали задаём командой, по вертикали панель в QSPI-режиме
    // окна не принимает — поэтому кадр всегда целиком (см. README, «Грабли»).
    const uint8_t caset[] = { 0x00, 0x00, (LCD_H_RES - 1) >> 8, (LCD_H_RES - 1) & 0xFF };
    ESP_RETURN_ON_ERROR(lcd_cmd(0x2A, caset, sizeof(caset)), TAG, "CASET");

    const uint8_t *src = (const uint8_t *)pixels;
    size_t left = (size_t)LCD_H_RES * LCD_V_RES * 2;
    bool first = true;

    cs_low();
    while (left) {
        // Шина отдаёт не больше 32 КБ за транзакцию, кадр — 300 КБ; режем по
        // размеру своего буфера и копируем в него из PSRAM.
        const size_t chunk = left > CHUNK_BYTES ? CHUNK_BYTES : left;
        memcpy(s_chunk, src, chunk);
        spi_transaction_ext_t t = {
            .base = {
                .tx_buffer = s_chunk,
                .length = chunk * 8,
            },
        };
        if (first) {
            // Первая посылка несёт команду записи в память панели.
            t.base.flags = SPI_TRANS_MODE_QIO;
            t.base.cmd = 0x32;
            t.base.addr = 0x002C00;
            first = false;
        } else {
            // Продолжение — без команды и адреса вовсе, данные идут потоком.
            t.base.flags = SPI_TRANS_MODE_QIO | SPI_TRANS_VARIABLE_CMD |
                           SPI_TRANS_VARIABLE_ADDR | SPI_TRANS_VARIABLE_DUMMY;
            t.command_bits = 0;
            t.address_bits = 0;
            t.dummy_bits = 0;
        }
        const esp_err_t err = spi_device_polling_transmit(s_spi, &t.base);
        if (err != ESP_OK) {
            cs_high();
            ESP_LOGE(TAG, "кадр не ушёл: %s", esp_err_to_name(err));
            return err;
        }
        src += chunk;
        left -= chunk;
    }
    cs_high();
    return ESP_OK;
}

esp_err_t panel_qspi_init(void)
{
    const gpio_config_t pins = {
        .pin_bit_mask = (1ULL << PIN_LCD_CS) | (1ULL << PIN_LCD_BL),
        .mode = GPIO_MODE_OUTPUT,
    };
    ESP_RETURN_ON_ERROR(gpio_config(&pins), TAG, "ноги CS и подсветки");
    cs_high();

    const spi_bus_config_t buscfg = {
        .data0_io_num = PIN_LCD_D0,
        .data1_io_num = PIN_LCD_D1,
        .sclk_io_num = PIN_LCD_PCLK,
        .data2_io_num = PIN_LCD_D2,
        .data3_io_num = PIN_LCD_D3,
        .max_transfer_sz = 32768,
        .flags = SPICOMMON_BUSFLAG_MASTER | SPICOMMON_BUSFLAG_GPIO_PINS,
    };
    ESP_RETURN_ON_ERROR(spi_bus_initialize(LCD_SPI_HOST, &buscfg, SPI_DMA_CH_AUTO), TAG, "шина");

    const spi_device_interface_config_t devcfg = {
        .command_bits = 8,
        .address_bits = 24,
        .mode = 0,                       // не 3, как в макросе компонента
        .clock_speed_hz = 32000000,      // потолок AXS15231B
        .spics_io_num = -1,              // CS дёргаем сами
        .flags = SPI_DEVICE_HALFDUPLEX,
        .queue_size = 1,
    };
    ESP_RETURN_ON_ERROR(spi_bus_add_device(LCD_SPI_HOST, &devcfg, &s_spi), TAG, "устройство");

    s_chunk = heap_caps_malloc(CHUNK_BYTES, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    ESP_RETURN_ON_FALSE(s_chunk != NULL, ESP_ERR_NO_MEM, TAG, "буфер посылки");

    for (size_t i = 0; i < sizeof(init_180640) / sizeof(init_180640[0]); i++) {
        ESP_RETURN_ON_ERROR(lcd_cmd(init_180640[i].cmd, init_180640[i].data,
                                    init_180640[i].len), TAG, "команда 0x%02X",
                            init_180640[i].cmd);
        if (init_180640[i].delay_ms) {
            vTaskDelay(pdMS_TO_TICKS(init_180640[i].delay_ms));
        }
    }

    gpio_set_level(PIN_LCD_BL, 1);
    ESP_LOGI(TAG, "панель поднята: %s, %dx%d", BOARD_NAME, LCD_H_RES, LCD_V_RES);
    return ESP_OK;
}
