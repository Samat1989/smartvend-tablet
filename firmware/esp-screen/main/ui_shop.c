#include "ui_shop.h"

#include <stdio.h>
#include <string.h>

#include "board.h"
#include "cart.h"
#include "catalog.h"
#include "display.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lock.h"
#include "lvgl.h"
#include "payment.h"
#include "ui_fonts.h"
#include "ui_setup.h"

static const char *TAG = "shop";

// Сброс по бездействию обязателен везде, кроме выдачи: иначе следующий
// покупатель получит чужую корзину и в лучшем случае удивится, а в худшем
// оплатит её.
#define IDLE_RESET_MS 60000
// Столько живёт экран QR. Ровно столько же держит заказ платёжный шлюз: не
// подтвердили за минуту — платёж возвращается сам. Показывать код дольше
// нечестно: покупатель будет платить по коду, который уже никто не примет.
#define QR_TIMEOUT_MS 60000
// Сколько ещё опрашиваем после нажатия «Отмена».
#define CANCEL_TAIL_US ((int64_t)15 * 1000 * 1000)

// Раскладка нумпада вынесена в константы: верхняя полоса (набор, название,
// цена) и сетка кнопок делят по высоте один экран, и подвинуть одно, забыв про
// другое, — значит наложить название на единицы.
#define NAME_Y      42                       // верх полосы названия
#define NAME_H      68                       // две строки шрифтом 28
#define NAME_W      (LCD_H_RES - 24)
#define PAD_TOP     160                      // верх сетки цифр
#define PAD_PITCH   60                       // шаг строк сетки
#define PAD_BTN_W   92
#define PAD_BTN_H   56

static char s_entry[3];          // набранные цифры номера ячейки
static lv_obj_t *s_entry_label;
static lv_obj_t *s_found_label;
static lv_obj_t *s_price_label;
static lv_obj_t *s_add_button;
static lv_obj_t *s_pay_button;
static lv_obj_t *s_cart_button;
static lv_timer_t *s_idle_timer;

// Кнопка оплаты гаснет, пока идёт опрос предыдущего заказа, и оживает, когда
// он закончился. Но заканчивается он в фоновой задаче, а на нумпаде некому
// пересчитать состояние — раньше кнопка так и оставалась серой, пока человек
// что-нибудь не нажмёт. Поэтому раз в секунду проверяем сами.
static lv_timer_t *s_pay_state_timer;
static lv_timer_t *s_countdown;

// Строки корзины держим по ссылке, чтобы нажатие ± меняло одну подпись, а не
// перестраивало экран целиком: перестройка заметна пальцем.
typedef struct {
    int cell;
    lv_obj_t *sum_label;
} cart_row_t;
static cart_row_t s_rows[CART_MAX_LINES];
static int s_row_count;
static lv_obj_t *s_total_label;
static int s_seconds_left;
static payment_t s_payment;
static lv_obj_t *s_qr_left_label;

// Идёт ли опрос оплаты. Отмена на экране QR платёж не отменяет — шлюз о ней не
// знает, — поэтому опрос продолжается в фоне, и если деньги пришли, товар
// выдаётся. Пока это так, вторую оплату начинать нельзя: получилось бы два
// заказа на одну корзину.
static bool s_polling;

// Отдельная защёлка на само оформление. s_polling поднимается уже внутри задачи
// опроса, и между нажатием «Оплатить» и её стартом оставалось окно: два быстрых
// нажатия заводили два заказа на одну корзину, то есть покупателя можно было
// списать дважды.
static bool s_checkout_busy;

// Заказ не создался. Шлюз иногда отвечает отказом («SmartVend: some error»), и
// раньше корзина просто возвращалась без объяснений — покупатель видел, что
// нажатие как будто не сработало, и жал снова.
static bool s_checkout_failed;

// Открыт ли сейчас экран корзины: после досинхронизации каталога его надо
// перерисовать, а нумпад — нет.
static bool s_cart_open;

// Когда последний раз подтягивали каталог ради покупателя, и не идёт ли
// подтяжка прямо сейчас.
static int64_t s_sync_at;
static bool s_syncing;

// Отмена на экране QR. Опрос после неё живёт недолго: если покупатель не
// сканировал код, ждать полную минуту незачем — он хочет пересобрать корзину.
static int64_t s_cancel_at;


static void show_numpad(void);
static void show_cart(void);
static void sync_catalog(void);
static void show_lock_failure(void);
static void forget_screen(void);
static void stop_countdown(void);
static void update_pay_state(void);
static void pay_state_tick(lv_timer_t *t);
static bool entry_is_buyable(void);
static void update_found(void);
static void update_cart_badge(void);

// Обратный отсчёт живёт на экране QR и на экране выдачи. Уходя с них, таймер
// надо снести: экран удаляется отложенно, а таймер продолжает тикать и пишет в
// подпись, которой уже нет. Именно так прошивка и падала при отмене оплаты.
// Уборка перед сменой экрана: гасим таймеры и забываем все указатели на
// элементы уходящего экрана.
//
// Экран удаляется отложенно, а таймеры и фоновые задачи продолжают работать —
// и лезут в объекты, которых уже нет. Так прошивка падала трижды: на отмене
// оплаты, на отказе замка и на «Очистить». Держать эту уборку в одном месте
// надёжнее, чем помнить о ней в каждом обработчике: следующий новый экран
// получит её даром.
static void forget_screen(void)
{
    if (s_countdown) {
        lv_timer_delete(s_countdown);
        s_countdown = NULL;
    }
    if (s_pay_state_timer) {
        lv_timer_delete(s_pay_state_timer);
        s_pay_state_timer = NULL;
    }

    s_qr_left_label = NULL;
    s_entry_label = NULL;
    s_found_label = NULL;
    s_price_label = NULL;
    s_add_button = NULL;
    s_pay_button = NULL;
    s_cart_button = NULL;
    s_total_label = NULL;
    s_row_count = 0;
}

