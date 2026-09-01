#include "ui_setup.h"

#include <stdio.h>
#include <string.h>

#include "board.h"
#include "cfg.h"
#include "cloud.h"
#include "display.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "net.h"
#include "ui_fonts.h"

static const char *TAG = "setup";

#define SERVICE_HOLD_MS 5000

static char s_ssid[NET_SSID_LEN];
static char s_pass[65];

static void show_networks(void);

// ── общие мелочи оформления ──────────────────────────────────────────────────

static lv_obj_t *fresh_screen(const char *title, const char *hint)
{
    lv_obj_t *scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x101418), 0);
    lv_obj_set_style_pad_all(scr, 0, 0);
    lv_obj_set_style_border_width(scr, 0, 0);

    lv_obj_t *t = lv_label_create(scr);
    lv_label_set_text(t, title);
    lv_obj_set_style_text_color(t, lv_color_hex(0xE6EDF3), 0);
    lv_obj_align(t, LV_ALIGN_TOP_LEFT, 16, 14);

    if (hint) {
        lv_obj_t *h = lv_label_create(scr);
        lv_label_set_text(h, hint);
        lv_obj_set_style_text_color(h, lv_color_hex(0x8B949E), 0);
        lv_label_set_long_mode(h, LV_LABEL_LONG_WRAP);
        lv_obj_set_width(h, LCD_H_RES - 32);
        lv_obj_align(h, LV_ALIGN_TOP_LEFT, 16, 36);
    }

    display_load_screen(scr);
    return scr;
}

// Экран занятости: пока идёт сеть, монтажник должен видеть, что происходит, а
// не гадать, приняло ли нажатие.
static lv_obj_t *s_status_label;

static void show_progress(const char *what)
{
    lv_obj_t *scr = fresh_screen("Настройка", NULL);
    lv_obj_t *spinner = lv_spinner_create(scr);
    lv_obj_set_size(spinner, 64, 64);
    lv_obj_align(spinner, LV_ALIGN_CENTER, 0, -30);

    s_status_label = lv_label_create(scr);
    lv_label_set_text(s_status_label, what);
    lv_obj_set_style_text_color(s_status_label, lv_color_hex(0xE6EDF3), 0);
    lv_obj_align(s_status_label, LV_ALIGN_CENTER, 0, 30);
}

static void show_result(const char *title, const char *detail, bool ok)
{
    lv_obj_t *scr = fresh_screen(title, detail);
    lv_obj_t *mark = lv_label_create(scr);
    lv_label_set_text(mark, ok ? LV_SYMBOL_OK : LV_SYMBOL_WARNING);
    lv_obj_set_style_text_color(mark, lv_color_hex(ok ? 0x30A46C : 0xE5484D), 0);
    lv_obj_set_style_text_font(mark, &ui_font_40, 0);
    lv_obj_align(mark, LV_ALIGN_CENTER, 0, -20);

    if (!ok) {
        lv_obj_t *again = lv_button_create(scr);
        lv_obj_set_size(again, 200, 48);
        lv_obj_align(again, LV_ALIGN_BOTTOM_MID, 0, -24);
        lv_obj_t *l = lv_label_create(again);
        lv_label_set_text(l, "Сначала");
        lv_obj_center(l);
        lv_obj_add_event_cb(again, (lv_event_cb_t)show_networks, LV_EVENT_CLICKED, NULL);
    }
}

// ── шаг 3: номер аппарата и привязка ─────────────────────────────────────────

// Привязка ходит в сеть, поэтому живёт в своей задаче: держать задачу LVGL
// на пятнадцатисекундном HTTP нельзя, иначе экран замрёт вместе со спиннером.
static void pair_task(void *arg)
{
    char *machid = arg;

    display_lock(0);
    show_progress("Подключаемся к сети");
    display_unlock();

    if (net_connect(s_ssid, s_pass, 20000) != ESP_OK) {
        display_lock(0);
        show_result("Сеть не отвечает", "Проверьте пароль и уровень сигнала.", false);
        display_unlock();
        free(machid);
        vTaskDelete(NULL);
        return;
    }
    cfg_set("ssid", s_ssid);
    cfg_set("pass", s_pass);

    display_lock(0);
    lv_label_set_text(s_status_label, "Привязываем аппарат");
    display_unlock();

    const pair_result_t res = cloud_pair(machid);

    display_lock(0);
    switch (res) {
    case PAIR_OK:
        show_result("Готово", "Аппарат привязан. Каталог задаётся в панели владельца.", true);
        break;
    case PAIR_NOT_FOUND:
        show_result("Номер не найден", "Такого аппарата нет в списке SmartVend. Проверьте номер.", false);
        break;
    case PAIR_WRONG_KIND:
        show_result("Не тот тип машины", "Этот аппарат заведён не как микромаркет с экраном. Поменяйте тип в панели.", false);
        break;
    case PAIR_TAKEN:
        show_result("Аппарат занят", "Его держит другое устройство. Отвяжите в панели владельца.", false);
        break;
    case PAIR_NETWORK:
    default:
        show_result("Сервер не ответил", "Сеть есть, но Supabase недоступен. Повторите позже.", false);
        break;
    }
    display_unlock();

    free(machid);
    vTaskDelete(NULL);
}

