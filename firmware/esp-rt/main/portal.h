// Setup portal: open SoftAP SmartVend-Setup-XXXX + captive page at 192.168.4.1.
// The owner picks Wi-Fi or GSM, enters the machine number and the pairing code
// from the panel; the board saves them and reboots into pairing.
#pragma once

#include <stdbool.h>

// can_time_out: reboot after 3 min idle (only when there is a config to go back to).
void portal_start(bool can_time_out);
