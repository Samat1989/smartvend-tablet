// Relay bring-up test firmware (ESP-IDF, target esp32).
//
// Purpose: drive the relay board over a simple USB-serial command protocol so
// the GPIO wiring and the latching pulse sequence can be verified from a PC
// before the real firmware is written.
//
// Pins come from reverse-engineering the stock SmartVend firmware dump:
//   channel 0 -> DIR = GPIO2 ("IO2"), PULSE = GPIO16 ("IO16")
// The relay is LATCHING (bistable): DIR selects the direction, a 50 ms pulse on
// PULSE energizes the coil, and the relay then holds its state with no current.
// Channel 1 pins are unknown — probe them with the raw `g`/`p` commands and set
// CH1_DIR / CH1_PULSE once found.
//
// Command protocol (one line, 115200 8N1, '\n' terminated):
//   help                 - print this help
//   on   <ch>            - latching activate  (ch = 0 or 1)
//   off  <ch>            - latching deactivate (ch = 0 or 1)
//   g    <pin> <0|1>     - raw: set any GPIO level (probe wiring)
//   p    <pin> <ms>      - raw: pulse a GPIO HIGH for <ms> then LOW
//   pins                 - show configured channel pins

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "driver/uart.h"
#include "esp_log.h"

static const char *TAG = "relay_test";

// ---- channel -> (direction pin, pulse pin) -------------------------------
// CH0 confirmed from the firmware dump. CH1 is a guess — verify with `g`/`p`.
#define CH0_DIR    GPIO_NUM_2
#define CH0_PULSE  GPIO_NUM_16
#define CH1_DIR    GPIO_NUM_4    // TODO: verify on real board
#define CH1_PULSE  GPIO_NUM_17   // TODO: verify on real board

// Latching timing (from dump): 100 ms settle, 50 ms coil pulse.
#define SETTLE_MS  100
#define PULSE_MS   50

typedef struct { gpio_num_t dir; gpio_num_t pulse; } relay_ch_t;
static const relay_ch_t CH[2] = {
    { CH0_DIR, CH0_PULSE },
    { CH1_DIR, CH1_PULSE },
};

static const gpio_num_t ALL_PINS[] = { CH0_DIR, CH0_PULSE, CH1_DIR, CH1_PULSE };

static void pins_init(void) {
    uint64_t mask = 0;
    for (size_t i = 0; i < sizeof(ALL_PINS) / sizeof(ALL_PINS[0]); i++)
        mask |= (1ULL << ALL_PINS[i]);
    gpio_config_t io = {
        .pin_bit_mask = mask,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&io);
    for (size_t i = 0; i < sizeof(ALL_PINS) / sizeof(ALL_PINS[0]); i++)
        gpio_set_level(ALL_PINS[i], 0);
}

// Latching ACTIVATE: DIR HIGH, settle, pulse coil, settle, DIR LOW.
static void relay_on(int ch) {
    if (ch < 0 || ch > 1) { printf("bad channel\n"); return; }
    const relay_ch_t *c = &CH[ch];
    printf("CH%d ON : DIR(IO%d)=HIGH, wait %dms\n", ch, c->dir, SETTLE_MS);
    gpio_set_level(c->dir, 1);   vTaskDelay(pdMS_TO_TICKS(SETTLE_MS));
    printf("        PULSE(IO%d) %dms\n", c->pulse, PULSE_MS);
    gpio_set_level(c->pulse, 1); vTaskDelay(pdMS_TO_TICKS(PULSE_MS));
    gpio_set_level(c->pulse, 0); vTaskDelay(pdMS_TO_TICKS(SETTLE_MS));
    gpio_set_level(c->dir, 0);
    printf("        DIR=LOW -> relay activated\n");
}

// Latching DEACTIVATE: DIR LOW, settle, pulse coil.
static void relay_off(int ch) {
    if (ch < 0 || ch > 1) { printf("bad channel\n"); return; }
    const relay_ch_t *c = &CH[ch];
    printf("CH%d OFF: DIR(IO%d)=LOW, wait %dms\n", ch, c->dir, SETTLE_MS);
    gpio_set_level(c->dir, 0);   vTaskDelay(pdMS_TO_TICKS(SETTLE_MS));
    printf("        PULSE(IO%d) %dms\n", c->pulse, PULSE_MS);
    gpio_set_level(c->pulse, 1); vTaskDelay(pdMS_TO_TICKS(PULSE_MS));
    gpio_set_level(c->pulse, 0);
    printf("        relay cycle complete\n");
}

