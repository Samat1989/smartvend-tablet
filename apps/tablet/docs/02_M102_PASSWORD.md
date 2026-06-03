# The hidden M102 "password" — CRC pre-image

## TL;DR

The factory M102 / M109E control board enforces a vendor-specific
**CRC pre-image** that the public protocol docs (`api_docsM109E.txt`)
do not mention. Frames whose CRC was computed without it are silently
discarded — **no reply ever comes back**. If you're building a host
client (Android / PC) and you see "TX goes out but every request
times out," this is almost certainly why.

## What you have to do

When computing the CRC-16/Modbus over an outgoing frame, append the
following 11 bytes to the CRC input **after** the 18 bytes of
`[addr][opcode][16 data bytes]`:

```
0x31 0x38 0x36 0x33 0x33 0x36 0x39 0x35 0x38 0x32 0x36
```

That's ASCII for **`18633695826`** — a Chinese phone number baked
into the factory firmware. The frame **on the wire is still 20
bytes** (the password is *not* transmitted), but the CRC reflects
the extended pre-image.

```
Frame on the wire :  [addr][op][16 data bytes][CRClo][CRChi]    = 20 bytes
CRC pre-image     :  [addr][op][16 data bytes] + "18633695826"  = 29 bytes
```

## Why we know this

Reverse-engineered from the factory Android app (decompiled `pos_app`
ancestor). The relevant code paths:

- `Flag.f282CMD_M102_` — the flag indicating M102-protocol mode
- `CreatADH.m141biany()` — the frame builder that pulls in the password
- `IS_M102GOTOCODE` — the boolean toggle, default `true`

Mirrored in this codebase at:

- [`m102_tester/lib/board/board_client.dart`](../lib/board/board_client.dart) — `m102Password` constant + `_useM102Password` flag (default `true`)
- [`mmd/lib/board_client.dart`](../../mmd/lib/board_client.dart) — same constants, same default; toggleable from the diagnostic UI

## Variants in the field

Not every M109E firmware enforces the password. Observed so far:

| Firmware ID | Source | Password required? |
|---|---|---|
| `mj2310` | Factory kiosk board (vending cabinet) | **Yes** — without it, no reply |
| `÷MÆ §á 2307` | Bench / test M109E, no cabinet wiring | No — replies fine with bare 18-byte CRC |

If you're integrating with an unknown M102/M109E board and `Get ID`
times out:

1. First, send the request **with** the password. ~95 % of factory
   boards need this.
2. If still no reply, send **without** the password. A small number
   of bench / aftermarket firmware versions skip the check.
3. Only then look elsewhere (slave address, baud, RS-485 direction
   pin, USB-Serial chip permissions).

## Validating incoming frames

The factory firmware appears to compute reply CRC using the same
password pre-image (untested across all opcodes). **Do not enforce
strict CRC validation on RX** — m102_tester reads the payload
directly and only checks frame length (20 bytes). The MMD client
follows the same convention. Over-strict CRC validation here will
drop legitimate replies and re-introduce the "timeout on every
request" symptom.

## The official docs are still useful

Everything in `api_docsM109E.txt` — opcodes, data layouts, motor
indexing, switch I/O — is correct *as a description of what the
frame contains*. The password is invisible at that layer; it only
shows up in the integrity check.
