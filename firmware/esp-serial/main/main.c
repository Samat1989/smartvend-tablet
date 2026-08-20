// esp-serial — relay board driven over USB-serial by the tablet.
//
// The micromarket variant: a fridge whose door is an electric lock instead of
// a wall of motors. The tablet already talks to control boards over USB, runs
// the storefront and settles the payment, so this firmware does exactly one
// thing — throw the relay when told to, and say whether it heard.
//
// Derived from esp-relay with the whole network stack removed: no MQTT, no
// WiFi, no GSM, no provisioning portal, no OTA. Those existed because the
// relay had to learn about a payment on its own; here the tablet knows, and
// the board is downstream of it. What remains is the latching-relay driver and
// the external watchdog, both unchanged.
//
// Protocol — lines of text at 115200 8N1 (see docs/tablet-micromarket.md):
//
//     PING       -> PONG
//     OPEN <sec> -> OK | ERR <reason>
//
// Text rather than framed bytes so an installer can check the board from any
// terminal without a tablet in hand. For one command there was nothing to save
// by parsing frames.
//
// The hold time arrives in the command instead of living here: reflashing this
// board means a cable and a site visit, so the one setting anyone will want to
// change belongs on the tablet.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "driver/gpio.h"
#include "driver/uart.h"
#include "esp_system.h"

// --- Firmware version -------------------------------------------------------
// No OTA here, so this is only ever read by a human over the wire.
#define FW_VERSION_NAME "1.0.0"

// --- Relay ------------------------------------------------------------------
// Latching (bistable) relay, pins reverse-engineered from the stock firmware
// (see ../relay-test/README.md and esp32_dump/RELAY_CONTROL.md). DIR (IO2) sets
// the direction; a short pulse on PULSE (IO16) throws the relay, which then
// holds its state with no coil current.
#define RELAY_DIR_GPIO   GPIO_NUM_2
#define RELAY_PULSE_GPIO GPIO_NUM_16
#define RELAY_SETTLE_MS  100
#define RELAY_PULSE_MS   50

#define HOLD_MIN_SEC 1
#define HOLD_MAX_SEC 600

// --- External hardware watchdog --------------------------------------------
// A WD chip reboots the board unless EXT_WD is pulsed HIGH at least once every
// WD_RESET_MS. Kept from esp-relay: drop it and the board reboots on its own
// every couple of minutes, which on a lock is not a cosmetic problem.
#define EXT_WD_GPIO  GPIO_NUM_32
#define WD_RESET_MS  120000
#define WD_PULSE_MS  500

// --- Status LED -------------------------------------------------------------
// Same pin esp-relay used. Two patterns, and the difference between them is the
// only diagnosis available on a board with no console:
//
//   one short blink every 2 s   firmware is running, nobody is talking to it
//   two quick blinks + pause    the host is sending commands
//
// "Host is talking" rather than "USB is connected", because the ESP cannot see
// the latter: the CH340 owns the USB side and hands us a plain UART, with no
// enumeration state to read. What we can see is traffic — and since the tablet
// pings every 10 s, traffic is an accurate stand-in for a live link. The idle
// window is three times that ping period, so one lost reply cannot flip the
// pattern.
#define STATUS_LED_GPIO GPIO_NUM_33
#define HOST_IDLE_MS    30000

static volatile TickType_t s_last_cmd_tick = 0;

// --- Command channel --------------------------------------------------------
// UART0 is the same port used for flashing. Console logging is switched off in
// sdkconfig.defaults so nothing but our replies ever reaches the tablet.
#define CMD_UART      UART_NUM_0
#define CMD_BAUD      115200
#define CMD_BUF_LEN   256

static volatile bool s_lock_busy = false;

// ============================ Relay =========================================

static void relay_pins_init(void) {
    gpio_config_t io = {
        .pin_bit_mask = (1ULL << RELAY_DIR_GPIO) | (1ULL << RELAY_PULSE_GPIO),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&io);
    gpio_set_level(RELAY_DIR_GPIO, 0);
    gpio_set_level(RELAY_PULSE_GPIO, 0);
}

// Latching ACTIVATE: DIR HIGH, settle, pulse coil, settle, DIR LOW.
static void relay_on(void) {
    gpio_set_level(RELAY_DIR_GPIO, 1);   vTaskDelay(pdMS_TO_TICKS(RELAY_SETTLE_MS));
    gpio_set_level(RELAY_PULSE_GPIO, 1); vTaskDelay(pdMS_TO_TICKS(RELAY_PULSE_MS));
    gpio_set_level(RELAY_PULSE_GPIO, 0); vTaskDelay(pdMS_TO_TICKS(RELAY_SETTLE_MS));
    gpio_set_level(RELAY_DIR_GPIO, 0);
}

// Latching DEACTIVATE: DIR LOW, settle, pulse coil. Leaves DIR low.
static void relay_off(void) {
    gpio_set_level(RELAY_DIR_GPIO, 0);   vTaskDelay(pdMS_TO_TICKS(RELAY_SETTLE_MS));
    gpio_set_level(RELAY_PULSE_GPIO, 1); vTaskDelay(pdMS_TO_TICKS(RELAY_PULSE_MS));
    gpio_set_level(RELAY_PULSE_GPIO, 0);
}