static void stop_countdown(void)
{
    forget_screen();
}

// Каталог обновляется раз в пять минут по отпечатку, и этого хватает витрине.
// Но пока покупатель собирает корзину, цифра остатка должна совпадать с
// сервером: соседний покупатель или оператор могли забрать товар минуту назад,
// а «+» в корзине упрётся в устаревший предел. Поэтому в момент сборки тянем
// каталог отдельно, не чаще раза в полминуты.
#define SYNC_MIN_INTERVAL_US ((int64_t)30 * 1000 * 1000)

static void sync_task(void *arg)
{
    (void)arg;
    if (catalog_refresh(catalog_digest()) == ESP_OK) {
        display_lock(0);
        // Остаток мог уменьшиться — подрезаем корзину под новый предел, иначе
        // покупатель дойдёт до оплаты с количеством, которого нет на полке.
        for (int i = cart_lines() - 1; i >= 0; i--) {
            const cart_line_t *line = cart_line(i);
            catalog_item_t item;
            if (!catalog_get(line->cell, &item)) {
                cart_remove(line->cell);
            } else if (line->count > item.stock) {
                cart_set_count(line->cell, item.stock);
            }
        }
        if (s_cart_open) {
            show_cart();
        }
        display_unlock();
    }
    s_syncing = false;
    vTaskDelete(NULL);
}

// Просьба подтянуть каталог. Возвращается сразу: сеть живёт в своей задаче,
// иначе экран замрёт на время запроса.
static void sync_catalog(void)
{
    const int64_t now = esp_timer_get_time();
    if (s_syncing || (s_sync_at && now - s_sync_at < SYNC_MIN_INTERVAL_US)) {
        return;
    }
    s_sync_at = now;
    s_syncing = true;
    xTaskCreate(sync_task, "catsync", 12288, NULL, 3, NULL);
}

// ── бездействие ──────────────────────────────────────────────────────────────

static void idle_fired(lv_timer_t *t)
{
    (void)t;
    if (s_polling) {
        return;   // деньги в пути — гасить корзину нельзя
    }
    if (cart_is_empty() && s_entry[0] == 0) {
        return;
    }
    ESP_LOGI(TAG, "сброс по бездействию");
    cart_clear();
    show_numpad();
}

static void idle_kick(void)
{
    if (s_idle_timer) {
        lv_timer_reset(s_idle_timer);
    }
}

static void any_touch_cb(lv_event_t *e)
{
    (void)e;
    idle_kick();
}

static lv_obj_t *shop_screen(void)
{
    forget_screen();

    lv_obj_t *scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x0D1117), 0);
    lv_obj_set_style_pad_all(scr, 0, 0);
    lv_obj_set_style_border_width(scr, 0, 0);
    lv_obj_remove_flag(scr, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_event_cb(scr, any_touch_cb, LV_EVENT_PRESSED, NULL);
    return scr;
}

// ── выдача ───────────────────────────────────────────────────────────────────

static void dispense_tick(lv_timer_t *t)
{
    lv_obj_t *label = lv_timer_get_user_data(t);
    if (!label) {
        return;
    }
    if (--s_seconds_left <= 0) {
        cart_clear();
        show_numpad();   // сам снесёт этот таймер
        return;
    }
    lv_label_set_text_fmt(label, "Закроется через %d с", s_seconds_left);
}

static void show_dispense(void)
{
    lv_obj_t *scr = shop_screen();

    lv_obj_t *ok = lv_label_create(scr);
    lv_label_set_text(ok, "Оплачено");
    lv_obj_set_style_text_font(ok, &ui_font_40, 0);
    lv_obj_set_style_text_color(ok, lv_color_hex(0x30A46C), 0);
    lv_obj_align(ok, LV_ALIGN_CENTER, 0, -60);

    lv_obj_t *take = lv_label_create(scr);
    lv_label_set_text(take, "Заберите товар");
    lv_obj_set_style_text_color(take, lv_color_hex(0xE6EDF3), 0);
    lv_obj_align(take, LV_ALIGN_CENTER, 0, -10);

    lv_obj_t *left = lv_label_create(scr);
    lv_obj_set_style_text_color(left, lv_color_hex(0x8B949E), 0);
    lv_obj_align(left, LV_ALIGN_CENTER, 0, 30);
    lv_label_set_text(left, "");

    display_load_screen(scr);

    // На выдаче сброса по бездействию нет: человек стоит у открытой двери.
    s_seconds_left = LOCK_OPEN_SECONDS;
    s_countdown = lv_timer_create(dispense_tick, 1000, left);
}

// Оплата прошла, замок не сработал.
//
// Телефон поддержки на экране не пишем: он на наклейке холодильника, и держать
// его в двух местах — значит однажды сменить в одном. Экран не висит вечно:
// уйти можно кнопкой, а если человек ушёл сам — автомат вернётся к продаже по
// таймеру, иначе следующий покупатель упрётся в чужую беду.
#define LOCK_FAILURE_TIMEOUT_MS 120000

static void lock_failure_exit_cb(lv_event_t *e)
{
    (void)e;
    cart_clear();
    show_numpad();
}

static void lock_failure_timeout(lv_timer_t *t)
{
    (void)t;
    cart_clear();
    show_numpad();   // сам снесёт этот таймер
}

