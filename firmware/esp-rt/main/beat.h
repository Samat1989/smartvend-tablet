// "I'm alive" for the panel's "last seen". Presence is the LWT — Realtime drops
// the board from it within seconds of the socket dying — but it remembers
// nothing, and nothing server-side stays subscribed to write it down. So while
// the board is in the channel it also reports once every 15 minutes over HTTPS
// (RPC device_beat), authenticated by the channel + key it got at pairing.
#pragma once

void beat_start(void);
