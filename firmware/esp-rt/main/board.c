#include "board.h"

#include "config.h"
#include "driver/gpio.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "board";

static void out_pin(int gpio) {
    gpio_config_t io = {
        .pin_bit_mask = 1ULL << gpio,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&io);
}

// ============================ Lock ============================
#if CONFIG_ESPRT_LOCK_RELAY
// Bistable relay: DIR (IO2) chooses the direction, a short pulse on IO16 moves
// the contact, and it then holds on its own — across resets too, which is why
// lock_init() latches it closed on every boot.
static void relay_latch(int dir) {
    gpio_set_level(LOCK_GPIO, dir);            vTaskDelay(pdMS_TO_TICKS(RELAY_SETTLE_MS));
    gpio_set_level(RELAY_PULSE_GPIO, 1);       vTaskDelay(pdMS_TO_TICKS(RELAY_PULSE_MS));
    gpio_set_level(RELAY_PULSE_GPIO, 0);       vTaskDelay(pdMS_TO_TICKS(RELAY_SETTLE_MS));
    gpio_set_level(LOCK_GPIO, 0);
}

void lock_init(void) {
    out_pin(LOCK_GPIO);
    out_pin(RELAY_PULSE_GPIO);
    gpio_set_level(LOCK_GPIO, 0);
    gpio_set_level(RELAY_PULSE_GPIO, 0);
    relay_latch(0);
    ESP_LOGI(TAG, "lock (relay IO%d/IO%d) latched CLOSED", LOCK_GPIO, RELAY_PULSE_GPIO);
}
void lock_open(void)  { relay_latch(1); }
void lock_close(void) { relay_latch(0); }
#else
// Single output held at LOCK_ACTIVE_LEVEL while open. GPIO2 is a strapping pin
// the firmware does not drive between reset and here, so the board's pulldown
// is what keeps the door shut across reset, bootloader and OTA.
void lock_init(void) {
    out_pin(LOCK_GPIO);
    gpio_set_level(LOCK_GPIO, !LOCK_ACTIVE_LEVEL);
    ESP_LOGI(TAG, "lock (pulse IO%d) parked CLOSED", LOCK_GPIO);
}
void lock_open(void)  { gpio_set_level(LOCK_GPIO, LOCK_ACTIVE_LEVEL); }
void lock_close(void) { gpio_set_level(LOCK_GPIO, !LOCK_ACTIVE_LEVEL); }
#endif

// ============================ External watchdog ============================
// The WD chip reboots the board unless EXT_WD is pulsed HIGH at least once
// every WD_RESET_MS. Runs in every mode, the setup portal included.
static void ext_wd_task(void *arg) {
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(WD_RESET_MS));
        gpio_set_level(EXT_WD_GPIO, 1);
        vTaskDelay(pdMS_TO_TICKS(WD_PULSE_MS));
        gpio_set_level(EXT_WD_GPIO, 0);
    }
}

void ext_wd_start(void) {
    out_pin(EXT_WD_GPIO);
    gpio_set_level(EXT_WD_GPIO, 1);            // boot kick
    vTaskDelay(pdMS_TO_TICKS(WD_PULSE_MS));
    gpio_set_level(EXT_WD_GPIO, 0);
    xTaskCreate(ext_wd_task, "ext_wd", 2048, NULL, 5, NULL);
}

// ============================ Status LED ============================
// Blink count = connection stage: 1 no link, 2 has IP, 3 joined Realtime.
// Setup portal: solid ON. Pairing refused: fast continuous blinking.
static volatile led_stage_t s_stage = LED_NO_LINK;
static volatile bool s_portal, s_pair_error;

static void blink(int times, int on_ms, int off_ms) {
    for (int i = 0; i < times; i++) {
        gpio_set_level(STATUS_LED_GPIO, 1);
        vTaskDelay(pdMS_TO_TICKS(on_ms));
        gpio_set_level(STATUS_LED_GPIO, 0);
        vTaskDelay(pdMS_TO_TICKS(off_ms));
    }
}

static void led_task(void *arg) {
    while (true) {
        if (s_pair_error) { blink(1, 60, 60); continue; }
        if (s_portal) { gpio_set_level(STATUS_LED_GPIO, 1); vTaskDelay(pdMS_TO_TICKS(300)); continue; }
        blink((int)s_stage, 100, 150);
        vTaskDelay(pdMS_TO_TICKS(1500));
    }
}

void led_start(void) {
    out_pin(STATUS_LED_GPIO);
    gpio_set_level(STATUS_LED_GPIO, 0);
    xTaskCreate(led_task, "led", 2048, NULL, 4, NULL);
}
void led_set_stage(led_stage_t stage) { s_stage = stage; }
void led_set_portal(bool on)          { s_portal = on; }
void led_set_pair_error(bool on)      { s_pair_error = on; }

// ============================ BOOT button ============================
// Debounced released->pressed edges on GPIO0 during `window_ms` after boot.
// (Sampling GPIO0 after boot is safe; holding it at reset enters download mode.)
int button_press_count(int window_ms) {
    gpio_config_t btn = {
        .pin_bit_mask = 1ULL << SETUP_BUTTON_GPIO,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&btn);
    const int step = 20, debounce = 40;
    int count = 0, pressed = 0, last_raw = 0, stable = 0;
    for (int t = 0; t < window_ms; t += step) {
        int raw = gpio_get_level(SETUP_BUTTON_GPIO) == 0;
        if (raw == last_raw) {
            stable += step;
            if (stable >= debounce && raw != pressed) {
                pressed = raw;
                if (pressed) count++;
            }
        } else {
            last_raw = raw;
            stable = 0;
        }
        vTaskDelay(pdMS_TO_TICKS(step));
    }
    return count;
}