static void machid_ready_cb(lv_event_t *e)
{
    lv_obj_t *ta = lv_event_get_user_data(e);
    const char *text = lv_textarea_get_text(ta);
    if (!text || text[0] == 0) {
        return;
    }
    char *machid = strdup(text);
    // 12 КБ стека: рукопожатие TLS с Supabase съедает около восьми, и на
    // шести задача падает молча — плата перезагружается, мастер начинается
    // заново, и со стороны это выглядит как бесконечный цикл поиска сети.
    xTaskCreate(pair_task, "pair", 12288, machid, 4, NULL);
}

static void show_machid(void)
{
    lv_obj_t *scr = fresh_screen("Номер аппарата", "Внутренний номер SmartVend. Секрет подтянется сам.");

    lv_obj_t *ta = lv_textarea_create(scr);
    lv_textarea_set_one_line(ta, true);
    lv_textarea_set_accepted_chars(ta, "0123456789");
    lv_textarea_set_max_length(ta, 12);
    lv_obj_set_width(ta, LCD_H_RES - 32);
    lv_obj_align(ta, LV_ALIGN_TOP_MID, 0, 70);

    lv_obj_t *kb = lv_keyboard_create(scr);
    lv_keyboard_set_mode(kb, LV_KEYBOARD_MODE_NUMBER);
    lv_keyboard_set_textarea(kb, ta);
    lv_obj_set_size(kb, LCD_H_RES, 210);
    lv_obj_align(kb, LV_ALIGN_BOTTOM_MID, 0, 0);
    lv_obj_add_event_cb(kb, machid_ready_cb, LV_EVENT_READY, ta);
}

// ── шаг 2: пароль ────────────────────────────────────────────────────────────

static void pass_ready_cb(lv_event_t *e)
{
    lv_obj_t *ta = lv_event_get_user_data(e);
    strncpy(s_pass, lv_textarea_get_text(ta), sizeof(s_pass) - 1);
    show_machid();
}

static void show_password(void)
{
    lv_obj_t *scr = fresh_screen(s_ssid, "Пароль сети");

    lv_obj_t *ta = lv_textarea_create(scr);
    lv_textarea_set_one_line(ta, true);
    lv_textarea_set_password_mode(ta, false);   // монтажнику важнее видеть, что набрал
    lv_obj_set_width(ta, LCD_H_RES - 32);
    lv_obj_align(ta, LV_ALIGN_TOP_MID, 0, 70);

    lv_obj_t *kb = lv_keyboard_create(scr);
    lv_keyboard_set_textarea(kb, ta);
    lv_obj_set_size(kb, LCD_H_RES, 210);
    lv_obj_align(kb, LV_ALIGN_BOTTOM_MID, 0, 0);
    lv_obj_add_event_cb(kb, pass_ready_cb, LV_EVENT_READY, ta);
}

// ── шаг 1: список сетей ──────────────────────────────────────────────────────

static void ap_chosen_cb(lv_event_t *e)
{
    lv_obj_t *btn = lv_event_get_target(e);
    strncpy(s_ssid, lv_list_get_button_text(lv_obj_get_parent(btn), btn), sizeof(s_ssid) - 1);
    s_pass[0] = 0;
    show_password();
}

// Скан занимает несколько секунд и блокирует — своя задача, чтобы экран жил.
static void scan_task(void *arg)
{
    (void)arg;
    static net_ap_t aps[NET_MAX_SCAN];
    const int found = net_scan(aps, NET_MAX_SCAN);

    display_lock(0);
    lv_obj_t *scr = fresh_screen("Выберите сеть", found ? NULL : "Сетей не видно. Проверьте, что точка рядом.");
    lv_obj_t *list = lv_list_create(scr);
    lv_obj_set_size(list, LCD_H_RES - 24, LCD_V_RES - 90);
    lv_obj_align(list, LV_ALIGN_BOTTOM_MID, 0, -12);

    for (int i = 0; i < found; i++) {
        lv_obj_t *btn = lv_list_add_button(list, aps[i].secured ? LV_SYMBOL_WIFI : LV_SYMBOL_EYE_OPEN,
                                           aps[i].ssid);
        lv_obj_add_event_cb(btn, ap_chosen_cb, LV_EVENT_CLICKED, NULL);
    }
    display_unlock();

    ESP_LOGI(TAG, "найдено сетей: %d", found);
    vTaskDelete(NULL);
}

