// NVS: provisioned config (namespace "rt") and the ring of recently opened ids.
#pragma once

#include <stdbool.h>
#include <stddef.h>

typedef struct {
    char netmode[8];     // "wifi" | "gsm"
    char ssid[64];
    char pass[64];
    char machid[16];
    char code[8];        // pairing code, kept only until device_pair succeeds
    char rt_topic[40];   // Realtime channel uuid
    char rt_key[72];     // HMAC key for signed commands
    int  opensec;
    bool pair_error;     // last pairing attempt was refused; shown in the portal
} rt_config_t;

extern rt_config_t g_cfg;

void store_init(void);
void store_load(void);
void store_set_str(const char *key, const char *val);
void store_set_int(const char *key, int val);
void store_erase(const char *key);

bool store_has_network(void);   // netmode set and, for Wi-Fi, an SSID
bool store_paired(void);        // machid + rt_topic + rt_key present

// Recently opened command ids (order ids / service-open ids), persisted so a
// command replayed after a reboot still does not open the door twice.
bool seen_has(const char *id);
void seen_add(const char *id);