// Holds the lock open, then closes it. Runs off the command task so the reply
// can go out immediately: the tablet's OK means "command accepted", not
// "customer took the goods", and if USB hiccups during the hold the door still
// closes on time because nothing about it depends on the link staying up.
static void hold_task(void *arg) {
    const int seconds = (int)(intptr_t)arg;
    relay_on();
    vTaskDelay(pdMS_TO_TICKS((uint32_t)seconds * 1000));
    relay_off();
    s_lock_busy = false;
    vTaskDelete(NULL);
}

// ============================ External watchdog =============================

static void ext_wd_task(void *arg) {
    gpio_config_t io = {
        .pin_bit_mask = 1ULL << EXT_WD_GPIO,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&io);
    gpio_set_level(EXT_WD_GPIO, 0);
    while (1) {
        gpio_set_level(EXT_WD_GPIO, 1);
        vTaskDelay(pdMS_TO_TICKS(WD_PULSE_MS));
        gpio_set_level(EXT_WD_GPIO, 0);
        vTaskDelay(pdMS_TO_TICKS(WD_RESET_MS - WD_PULSE_MS));
    }
}

// ============================ Status LED ====================================

static void led_blink(int times, int on_ms, int gap_ms) {
    for (int i = 0; i < times; i++) {
        gpio_set_level(STATUS_LED_GPIO, 1);
        vTaskDelay(pdMS_TO_TICKS(on_ms));
        gpio_set_level(STATUS_LED_GPIO, 0);
        if (i + 1 < times) vTaskDelay(pdMS_TO_TICKS(gap_ms));
    }
}

static void status_led_task(void *arg) {
    gpio_config_t io = {
        .pin_bit_mask = 1ULL << STATUS_LED_GPIO,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&io);
    gpio_set_level(STATUS_LED_GPIO, 0);

    while (1) {
        // Unsigned subtraction, so the 32-bit tick counter wrapping after some
        // seven weeks of uptime does not make the board look idle.
        const TickType_t since = xTaskGetTickCount() - s_last_cmd_tick;
        if (s_last_cmd_tick != 0 && since < pdMS_TO_TICKS(HOST_IDLE_MS)) {
            led_blink(2, 70, 130);
            vTaskDelay(pdMS_TO_TICKS(1400));
        } else {
            led_blink(1, 60, 0);
            vTaskDelay(pdMS_TO_TICKS(1940));
        }
    }
}

// ============================ Command channel ===============================

static void reply(const char *s) {
    uart_write_bytes(CMD_UART, s, strlen(s));
    uart_write_bytes(CMD_UART, "\n", 1);
}

// One command line, already trimmed. Unknown input gets a named error rather
// than silence — a tester on a terminal should never be left guessing whether
// the board is wedged or just did not understand.
static void handle_line(char *line) {
    // Stamped for any line at all, including one we go on to reject: a garbled
    // command still proves somebody is on the other end, which is exactly what
    // the LED is reporting.
    s_last_cmd_tick = xTaskGetTickCount();

    if (strcmp(line, "PING") == 0) {
        reply("PONG");
        return;
    }

    if (strcmp(line, "VER") == 0) {
        reply("esp-serial " FW_VERSION_NAME);
        return;
    }

    if (strncmp(line, "OPEN", 4) == 0 && (line[4] == ' ' || line[4] == 0)) {
        if (s_lock_busy) {
            // Refuse rather than restart the timer: a second OPEN mid-hold
            // means either a double tap or two sales racing, and silently
            // extending the open door is the wrong answer to both.
            reply("ERR busy");
            return;
        }
        const int seconds = (line[4] == 0) ? 0 : atoi(line + 5);
        if (seconds < HOLD_MIN_SEC || seconds > HOLD_MAX_SEC) {
            reply("ERR range");
            return;
        }
        s_lock_busy = true;
        if (xTaskCreate(hold_task, "hold", 2560,
                        (void *)(intptr_t)seconds, 5, NULL) != pdPASS) {
            s_lock_busy = false;
            reply("ERR task");
            return;
        }
        reply("OK");
        return;
    }

    reply("ERR unknown");
}

static void cmd_task(void *arg) {
    uart_config_t cfg = {
        .baud_rate = CMD_BAUD,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    uart_driver_install(CMD_UART, CMD_BUF_LEN * 2, 0, 0, NULL, 0);
    uart_param_config(CMD_UART, &cfg);

    char line[CMD_BUF_LEN];
    int len = 0;
    uint8_t ch;

    while (1) {
        if (uart_read_bytes(CMD_UART, &ch, 1, portMAX_DELAY) != 1) continue;

        if (ch == '\n' || ch == '\r') {
            if (len == 0) continue;          // bare CR of a CRLF, or a stray NL
            line[len] = 0;
            len = 0;
            handle_line(line);
            continue;
        }

        // Overlong input is dropped rather than truncated and acted on: a
        // half-parsed OPEN could open the door for the wrong number of seconds.
        if (len >= (int)sizeof(line) - 1) {
            len = 0;
            reply("ERR toolong");
            continue;
        }
        line[len++] = (char)ch;
    }
}

// ============================ app_main ======================================

void app_main(void) {
    // Park the relay closed before anything else. It is bistable, so it powers
    // up in whatever state it was left in — including open, if the board lost
    // power mid-hold.
    relay_pins_init();
    relay_off();

    xTaskCreate(ext_wd_task, "ext_wd", 2048, NULL, 4, NULL);
    xTaskCreate(status_led_task, "status_led", 2048, NULL, 3, NULL);
    xTaskCreate(cmd_task, "cmd", 4096, NULL, 5, NULL);
}