static void show_networks(void)
{
    show_progress("Ищем сети");
    xTaskCreate(scan_task, "scan", 4096, NULL, 4, NULL);
}

void ui_setup_show(void)
{
    show_networks();
}

// ── вход в сервис ────────────────────────────────────────────────────────────

static void service_cancel_cb(lv_event_t *e)
{
    (void)e;
    // Возвращаться некуда: экран покупки построит тот, кто нас позвал.
    extern void ui_shop_start(void);
    ui_shop_start();
}

static void service_repair_cb(lv_event_t *e)
{
    (void)e;
    ui_setup_show();
}

// Спрашиваем до того, как что-то менять: удержание угла — жест неочевидный, и
// попасть в него случайно всё-таки можно. Привязка при этом не стирается: её
// перезапишет только успешное завершение мастера.
static void show_service_menu(void)
{
    lv_obj_t *scr = fresh_screen("Сервис", "Аппарат уже привязан. Перепривязка нужна, "
                                           "если сменилась сеть или номер аппарата.");

    lv_obj_t *repair = lv_button_create(scr);
    lv_obj_set_size(repair, LCD_H_RES - 40, 56);
    lv_obj_align(repair, LV_ALIGN_CENTER, 0, 0);
    lv_obj_add_event_cb(repair, service_repair_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *rl = lv_label_create(repair);
    lv_label_set_text(rl, "Перепривязать");
    lv_obj_center(rl);

    lv_obj_t *cancel = lv_button_create(scr);
    lv_obj_set_size(cancel, LCD_H_RES - 40, 56);
    lv_obj_align(cancel, LV_ALIGN_CENTER, 0, 70);
    lv_obj_add_event_cb(cancel, service_cancel_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *cl = lv_label_create(cancel);
    lv_label_set_text(cl, "Назад к покупке");
    lv_obj_center(cl);
}

static void corner_cb(lv_event_t *e)
{
    static uint32_t pressed_at;
    const lv_event_code_t code = lv_event_get_code(e);

    // Разбираем ровно три события. Раньше здесь был общий else, который
    // обнулял отсчёт, — а подписка идёт на LV_EVENT_ALL, куда попадают и
    // служебные события вроде отрисовки. Они приходят постоянно, поэтому
    // удержание сбрасывалось на первом же кадре и в сервис было не попасть.
    switch (code) {
    case LV_EVENT_PRESSED:
        pressed_at = lv_tick_get();
        ESP_LOGI(TAG, "касание сервисной зоны");
        break;
    case LV_EVENT_PRESSING:
        if (pressed_at && lv_tick_elaps(pressed_at) > SERVICE_HOLD_MS) {
            pressed_at = 0;
            ESP_LOGI(TAG, "сервисный вход по удержанию угла");
            show_service_menu();
        }
        break;
    case LV_EVENT_RELEASED:
    case LV_EVENT_PRESS_LOST:
        pressed_at = 0;
        break;
    default:
        break;
    }
}

void ui_setup_attach_service_corner(void)
{
    // Сервисная зона в левом верхнем углу. Не невидимая, а еле заметная:
    // совсем скрытую невозможно нащупать даже тому, кто про неё знает, а
    // бледная шестерёнка покупателю ни о чём не говорит и нажать её случайно
    // нельзя — нужно удержание в пять секунд.
    //
    // Внизу зону держать нельзя: там кнопка «В корзину» во всю ширину, и она
    // забирает касания на себя.
    lv_obj_t *corner = lv_obj_create(lv_screen_active());
    lv_obj_set_size(corner, 80, 80);
    lv_obj_align(corner, LV_ALIGN_TOP_LEFT, 0, 0);
    lv_obj_set_style_bg_opa(corner, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(corner, 0, 0);
    lv_obj_set_style_pad_all(corner, 0, 0);
    lv_obj_add_flag(corner, LV_OBJ_FLAG_CLICKABLE);
    // Прокрутку выключаем и у зоны, и у экрана: удержание пальца LVGL иначе
    // принимает за начало жеста прокрутки и присылает PRESS_LOST, обрывая
    // отсчёт.
    lv_obj_remove_flag(corner, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(lv_screen_active(), LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_move_foreground(corner);

    lv_obj_t *gear = lv_label_create(corner);
    lv_label_set_text(gear, LV_SYMBOL_SETTINGS);
    lv_obj_set_style_text_color(gear, lv_color_hex(0x30363D), 0);
    lv_obj_align(gear, LV_ALIGN_TOP_LEFT, 10, 10);
    lv_obj_remove_flag(gear, LV_OBJ_FLAG_CLICKABLE);

    lv_obj_add_event_cb(corner, corner_cb, LV_EVENT_ALL, NULL);
}
