// Takeover of a board that ran esp-pulse / esp-relay. Their NVS namespace
// "cfg" holds the network setup plus machid and the SmartVend secret; esp-rt
// imports the network and proves the secret to the server (RPC device_migrate)
// in return for its channel and key, so no one has to touch the board.
#pragma once

#include <stdbool.h>

#include "pair.h"

bool migrate_pending(void);          // "cfg" has machid + secret
void migrate_import_network(void);   // netmode / ssid / pass -> "rt", then store_load()
pair_result_t migrate_device(void);  // device_migrate; on success wipes "cfg"
void migrate_wipe(void);             // erase the old "cfg" (secret included)
long migrate_machid(void);           // for the log; 0 if none
