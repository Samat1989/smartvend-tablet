#include "display.h"

#include <string.h>

#include "board.h"
#include "driver/i2c_master.h"
#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_lcd_axs15231b.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_touch.h"
#include "esp_log.h"
#include "esp_task_wdt.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "panel_qspi.h"
#include "ui_fonts.h"

static const char *TAG = "display";

static SemaphoreHandle_t s_lock;
static esp_lcd_touch_handle_t s_touch;

// LVGL держит время сама, но спрашивает его у нас.
static uint32_t tick_get(void)
{
    return (uint32_t)(esp_timer_get_time() / 1000);
}

// Собственный кадр в PSRAM: панель принимает только целые кадры, а рисует LVGL
// кусками. Здесь куски и собираются.
static uint16_t *s_frame;

// Рисуем в маленький буфер во внутренней памяти, а не сразу в PSRAM.
//
// Разница ощутима руками: запись в PSRAM в разы медленнее внутренней, и когда
// LVGL рендерил прямо туда, прокрутка корзины заметно подтормаживала. Теперь
// отрисовка идёт быстро, а в PSRAM уходит только копия готовых строк — и раз в
// кадр одна посылка на панель.
static void flush_cb(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map)
{
    const int32_t w = lv_area_get_width(area);
    const int32_t h = lv_area_get_height(area);

    // LVGL складывает RGB565 младшим байтом вперёд, панель ждёт наоборот.
    lv_draw_sw_rgb565_swap(px_map, (uint32_t)(w * h));

    const uint16_t *src = (const uint16_t *)px_map;
    for (int32_t y = 0; y < h; y++) {
        memcpy(&s_frame[(area->y1 + y) * LCD_H_RES + area->x1], src + y * w, (size_t)w * 2);
    }

    // Панель не принимает окно по вертикали (RASET в QSPI-режиме не шлётся),
    // поэтому отправляем целиком — но один раз, когда LVGL отдал последний
    // кусок кадра.
    if (lv_display_flush_is_last(disp)) {
        panel_qspi_draw_frame(s_frame);
    }
    lv_display_flush_ready(disp);
}

static void touch_read_cb(lv_indev_t *indev, lv_indev_data_t *data)
{
    (void)indev;
    uint16_t x = 0, y = 0;
    uint8_t count = 0;

    esp_lcd_touch_read_data(s_touch);
    if (esp_lcd_touch_get_coordinates(s_touch, &x, &y, NULL, &count, 1) && count > 0) {
        data->point.x = x;
        data->point.y = y;
        data->state = LV_INDEV_STATE_PRESSED;
    } else {
        data->state = LV_INDEV_STATE_RELEASED;
    }
}

static void lvgl_task(void *arg)
{
    (void)arg;
    // Берём задачу под сторожевой таймер: если отрисовка встанет, автомат
    // покажет застывший экран и будет молча принимать деньги — перезагрузка
    // тут честнее.
    esp_task_wdt_add(NULL);

    while (true) {
        esp_task_wdt_reset();
        uint32_t wait_ms = 10;
        if (display_lock(20)) {
            wait_ms = lv_timer_handler();
            display_unlock();
        }
        if (wait_ms > 100) {
            wait_ms = 100;
        }
        vTaskDelay(pdMS_TO_TICKS(wait_ms < 5 ? 5 : wait_ms));
    }
}

void display_load_screen(lv_obj_t *scr)
{
    lv_obj_t *old = lv_screen_active();
    lv_screen_load(scr);
    if (old && old != scr) {
        lv_obj_delete_async(old);
    }
}

bool display_lock(uint32_t timeout_ms)
{
    const TickType_t ticks = timeout_ms ? pdMS_TO_TICKS(timeout_ms) : portMAX_DELAY;
    return xSemaphoreTakeRecursive(s_lock, ticks) == pdTRUE;
}

void display_unlock(void)
{
    xSemaphoreGiveRecursive(s_lock);
}

