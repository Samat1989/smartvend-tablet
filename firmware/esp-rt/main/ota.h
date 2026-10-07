// OTA from Supabase Storage: updates/esp-rt-<variant>/manifest.json.
//
// Manifest: {version, code, url, size, sha256, devices?, pins?}
//   devices: board IDs that get the release (absent = everybody);
//   pins:    {"<ID>": {version, code, url, size, sha256}} — that board gets
//            exactly this build, even an older one. Without a pin a board never
//            goes down.
// A new image must prove itself (2 minutes in the Realtime channel) or the
// board returns to the previous esp-rt image and never installs that code again.
#pragma once

#include <stdbool.h>

void ota_on_boot(void);               // first thing in app_main: crash-loop guard
void ota_start(void);                 // check 60 s after start, then once a day
void ota_check_now(const char *id);   // from the server (signed ota-check): check now, report `ota`
