// Board hardware: lock output, status LED, external watchdog, BOOT button.
#pragma once

#include <stdbool.h>

typedef enum {
    LED_NO_LINK = 1,     // 1 blink
    LED_HAS_IP  = 2,     // 2 blinks
    LED_ONLINE  = 3,     // 3 blinks: joined the Realtime channel
} led_stage_t;

void lock_init(void);     // parks the lock closed
void lock_open(void);
void lock_close(void);

void ext_wd_start(void);

void led_start(void);
void led_set_stage(led_stage_t stage);
void led_set_portal(bool on);      // solid ON while the setup portal is up
void led_set_pair_error(bool on);  // fast blinking: pairing code refused

int  button_press_count(int window_ms);
