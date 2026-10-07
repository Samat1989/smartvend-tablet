// esp-rt — static-QR lock board on Supabase Realtime. Fixed constants.
#pragma once

#include "sdkconfig.h"

#define FW_VERSION_NAME   "1.1.3"
#define FW_VERSION_CODE   10103

// --- Cloud ---
#define SUPABASE_HOST     "cgvfhtvdtdjsyluhlcbq.supabase.co"
#define SUPABASE_KEY      "sb_publishable_84RnaNCrFwxKicybxLGL2w_StEYpHnD"

// --- Variant ---
// OTA reads updates/esp-rt-<variant>/manifest.json in Supabase Storage, so a
// pulse board never pulls the relay build (its lock line would stay dead).
#if CONFIG_ESPRT_LOCK_RELAY
#define FW_VARIANT        "relay"
#else
#define FW_VARIANT        "pulse"
#endif

// --- Pins (same board as esp-pulse / esp-relay) ---
#define LOCK_GPIO            2     // pulse: held HIGH while open; relay: DIR
#define RELAY_PULSE_GPIO     16    // relay only: coil pulse
#define LOCK_ACTIVE_LEVEL    1     // pulse: IO2 needs a pulldown on the board (strapping pin)
#define RELAY_SETTLE_MS      100
#define RELAY_PULSE_MS       50
#define EXT_WD_GPIO          32    // external watchdog: pulse HIGH every WD_RESET_MS
#define WD_RESET_MS          120000
#define WD_PULSE_MS          500
#define STATUS_LED_GPIO      33
#define SETUP_BUTTON_GPIO    0     // BOOT: >3 taps within 4 s of power-on -> setup portal
#define PROVISION_WINDOW_MS  4000
#define PROVISION_PRESS_COUNT 3

// --- GSM (A7670E over PPP, driven as SIM7600) ---
#define GSM_UART_TX_GPIO     25
#define GSM_UART_RX_GPIO     26
#define GSM_UART_BAUD        115200
#define GSM_POWER_GPIO       5
#define GSM_BOOT_DELAY_MS    10000
#define GSM_DEFAULT_APN      "internet"

#define DEFAULT_OPEN_SECONDS 20