static esp_err_t touch_start(void)
{
    const i2c_master_bus_config_t i2c_cfg = {
        .i2c_port = TOUCH_I2C_PORT,
        .sda_io_num = PIN_TOUCH_SDA,
        .scl_io_num = PIN_TOUCH_SCL,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .flags.enable_internal_pullup = true,
    };
    i2c_master_bus_handle_t bus = NULL;
    ESP_RETURN_ON_ERROR(i2c_new_master_bus(&i2c_cfg, &bus), TAG, "шина I2C");

    // Адрес 0x3B зашит в макрос компонента; скорость дописываем сами, потому
    // что в макросе ..._CONFIG_EX имя параметра совпадает с именем поля и
    // препроцессор портит designator.
    esp_lcd_panel_io_i2c_config_t io_cfg = ESP_LCD_TOUCH_IO_I2C_AXS15231B_CONFIG();
    io_cfg.scl_speed_hz = TOUCH_I2C_HZ;
    esp_lcd_panel_io_handle_t io = NULL;
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_io_i2c(bus, &io_cfg, &io), TAG, "io тача");

    const esp_lcd_touch_config_t cfg = {
        .x_max = LCD_H_RES,
        .y_max = LCD_V_RES,
        .rst_gpio_num = PIN_TOUCH_RST,
        .int_gpio_num = PIN_TOUCH_INT,
    };
    return esp_lcd_touch_new_i2c_axs15231b(io, &cfg, &s_touch);
}

esp_err_t display_start(void)
{
    ESP_RETURN_ON_ERROR(panel_qspi_init(), TAG, "панель");

    s_lock = xSemaphoreCreateRecursiveMutex();
    ESP_RETURN_ON_FALSE(s_lock != NULL, ESP_ERR_NO_MEM, TAG, "мьютекс");

    lv_init();
    lv_tick_set_cb(tick_get);

    lv_display_t *disp = lv_display_create(LCD_H_RES, LCD_V_RES);
    ESP_RETURN_ON_FALSE(disp != NULL, ESP_FAIL, TAG, "дисплей lvgl");

    // Кадр целиком — в PSRAM. DMA до него не дотягивается, но это и не нужно:
    // на панель он уходит через свой буфер внутри panel_qspi.
    const size_t frame = (size_t)LCD_H_RES * LCD_V_RES * sizeof(uint16_t);
    s_frame = heap_caps_malloc(frame, MALLOC_CAP_SPIRAM);
    ESP_RETURN_ON_FALSE(s_frame != NULL, ESP_ERR_NO_MEM, TAG, "кадр в PSRAM");
    memset(s_frame, 0, frame);

    // Рабочий буфер LVGL — сорок строк во внутренней памяти. Больше брать
    // незачем: она нужна TLS, а выигрыш в скорости даёт сам факт отрисовки не
    // в PSRAM.
    const size_t work = (size_t)LCD_H_RES * 40 * sizeof(uint16_t);
    void *buf = heap_caps_malloc(work, MALLOC_CAP_INTERNAL);
    ESP_RETURN_ON_FALSE(buf != NULL, ESP_ERR_NO_MEM, TAG, "рабочий буфер");

    lv_display_set_color_format(disp, LV_COLOR_FORMAT_RGB565);
    lv_display_set_buffers(disp, buf, NULL, work, LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(disp, flush_cb);

    // Шрифт по умолчанию — свой: во встроенных Montserrat нет кириллицы, и все
    // русские надписи молча превращаются в пустые строки.
    lv_theme_t *theme = lv_theme_default_init(disp, lv_palette_main(LV_PALETTE_BLUE),
                                              lv_palette_main(LV_PALETTE_RED), true, &ui_font_20);
    lv_display_set_theme(disp, theme);

    if (touch_start() == ESP_OK) {
        lv_indev_t *indev = lv_indev_create();
        lv_indev_set_type(indev, LV_INDEV_TYPE_POINTER);
        lv_indev_set_read_cb(indev, touch_read_cb);
        lv_indev_set_display(indev, disp);
    } else {
        // Без тача продавать нельзя, но и молча вставать смысла нет: экран
        // покажет телефон поддержки, а в логе будет причина.
        ESP_LOGE(TAG, "тач не поднялся — экран останется неинтерактивным");
    }

    xTaskCreatePinnedToCore(lvgl_task, "lvgl", 6144, NULL, 4, NULL, 1);
    ESP_LOGI(TAG, "LVGL запущена");
    return ESP_OK;
}