// Timed open: activate, hold N seconds, deactivate — runs in its own task so
// the command console stays responsive while the relay is held.
typedef struct { int ch; int sec; } open_arg_t;
static void open_task(void *pv) {
    open_arg_t a = *(open_arg_t *)pv;
    free(pv);
    relay_on(a.ch);
    vTaskDelay(pdMS_TO_TICKS(a.sec * 1000));
    relay_off(a.ch);
    printf("CH%d closed after %ds\n", a.ch, a.sec);
    vTaskDelete(NULL);
}

static void print_help(void) {
    printf(
        "\ncommands:\n"
        "  on   <ch>          latching activate   (ch 0/1)\n"
        "  off  <ch>          latching deactivate (ch 0/1)\n"
        "  open <ch> <sec>    activate, hold <sec> seconds, deactivate\n"
        "  g    <pin> <0|1>   raw set GPIO level\n"
        "  p    <pin> <ms>    raw pulse GPIO HIGH for <ms>\n"
        "  pins               show channel pins\n"
        "  help               this help\n\n");
}

static void handle_line(char *line) {
    char *cmd = strtok(line, " \t\r\n");
    if (!cmd) return;
    char *a1 = strtok(NULL, " \t\r\n");
    char *a2 = strtok(NULL, " \t\r\n");

    if (!strcmp(cmd, "help")) {
        print_help();
    } else if (!strcmp(cmd, "pins")) {
        printf("CH0: DIR=IO%d PULSE=IO%d\nCH1: DIR=IO%d PULSE=IO%d\n",
               CH[0].dir, CH[0].pulse, CH[1].dir, CH[1].pulse);
    } else if (!strcmp(cmd, "on") && a1) {
        relay_on(atoi(a1));
    } else if (!strcmp(cmd, "off") && a1) {
        relay_off(atoi(a1));
    } else if (!strcmp(cmd, "open") && a1 && a2) {
        open_arg_t *p = malloc(sizeof(*p));
        if (p) {
            p->ch = atoi(a1); p->sec = atoi(a2);
            printf("CH%d open for %ds...\n", p->ch, p->sec);
            xTaskCreate(open_task, "open", 3072, p, 5, NULL);
        }
    } else if (!strcmp(cmd, "g") && a1 && a2) {
        int pin = atoi(a1), lvl = atoi(a2) ? 1 : 0;
        gpio_set_direction(pin, GPIO_MODE_OUTPUT);
        gpio_set_level(pin, lvl);
        printf("GPIO%d = %d\n", pin, lvl);
    } else if (!strcmp(cmd, "p") && a1 && a2) {
        int pin = atoi(a1), ms = atoi(a2);
        gpio_set_direction(pin, GPIO_MODE_OUTPUT);
        gpio_set_level(pin, 1); vTaskDelay(pdMS_TO_TICKS(ms)); gpio_set_level(pin, 0);
        printf("GPIO%d pulsed %dms\n", pin, ms);
    } else {
        printf("? unknown: %s (type 'help')\n", cmd);
    }
}

#define UART_PORT  UART_NUM_0
#define BUF_SZ     256

void app_main(void) {
    pins_init();

    uart_config_t uc = {
        .baud_rate = 115200,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    uart_driver_install(UART_PORT, BUF_SZ * 2, 0, 0, NULL, 0);
    uart_param_config(UART_PORT, &uc);

    ESP_LOGI(TAG, "relay test ready (esp32). CH0 IO2/IO16. type 'help'");
    print_help();

    char line[BUF_SZ];
    int idx = 0;
    uint8_t ch;
    while (1) {
        int n = uart_read_bytes(UART_PORT, &ch, 1, pdMS_TO_TICKS(100));
        if (n <= 0) continue;
        if (ch == '\n' || ch == '\r') {
            if (idx > 0) { line[idx] = 0; handle_line(line); idx = 0; }
        } else if (idx < BUF_SZ - 1) {
            line[idx++] = ch;
        }
    }
}
