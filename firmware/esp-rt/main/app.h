// Normal operation: Realtime channel, ping/pong, signed open / service-open / ota-check.
#pragma once

#include <stdbool.h>

void app_start(void);
bool app_idle(void);   // no open window now or in the last 2 minutes: safe to reboot
