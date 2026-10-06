// Uplink: Wi-Fi STA or GSM (A7670E over PPP). Same bring-up as esp-pulse.
#pragma once

#include <stdbool.h>

void net_init(void);                       // netif, event loop, Wi-Fi driver
void net_start(void);                      // brings up g_cfg.netmode and keeps it up
bool net_wait_ip(int timeout_ms);
bool net_has_ip(void);
void net_portal_mode(void);              // before the portal starts Wi-Fi: no auto-connect
bool net_wifi_try(const char *ssid, const char *pass);   // portal: test credentials (APSTA)
void net_signal(int *dbm, int *csq);       // dBm (0 = unknown); csq: GSM 0..31/99, -1 on Wi-Fi
void net_sntp_start(void);
bool net_time_synced(void);