static void show_lock_failure(void)
{
    lv_obj_t *scr = shop_screen();

    lv_obj_t *title = lv_label_create(scr);
    lv_label_set_text(title, "Оплачено");
    lv_obj_set_style_text_font(title, &ui_font_40, 0);
    lv_obj_set_style_text_color(title, lv_color_hex(0x30A46C), 0);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 60);

    lv_obj_t *text = lv_label_create(scr);
    lv_label_set_text(text, "Дверь не открылась.\n\n"
                            "Позвоните в поддержку — телефон на наклейке "
                            "на холодильнике. Деньги вернут или товар выдадут.");
    lv_obj_set_style_text_color(text, lv_color_hex(0xE6EDF3), 0);
    lv_obj_set_style_text_align(text, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_width(text, LCD_H_RES - 40);
    lv_label_set_long_mode(text, LV_LABEL_LONG_WRAP);
    lv_obj_align(text, LV_ALIGN_CENTER, 0, -10);

    lv_obj_t *exit_btn = lv_button_create(scr);
    lv_obj_set_size(exit_btn, LCD_H_RES - 40, 56);
    lv_obj_align(exit_btn, LV_ALIGN_BOTTOM_MID, 0, -20);
    lv_obj_add_event_cb(exit_btn, lock_failure_exit_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *el = lv_label_create(exit_btn);
    lv_label_set_text(el, "На главный экран");
    lv_obj_center(el);

    display_load_screen(scr);
    ui_setup_attach_service_corner();
    s_countdown = lv_timer_create(lock_failure_timeout, LOCK_FAILURE_TIMEOUT_MS, NULL);
}

// ── QR ───────────────────────────────────────────────────────────────────────

// Опрос платежа блокирующий и долгий — только в своей задаче.
static void poll_task(void *arg)
{
    (void)arg;
    s_polling = true;
    ESP_LOGI(TAG, "опрос оплаты начат");
    char orderid[PAYMENT_ORDERID_LEN];
    strncpy(orderid, s_payment.orderid, sizeof(orderid) - 1);

    // Срок опроса задаём здесь, а не подписью на экране: покупатель может уйти
    // с экрана QR по отмене, и тогда обратный отсчёт сносится вместе с ним.
    // Раньше опрос из-за этого оставался без срока и крутился вечно — в
    // корзине навсегда застревало «проверяем оплату».
    const int64_t deadline = esp_timer_get_time() + (int64_t)QR_TIMEOUT_MS * 1000;
    s_cancel_at = 0;

    while (true) {
        const payment_state_t state = payment_poll(orderid);

        if (state == PAYMENT_PAID) {
            display_lock(0);
            show_dispense();
            display_unlock();

            // Замок открывается только здесь и только после 200 — не «увидели
            // оплату», а «сервер подтвердил в шлюзе и записал продажу».
            if (!lock_open()) {
                // Деньги списаны, а двери нет. Молчать нельзя: человек стоит и
                // не понимает, что произошло.
                ESP_LOGE(TAG, "ОПЛАЧЕНО, НО ЗАМОК НЕ ОТКРЫЛСЯ: заказ %s", orderid);
                display_lock(0);
                show_lock_failure();
                display_unlock();
            }
            s_polling = false;
            vTaskDelete(NULL);
            return;
        }

        // После отмены ждём недолго. Покупатель, который не сканировал код,
        // хочет собрать корзину заново, а не смотреть на «проверяем оплату»
        // целую минуту. Если он всё-таки успел заплатить в эти секунды —
        // деньги вернёт сам шлюз, он держит неподтверждённый платёж около
        // минуты. Это та же защита, что и в static-QR.
        const int64_t limit = s_cancel_at ? s_cancel_at + CANCEL_TAIL_US : deadline;
        if (state == PAYMENT_UNKNOWN || esp_timer_get_time() > limit) {
            s_polling = false;
            ESP_LOGI(TAG, "опрос оплаты закончен, интерфейс свободен");
            display_lock(0);
            // Состав корзины сохраняем: человек мог просто не успеть открыть
            // банковское приложение.
            show_cart();
            display_unlock();
            vTaskDelete(NULL);
            return;
        }

        // При 503 и сетевых ошибках просто повторяем: один вызов сам занимает
        // около двенадцати секунд, и этим задаёт ритм.
        vTaskDelay(pdMS_TO_TICKS(state == PAYMENT_ERROR ? 3000 : 200));
    }
}

static void qr_tick(lv_timer_t *t)
{
    (void)t;
    if (!s_qr_left_label) {
        return;
    }
    if (--s_seconds_left <= 0) {
        lv_label_set_text(s_qr_left_label, "Время оплаты истекло");
        return;
    }
    lv_label_set_text_fmt(s_qr_left_label, "%d с", s_seconds_left);
}

static void qr_cancel_cb(lv_event_t *e)
{
    (void)e;
    s_cancel_at = esp_timer_get_time();
    // Отмена гасит только экран. Заказ живёт своей жизнью: если покупатель уже
    // отсканировал код и заплатил, опрос это увидит и товар выдастся. Иначе
    // шлюз сам вернёт неподтверждённый платёж примерно через минуту.
    show_cart();
}

static void show_qr(void)
{
    lv_obj_t *scr = shop_screen();

    lv_obj_t *sum = lv_label_create(scr);
    lv_label_set_text_fmt(sum, "%d ₸", cart_total_price());
    lv_obj_set_style_text_font(sum, &ui_font_40, 0);
    lv_obj_set_style_text_color(sum, lv_color_hex(0xE6EDF3), 0);
    lv_obj_align(sum, LV_ALIGN_TOP_MID, 0, 12);

    lv_obj_t *qr = lv_qrcode_create(scr);
    lv_qrcode_set_size(qr, 200);
    lv_qrcode_set_dark_color(qr, lv_color_black());
    lv_qrcode_set_light_color(qr, lv_color_white());
    lv_qrcode_update(qr, s_payment.url, strlen(s_payment.url));
    lv_obj_align(qr, LV_ALIGN_TOP_MID, 0, 62);

    // Под кодом только отсчёт и короткое предупреждение. Подсказку
    // «отсканируйте телефоном» убрали намеренно: человек, подошедший к автомату
    // с QR на экране, и так знает, что с ним делать, а место под кодом дорогое —
    // три строки там налезали друг на друга.
    s_qr_left_label = lv_label_create(scr);
    lv_obj_set_style_text_font(s_qr_left_label, &ui_font_28, 0);
    lv_obj_set_style_text_color(s_qr_left_label, lv_color_hex(0xE6EDF3), 0);
    lv_obj_align(s_qr_left_label, LV_ALIGN_TOP_MID, 0, 274);

    lv_obj_t *warn = lv_label_create(scr);
    lv_label_set_text(warn, "Оплатили — не отменяйте");
    lv_obj_set_style_text_color(warn, lv_color_hex(0x8B949E), 0);
    lv_obj_align(warn, LV_ALIGN_TOP_MID, 0, 308);

    lv_obj_t *cancel = lv_button_create(scr);
    lv_obj_set_size(cancel, 200, 52);
    lv_obj_align(cancel, LV_ALIGN_BOTTOM_MID, 0, -18);
    lv_obj_add_event_cb(cancel, qr_cancel_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *cl = lv_label_create(cancel);
    lv_label_set_text(cl, "Отмена");
    lv_obj_center(cl);

    display_load_screen(scr);

    s_seconds_left = QR_TIMEOUT_MS / 1000;
    lv_label_set_text_fmt(s_qr_left_label, "%d с", s_seconds_left);
    s_countdown = lv_timer_create(qr_tick, 1000, NULL);
}

// Создание заказа ходит в сеть — своя задача, иначе экран замрёт на секунды.
static void checkout_task(void *arg)
{
    (void)arg;

    // Каталог перед оплатой нужен свежий: так закрывается сценарий «оператор
    // перевесил номер 15 с колы на шоколад», ради которого документ предлагал
    // принимать номер ячейки на сервере.
    //
    // Но тянуть его прямо здесь стоит только если он успел устареть. Покупатель
    // уже подтянул каталог, когда начинал собирать корзину, и повтор добавлял к
    // ожиданию целый TLS-обмен — на ESP это секунды, и человек смотрит на
    // спиннер вместо кода.
    const int64_t t0 = esp_timer_get_time();

    // Если загрузка каталога уже идёт — дожидаемся её, а не запускаем свою.
    // Набор номера и нажатие «Оплатить» разделяет доля секунды, и без этого обе
    // загрузки стартовали почти одновременно: покупатель ждал вторую, хотя
    // первая тянула ровно те же данные.
    //
    for (int i = 0; i < 50 && s_syncing; i++) {
        vTaskDelay(pdMS_TO_TICKS(100));
    }

    if (!s_sync_at || esp_timer_get_time() - s_sync_at > SYNC_MIN_INTERVAL_US) {
        catalog_refresh(catalog_digest());
        s_sync_at = esp_timer_get_time();
    }

    const int64_t t1 = esp_timer_get_time();
    const esp_err_t err = payment_create(&s_payment);
    ESP_LOGI(TAG, "оплата готова за %lld мс (каталог %lld, заказ %lld)",
             (long long)((esp_timer_get_time() - t0) / 1000),
             (long long)((t1 - t0) / 1000),
             (long long)((esp_timer_get_time() - t1) / 1000));

    display_lock(0);
    if (err == ESP_OK) {
        s_checkout_failed = false;
        show_qr();
        xTaskCreate(poll_task, "poll", 16384, NULL, 4, NULL);
    } else {
        s_checkout_failed = true;
        show_cart();
    }
    display_unlock();
    s_checkout_busy = false;
    vTaskDelete(NULL);
}

static void pay_cb(lv_event_t *e)
{
    (void)e;
    if (s_polling || s_checkout_busy) {
        return;
    }
    // «Оплатить» выставляет счёт на всё, что человек выбрал.
    //
    // Набранный на нумпаде товар пропадать не должен: он выбран так же явно,
    // как и те, что уже в корзине, — просто «+» нажать забыли. Поэтому он
    // добавляется сам, а потом счёт выставляется на всю корзину целиком.
    //
    // Если этот номер в корзине уже есть, второй штуки не добавляем: человек
    // набрал его, чтобы посмотреть, а не чтобы взять ещё одну.
    if (entry_is_buyable() && cart_count_of(atoi(s_entry)) == 0) {
        cart_add(atoi(s_entry));
        s_entry[0] = 0;
        update_found();
        update_cart_badge();
    }
    if (cart_is_empty()) {
        return;
    }
    s_checkout_busy = true;
    s_checkout_failed = false;

    lv_obj_t *scr = shop_screen();
    lv_obj_t *spinner = lv_spinner_create(scr);
    lv_obj_set_size(spinner, 64, 64);
    lv_obj_center(spinner);
    // Сумму показываем сразу: заказ в шлюзе создаётся несколько секунд, и всё
    // это время человеку нечего читать, кроме спиннера. Пусть видит, за что
    // платит, — ожидание то же, но пустым уже не выглядит.
    lv_obj_t *sum = lv_label_create(scr);
    lv_label_set_text_fmt(sum, "%d ₸", cart_total_price());
    lv_obj_set_style_text_font(sum, &ui_font_40, 0);
    lv_obj_set_style_text_color(sum, lv_color_hex(0xE6EDF3), 0);
    lv_obj_align(sum, LV_ALIGN_CENTER, 0, -80);

    lv_obj_t *label = lv_label_create(scr);
    lv_label_set_text(label, "Готовим оплату");
    lv_obj_set_style_text_color(label, lv_color_hex(0x8B949E), 0);
    lv_obj_align(label, LV_ALIGN_CENTER, 0, 60);
    display_load_screen(scr);

    xTaskCreate(checkout_task, "checkout", 16384, NULL, 4, NULL);
}

// ── корзина ──────────────────────────────────────────────────────────────────

// Обновить одну строку и итог. Возврат к полной перестройке нужен только
// когда строка исчезает — тогда меняется состав, а не числа.
static void refresh_line(int cell)
{
    catalog_item_t item;
    const bool known = catalog_get(cell, &item);
    const int count = cart_count_of(cell);
    for (int i = 0; i < s_row_count; i++) {
        if (s_rows[i].cell == cell && known) {
            lv_label_set_text_fmt(s_rows[i].sum_label, "%d × %d = %d ₸",
                                  count, item.price, count * item.price);
            break;
        }
    }
    if (s_total_label) {
        lv_label_set_text_fmt(s_total_label, "Итого %d ₸", cart_total_price());
    }
}

static void cart_plus_cb(lv_event_t *e)
{
    const int cell = (int)(intptr_t)lv_event_get_user_data(e);
    if (cart_add(cell)) {
        refresh_line(cell);
    }
    // Упёрлись в остаток — молча ничего не делаем: количество и так предельное,
    // и подпись под кнопкой это уже показывает.
}

static void cart_minus_cb(lv_event_t *e)
{
    const int cell = (int)(intptr_t)lv_event_get_user_data(e);
    const int next = cart_count_of(cell) - 1;
    cart_set_count(cell, next);
    if (next <= 0) {
        show_cart();   // строка ушла — состав изменился
        return;
    }
    refresh_line(cell);
}

static void cart_clear_cb(lv_event_t *e)
{
    (void)e;
    cart_clear();
    show_numpad();
}

static void cart_back_cb(lv_event_t *e)
{
    (void)e;
    show_numpad();
}

static void show_cart(void)
{
    if (cart_is_empty()) {
        show_numpad();
        return;
    }
    s_cart_open = true;

    lv_obj_t *scr = shop_screen();

    lv_obj_t *title = lv_label_create(scr);
    lv_label_set_text(title, "Корзина");
    lv_obj_set_style_text_color(title, lv_color_hex(0xE6EDF3), 0);
    lv_obj_align(title, LV_ALIGN_TOP_LEFT, 16, 14);

    // Прокрутка у списка нужна: строк может оказаться больше, чем влезает.
    // Мешала не она, а прокрутка внутри каждой строки — та отключается ниже.
    const int row_h = 48;
    const int list_h = 260;

    lv_obj_t *list = lv_obj_create(scr);
    lv_obj_set_size(list, LCD_H_RES - 24, list_h);
    lv_obj_align(list, LV_ALIGN_TOP_MID, 0, 44);
    lv_obj_set_style_bg_opa(list, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(list, 0, 0);
    lv_obj_set_style_pad_all(list, 0, 0);
    lv_obj_set_style_pad_row(list, 4, 0);
    lv_obj_set_flex_flow(list, LV_FLEX_FLOW_COLUMN);

    s_row_count = 0;
    for (int i = 0; i < cart_lines(); i++) {
        const cart_line_t *line = cart_line(i);
        catalog_item_t item;
        if (!catalog_get(line->cell, &item)) {
            continue;
        }

        lv_obj_t *row = lv_obj_create(list);
        lv_obj_set_size(row, LCD_H_RES - 44, row_h);
        // Строка — обычный контейнер, а он по умолчанию прокручивается сам:
        // палец сдвигал позицию внутри её же рамки вместо прокрутки списка.
        lv_obj_remove_flag(row, LV_OBJ_FLAG_SCROLLABLE);
        lv_obj_set_style_bg_color(row, lv_color_hex(0x161B22), 0);
        lv_obj_set_style_border_width(row, 0, 0);
        lv_obj_set_style_pad_all(row, 6, 0);

        lv_obj_t *name = lv_label_create(row);
        lv_label_set_text_fmt(name, "%d  %s", item.cell, item.name);
        lv_obj_set_style_text_color(name, lv_color_hex(0xE6EDF3), 0);
        lv_obj_align(name, LV_ALIGN_LEFT_MID, 0, -12);

        lv_obj_t *sum = lv_label_create(row);
        lv_label_set_text_fmt(sum, "%d × %d = %d ₸", line->count, item.price,
                              line->count * item.price);
        lv_obj_set_style_text_color(sum, lv_color_hex(0x8B949E), 0);
        lv_obj_align(sum, LV_ALIGN_LEFT_MID, 0, 12);
        s_rows[s_row_count++] = (cart_row_t){ .cell = line->cell, .sum_label = sum };

        // Изменить количество и удалить строку обязательно: без этого
        // случайное нажатие заставляет начинать всё заново.
        lv_obj_t *minus = lv_button_create(row);
        lv_obj_set_size(minus, 40, 40);
        lv_obj_align(minus, LV_ALIGN_RIGHT_MID, -46, 0);
        lv_obj_add_event_cb(minus, cart_minus_cb, LV_EVENT_CLICKED, (void *)(intptr_t)line->cell);
        lv_obj_t *ml = lv_label_create(minus);
        lv_label_set_text(ml, LV_SYMBOL_MINUS);
        lv_obj_center(ml);

        lv_obj_t *plus = lv_button_create(row);
        lv_obj_set_size(plus, 40, 40);
        lv_obj_align(plus, LV_ALIGN_RIGHT_MID, 0, 0);
        lv_obj_add_event_cb(plus, cart_plus_cb, LV_EVENT_CLICKED, (void *)(intptr_t)line->cell);
        lv_obj_t *pl = lv_label_create(plus);
        lv_label_set_text(pl, LV_SYMBOL_PLUS);
        lv_obj_center(pl);
    }

    s_total_label = lv_label_create(scr);
    lv_label_set_text_fmt(s_total_label, "Итого %d ₸", cart_total_price());
    lv_obj_set_style_text_font(s_total_label, &ui_font_40, 0);
    lv_obj_set_style_text_color(s_total_label, lv_color_hex(0xE6EDF3), 0);
    lv_obj_align(s_total_label, LV_ALIGN_TOP_MID, 0, 306);

    if (s_polling) {
        // Экран корзины перерисует сама задача опроса, когда закончит: она
        // зовёт show_cart() на выходе. Отдельный таймер тут не нужен.
        //
        // Опрос ещё идёт: показывать кнопку оплаты нельзя, иначе на одну
        // корзину заведётся второй заказ. И покупателю надо сказать, что
        // уходить рано — товар выдастся сам.
        lv_obj_t *wait = lv_label_create(scr);
        lv_label_set_text(wait, "Проверяем оплату. Если вы уже заплатили, "
                                "подождите — товар выдастся сам");
        lv_obj_set_style_text_color(wait, lv_color_hex(0xD29922), 0);
        lv_obj_set_style_text_align(wait, LV_TEXT_ALIGN_CENTER, 0);
        // Ширину задаём и переносим по словам: без этого длинная строка уезжает
        // за края экрана и обрывается на полуслове.
        lv_obj_set_width(wait, LCD_H_RES - 40);
        lv_label_set_long_mode(wait, LV_LABEL_LONG_WRAP);
        lv_obj_align(wait, LV_ALIGN_BOTTOM_MID, 0, -66);
    } else {
        if (s_checkout_failed) {
            lv_obj_t *failed = lv_label_create(scr);
            lv_label_set_text(failed, "Не удалось создать заказ. Попробуйте ещё раз");
            lv_obj_set_style_text_color(failed, lv_color_hex(0xE5484D), 0);
            lv_obj_set_style_text_align(failed, LV_TEXT_ALIGN_CENTER, 0);
            lv_obj_set_width(failed, LCD_H_RES - 40);
            lv_label_set_long_mode(failed, LV_LABEL_LONG_WRAP);
            lv_obj_align(failed, LV_ALIGN_BOTTOM_MID, 0, -132);
        }

        lv_obj_t *pay = lv_button_create(scr);
        lv_obj_set_size(pay, LCD_H_RES - 40, 56);
        lv_obj_align(pay, LV_ALIGN_BOTTOM_MID, 0, -70);
        lv_obj_set_style_bg_color(pay, lv_color_hex(0x2DA44E), 0);
        lv_obj_add_event_cb(pay, pay_cb, LV_EVENT_CLICKED, NULL);
        lv_obj_t *pl = lv_label_create(pay);
        lv_label_set_text(pl, "Оплатить");
        lv_obj_center(pl);
    }

    lv_obj_t *back = lv_button_create(scr);
    lv_obj_set_size(back, 132, 44);
    lv_obj_align(back, LV_ALIGN_BOTTOM_LEFT, 16, -16);
    lv_obj_add_event_cb(back, cart_back_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *bl = lv_label_create(back);
    lv_label_set_text(bl, "Назад");
    lv_obj_center(bl);

    lv_obj_t *clear = lv_button_create(scr);
    lv_obj_set_size(clear, 132, 44);
    lv_obj_align(clear, LV_ALIGN_BOTTOM_RIGHT, -16, -16);
    lv_obj_add_event_cb(clear, cart_clear_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *cl = lv_label_create(clear);
    lv_label_set_text(cl, "Очистить");
    lv_obj_center(cl);

    display_load_screen(scr);
}

// ── нумпад ───────────────────────────────────────────────────────────────────

// Есть ли под набранным номером товар, который можно взять. По этому же
// признаку оживает кнопка оплаты: покупателю с одним товаром не нужно сначала
// класть его в корзину.
static bool entry_is_buyable(void)
{
    if (strlen(s_entry) < 2) {
        return false;
    }
    catalog_item_t item;
    return catalog_get(atoi(s_entry), &item) && item.stock > 0;
}

// Название товара — крупно, если помещается в строку, и обычным шрифтом в две
// строки, если нет. Раньше шрифт был один и длинное название всегда резалось
// многоточием; теперь «Вода 0,5» видно от кассы, а «Морс клюквенный
// облепиховый» читается целиком.
static void set_name_text(const char *txt)
{
    lv_point_t sz;
    lv_text_get_size(&sz, txt, &ui_font_40, 0, 0, LV_COORD_MAX, LV_TEXT_FLAG_NONE);
    const bool big = sz.x <= NAME_W;
    lv_obj_set_style_text_font(s_found_label, big ? &ui_font_40 : &ui_font_28, 0);
    // Одну строку центрируем в полосе, двум она и так впору.
    lv_obj_align(s_found_label, LV_ALIGN_TOP_MID, 0,
                 big ? NAME_Y + (NAME_H - 49) / 2 : NAME_Y);
    lv_label_set_text(s_found_label, txt);
}

static void update_found(void)
{
    if (!s_found_label) {
        return;   // нумпада на экране нет, подписи уже удалены
    }
    const int len = (int)strlen(s_entry);
    lv_label_set_text(s_entry_label, len ? s_entry : "__");
    lv_label_set_text(s_price_label, "");

    if (len < 2) {
        set_name_text("Наберите номер ячейки");
        lv_obj_set_style_text_color(s_found_label, lv_color_hex(0x8B949E), 0);
        lv_obj_add_state(s_add_button, LV_STATE_DISABLED);
        update_pay_state();
        return;
    }

    const int cell = atoi(s_entry);
    catalog_item_t item;
    if (!catalog_get(cell, &item)) {
        // Молчать нельзя: покупатель не поймёт, стирать ему или нет.
        set_name_text("Нет такого номера");
        lv_obj_set_style_text_color(s_found_label, lv_color_hex(0xE5484D), 0);
        lv_obj_add_state(s_add_button, LV_STATE_DISABLED);
        update_pay_state();
        return;
    }

    set_name_text(item.name);
    if (item.stock <= 0) {
        // Товар видно на полке — отказывать молча тем более нельзя.
        lv_obj_set_style_text_color(s_found_label, lv_color_hex(0x8B949E), 0);
        lv_label_set_text(s_price_label, "нет в наличии");
        lv_obj_set_style_text_color(s_price_label, lv_color_hex(0xE5484D), 0);
        lv_obj_add_state(s_add_button, LV_STATE_DISABLED);
        update_pay_state();
        return;
    }

    lv_obj_set_style_text_color(s_found_label, lv_color_hex(0xE6EDF3), 0);
    lv_label_set_text_fmt(s_price_label, "%d ₸", item.price);
    lv_obj_set_style_text_color(s_price_label, lv_color_hex(0x2DA44E), 0);
    lv_obj_remove_state(s_add_button, LV_STATE_DISABLED);
    update_pay_state();

    // Товар найден — значит покупка вот-вот начнётся. Подтягиваем каталог
    // сейчас, пока человек читает название и тянется к кнопке: к моменту
    // «Оплатить» он будет свежим, и эти секунды не лягут в ожидание кода.
    // Внутри стоит ограничение — не чаще раза в полминуты.
    sync_catalog();
}

static void pay_state_tick(lv_timer_t *t)
{
    (void)t;
    update_pay_state();
}

static void update_pay_state(void)
{
    if (!s_pay_button) {
        return;
    }
    // Платить можно, когда есть корзина или набран доступный товар, и нельзя,
    // пока идёт опрос предыдущего заказа.
    const bool can = (!cart_is_empty() || entry_is_buyable()) && !s_polling && !s_checkout_busy;
    if (can) {
        lv_obj_remove_state(s_pay_button, LV_STATE_DISABLED);
    } else {
        lv_obj_add_state(s_pay_button, LV_STATE_DISABLED);
    }
}

static void update_cart_badge(void)
{
    if (!s_cart_button) {
        return;
    }
    lv_obj_t *label = lv_obj_get_child(s_cart_button, 0);
    if (cart_is_empty()) {
        // Пустая корзина — клавиша гаснет: нажимать её не на что, а серый вид
        // сразу говорит, что в корзине ничего нет.
        lv_label_set_text(label, UI_SYMBOL_CART);
        lv_obj_add_state(s_cart_button, LV_STATE_DISABLED);
    } else {
        lv_label_set_text_fmt(label, UI_SYMBOL_CART "%d", cart_total_items());
        lv_obj_remove_state(s_cart_button, LV_STATE_DISABLED);
    }

    update_pay_state();
}

static void digit_cb(lv_event_t *e)
{
    const int digit = (int)(intptr_t)lv_event_get_user_data(e);
    const size_t len = strlen(s_entry);
    if (len >= 2) {
        s_entry[0] = 0;
    }
    const size_t pos = strlen(s_entry);
    s_entry[pos] = (char)('0' + digit);
    s_entry[pos + 1] = 0;
    // Длина номера фиксированная, две цифры: поиск запускается сам после
    // второй, и кнопка «ОК» не нужна — на одно нажатие меньше в самом частом
    // действии.
    update_found();
}

static void backspace_cb(lv_event_t *e)
{
    (void)e;
    // Стираем по одной цифре, а не всё поле: ошибся во второй — поправил
    // вторую, а не набирай номер заново.
    const size_t len = strlen(s_entry);
    if (len) {
        s_entry[len - 1] = 0;
    }
    update_found();
}

static void add_cb(lv_event_t *e)
{
    (void)e;
    const int cell = atoi(s_entry);
    if (!cart_add(cell)) {
        set_name_text("Больше нет в наличии");
        return;
    }
    sync_catalog();   // покупатель начал собирать — сверимся с сервером
    s_entry[0] = 0;
    update_found();
    update_cart_badge();
}

static void open_cart_cb(lv_event_t *e)
{
    (void)e;
    if (!cart_is_empty()) {
        sync_catalog();
        show_cart();
    }
}

static void show_numpad(void)
{
    s_cart_open = false;
    lv_obj_t *scr = shop_screen();
    s_entry[0] = 0;

    // Набранные цифры — мелко: их подтверждает название товара строкой ниже,
    // а сами кнопки с цифрами и так крупные и в поле зрения.
    s_entry_label = lv_label_create(scr);
    lv_obj_set_style_text_font(s_entry_label, &ui_font_28, 0);
    lv_obj_set_style_text_color(s_entry_label, lv_color_hex(0x8B949E), 0);
    lv_obj_align(s_entry_label, LV_ALIGN_TOP_MID, 0, 6);

    // Название и цена — двумя строками, а не одной.
    //
    // Раньше они шли вместе («Coca-cola — 450 ₸») и длинное название утаскивало
    // цену за край экрана. Теперь название живёт в своей строке и при нехватке
    // места обрезается многоточием, а цена всегда на своём месте и крупная:
    // это второе, на что смотрит покупатель после названия.
    //
    // Полоса под название — во всю ширину экрана: значка корзины в правом углу
    // больше нет (он переехал в пустую клетку нумпада), и длинное название
    // никуда не упирается. Размер шрифта подбирается в set_name_text().
    s_found_label = lv_label_create(scr);
    lv_obj_set_style_text_font(s_found_label, &ui_font_28, 0);
    lv_obj_set_style_text_color(s_found_label, lv_color_hex(0xE6EDF3), 0);
    lv_label_set_long_mode(s_found_label, LV_LABEL_LONG_DOT);
    lv_obj_set_size(s_found_label, NAME_W, NAME_H);
    lv_obj_set_style_text_align(s_found_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(s_found_label, LV_ALIGN_TOP_MID, 0, NAME_Y);

    s_price_label = lv_label_create(scr);
    lv_obj_set_style_text_font(s_price_label, &ui_font_40, 0);
    lv_obj_set_style_text_color(s_price_label, lv_color_hex(0x2DA44E), 0);
    lv_obj_align(s_price_label, LV_ALIGN_TOP_MID, 0, NAME_Y + NAME_H);

    // Сетка 3×4. Нижний ряд: корзина, ноль, стереть — как на телефонной
    // клавиатуре, где backspace всегда справа от нуля. Корзина заняла клетку,
    // которая раньше пустовала: наверху она отъедала место у названия товара, а
    // здесь стоит там, куда и так тянется палец.
    static const char *keys[12] = { "1", "2", "3", "4", "5", "6",
                                    "7", "8", "9", NULL, "0", LV_SYMBOL_BACKSPACE };
    for (int i = 0; i < 12; i++) {
        lv_obj_t *btn = lv_button_create(scr);
        lv_obj_set_size(btn, PAD_BTN_W, PAD_BTN_H);
        lv_obj_align(btn, LV_ALIGN_TOP_LEFT, 12 + (i % 3) * 100,
                     PAD_TOP + (i / 3) * PAD_PITCH);
        if (!keys[i]) {
            s_cart_button = btn;
            lv_obj_set_style_bg_color(btn, lv_color_hex(0x21262D), 0);
            lv_obj_add_event_cb(btn, open_cart_cb, LV_EVENT_CLICKED, NULL);
            lv_obj_t *badge = lv_label_create(btn);
            lv_obj_set_style_text_font(badge, &ui_font_28, 0);
            lv_obj_center(badge);
            continue;
        }
        lv_obj_set_style_bg_color(btn, lv_color_hex(0x161B22), 0);
        lv_obj_t *l = lv_label_create(btn);
        lv_label_set_text(l, keys[i]);
        lv_obj_set_style_text_font(l, &ui_font_40, 0);
        lv_obj_center(l);

        const bool is_digit = keys[i][0] >= '0' && keys[i][0] <= '9';
        if (is_digit) {
            lv_obj_add_event_cb(btn, digit_cb, LV_EVENT_CLICKED,
                                (void *)(intptr_t)(keys[i][0] - '0'));
        } else {
            lv_obj_add_event_cb(btn, backspace_cb, LV_EVENT_CLICKED, NULL);
        }
    }

    // Две кнопки вместо одной: добавить и сразу оплатить. Покупателю с одним
    // товаром больше не нужно заходить в корзину — это самый частый случай.
    s_add_button = lv_button_create(scr);
    lv_obj_set_size(s_add_button, (LCD_H_RES - 36) / 2, 56);
    lv_obj_align(s_add_button, LV_ALIGN_BOTTOM_LEFT, 12, -12);
    lv_obj_set_style_bg_color(s_add_button, lv_color_hex(0x2DA44E), 0);
    lv_obj_add_event_cb(s_add_button, add_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *al = lv_label_create(s_add_button);
    lv_label_set_text(al, LV_SYMBOL_PLUS " " UI_SYMBOL_CART);
    lv_obj_center(al);

    s_pay_button = lv_button_create(scr);
    lv_obj_set_size(s_pay_button, (LCD_H_RES - 36) / 2, 56);
    lv_obj_align(s_pay_button, LV_ALIGN_BOTTOM_RIGHT, -12, -12);
    lv_obj_set_style_bg_color(s_pay_button, lv_color_hex(0x2DA44E), 0);
    lv_obj_add_event_cb(s_pay_button, pay_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *pl = lv_label_create(s_pay_button);
    lv_label_set_text(pl, "Оплатить");
    lv_obj_center(pl);

    display_load_screen(scr);
    update_found();
    update_cart_badge();
    ui_setup_attach_service_corner();

    if (!s_pay_state_timer) {
        s_pay_state_timer = lv_timer_create(pay_state_tick, 1000, NULL);
    }
}

void ui_shop_start(void)
{
    lock_init();
    if (!s_idle_timer) {
        s_idle_timer = lv_timer_create(idle_fired, IDLE_RESET_MS, NULL);
    }
    show_numpad();
}

void ui_shop_catalog_changed(void)
{
    // Пока покупатель набирает или держит корзину, витрину не трогаем: под
    // руками ничего меняться не должно.
    if (!cart_is_empty() || s_entry[0] != 0) {
        return;
    }
    if (display_lock(200)) {
        show_numpad();
        display_unlock();
    }
}
