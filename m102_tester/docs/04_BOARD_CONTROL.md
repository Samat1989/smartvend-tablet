# Board control — m102_tester reference

How the tablet app talks to the M102 / M109E / MP2404 control board.
Source-level details with code references so the next engineer doesn't
have to reverse-engineer twice. The public M109E API doc
(`/c/m109e/docs/01_PROTOCOL.md`) describes the wire format generically;
this file documents how **m102_tester** uses it.

---

## 1. Physical layer

| Setting | Value | Source |
|---|---|---|
| Transport | USB-Serial via CH340 | [`board_client.dart:88`](../lib/board/board_client.dart) |
| USB VID/PID | `0x1A86` / `0x7523` | matches factory app's `UsbUtil.findUSB` |
| Baud | 9600 | factory constant `BOTELV_9600` |
| Framing | 8N1 | factory default |
| Bus | RS-485 half-duplex with auto-direction (CH340 RTS drives DE/RE) | observed |

The CH340 in this cabinet is **fixed to the board** — auto-detect
filters on VID/PID before opening. Other USB-Serial adapters (FTDI,
CP210x, PL2303) only appear in the manual-connect picker; auto-connect
ignores them so the app doesn't grab unrelated peripherals.

---

## 2. Frame format

Every TX and RX is **exactly 20 bytes**, fixed length, no escaping:

```
[addr] [opcode] [data×16]                              [crc_lo] [crc_hi]
 1 B    1 B     16 B                                    1 B      1 B
```

* `addr` — slave address, default `1`. Multi-board cabinets number
  1..N; m102_tester uses 1 throughout.
* `opcode` — single byte, see §3.
* `data` — opcode-specific 16 bytes, zero-padded.
* `crc` — Modbus CRC-16, **little-endian** in the frame.

CRC computation: [`board_client.dart:536-545`](../lib/board/board_client.dart).
The polynomial is `0xA001` (reversed `0x8005`), seed `0xFFFF`. Standard
Modbus RTU.

### 2.1 The hidden CRC password

The CRC is **not** computed over the bare 18-byte header — it's
computed over `[header] + "18633695826"` (11 ASCII bytes). Full
write-up in [`02_M102_PASSWORD.md`](02_M102_PASSWORD.md). Short
version:

```dart
final crcInput = _useM102Password
    ? [...frame.sublist(0, 18), ...m102Password]
    : frame.sublist(0, 18);
```

Default ON. Toggleable per-device from **Сервисный режим → Плата →
«CRC-пароль»**. Persisted in `DeviceStorage.useM102Password`.

When to switch it off:

* **`mj2310`** (factory M109E kiosk board) — keep ON.
* **`2307`** (bench/test M109E) — switch OFF, replies otherwise time out.
* **MP2404** clone boards — observed both ways; flip and see what
  responds to `Get ID`.

The factory firmware **also** generates reply CRCs using the same
password recipe. We do not validate incoming CRCs (frame length 20 is
the only RX check) — over-strict validation drops valid replies and
re-introduces the "timeout on everything" symptom.

---

## 3. Opcode table

Every command m102_tester issues. Codes match `api_docsM109E.txt` and
the decompiled `ParseM102.java`.

| Opcode | Name | Dart entry-point | Use |
|---|---|---|---|
| `0x01` | Get ID | `BoardClient.getId()` | firmware probe at connect / health recovery |
| `0x03` | Poll status | `BoardClient.poll()` | 900 ms heartbeat + dispense progress |
| `0x04` | Motor Scan | `BoardClient.scanMotor()` | service-mode "Scan all motors" |
| `0x05` | Motor Run | `BoardClient.motorRun()` | start a dispense |
| `0x07` | Read Temperature | `BoardClient.readTemp()` | climate-controller 10 s tick |
| `0x08` | Write DO | `BoardClient.writeDo()` | fan / compressor / heater / LED |
| `0x10` | Read Humidity | `BoardClient.readHumidity()` | climate 30 s tick (optional) |

Lower-level send is [`_sendAndReceive`](../lib/board/board_client.dart)
— builds frame, writes to port, parks a `Completer<Uint8List>` that
the RX listener fulfils when a frame with the same opcode comes back.
Timeout default **800 ms** (300 ms for Motor Scan since it has to
sweep 0..99 quickly).

### 3.1 Get ID (0x01)

* Request payload: 16 zero bytes.
* Reply: ASCII firmware ID in bytes 2..13 (e.g. `mj2310 v1.0`).
* The reply also serves as a liveness check — `BoardClient.ping()`
  uses the same opcode with a shorter 600 ms timeout for the cart/pay
  flow's "is the board alive *right now*" gate.

### 3.2 Poll status (0x03)

```
RX layout (factory ParseM102.m177jx):
  byte 2  : state       0=Idle, 1=Running, 2=Done
  byte 3  : motor       channel that ran (only meaningful if state>0)
  byte 4  : result      0=OK, 1=Overload, 2=WireBreak, 3=Timeout,
                        4=CurtainErr, 5=LockNotOpen, 10=MicroSwitchTimeout
  byte 5-6: peak mA     u16 big-endian
  byte 7-8: avg mA      u16 big-endian
  byte 9-10: time ms    u16 big-endian
  byte 11 : curtain ms  u8 — IR drop-sensor break duration
```

Two roles in m102_tester:

1. **900 ms heartbeat** (see §4) — keeps the bus warm and produces
   side-effect signal for the health watchdog.
2. **Dispense progress** — after `motorRun`, the [`dispense()`
   loop](../lib/board/board_client.dart) polls every 500 ms until
   `state == 2 (Done)`, with a 20 s overall timeout.

### 3.3 Motor Scan (0x04)

Non-destructive presence test — pulses the channel and reads the
shunt-current sense byte, the spiral does **not** rotate.

* Request: byte 0 = motor index (0..99).
* Reply byte 2:
  * `0xAA` — wired (normal current draw)
  * `0xBB` — empty / wire break (no current)
  * `0xCC` — overload (short)

Used by the layout editor's "Сканировать моторы" sweep — walks 0..99,
shows green/grey/orange cells so the operator sees which channels
are physically wired before assigning slots.

### 3.4 Motor Run (0x05)

```
TX layout:
  byte 0 : motor index   0..99
  byte 1 : type          2 = 2-wire (default), 3 = 3-wire
  byte 2 : curtain mode  0 = no drop sensor,
                         1 = standard (require break to confirm),
                         2 = priority (sensor self-test before run)
```

Reply byte 2 ACK:
* `0` started
* `1` invalid index (motor doesn't exist)
* `2` busy (previous run still in progress)

Started is just an ACK — completion comes through `0x03 Poll` later.

### 3.5 Read Temperature (0x07)

```
raw = signed_int16(bytes 2..3)
°C  = (raw - 20) / 10
```

`-52 °C` is the sentinel for "no probe" — `readTemp()` returns null
in that case so the climate controller can fall back to safe-off.

### 3.6 Write DO (0x08)

Discrete output control. Channel map is **fixed by firmware**, not
configurable:

| DO id | Name | Driven from |
|---|---|---|
| 0 | Fan (compressor heat-dissipation) | `_setDo(DoChannel.fan, …)` |
| 1 | Compressor (refrigeration relay) | `_setDo(DoChannel.compressor, …)` |
| 2 | Glass heater (anti-condensation) | `_setDo(DoChannel.glassHeater, …)` |
| 3 | LED strip (cabinet light) | `_setDo(DoChannel.lightStrip, …)` |
| 4 | Heater module (when ClimateMode = heating) | `_setDo(DoChannel.heaterModule, …)` |

Reply byte 3: `0xF0` = OFF accepted, `0xF1` = ON accepted, anything
else means the board rejected the request (usually means the channel
id is out of range).

### 3.7 Read Humidity (0x10)

```
byte 2 : %RH (0..100)
byte 4 : status (<10 means sensor OK)
```

Optional — many cabinets don't have a humidity probe. `readHumidity()`
returns null on missing sensor; climate controller then folds glass
heater control into the compressor cycle instead of running it as a
standalone humidity loop.

---

## 4. The 900 ms poll heartbeat

The factory app's `C0082ThreadADH.java:97` runs a forever-loop:

```java
while (true) {
    Thread.sleep(900);
    for (addr in 1..N) sendM102Order("03");
}
```

m102_tester mirrors this with a Dart `Timer.periodic` —
[`_startPollHeartbeat()`](../lib/board/board_client.dart). Why 900 ms
specifically:

1. **CH340 autosuspend**. On Android Go tablets (the cabinet's
   primary target — Unisoc SC9832E), the USB-Serial chip enters
   autosuspend after ~3 s of TX silence. Once suspended, the next TX
   has a 200-500 ms wake-up tax and sometimes drops the first frame
   silently. A poll-per-second cleanly avoids this.
2. **Board-side bus watchdog**. Some firmware revisions reset their
   own communication state after several seconds of silence. The
   factory cadence is what's been tested in the field.
3. **Health signal**. Every poll either succeeds (resets
   `_consecutiveFailures` to 0) or fails (increments). Four
   consecutive misses → `isHealthy = false`, which lights up the
   maintenance overlay on the customer screen.

The tick **skips itself** when (a) another request is mid-flight
(climate read, dispense, manual op from service mode) or (b) the
health watchdog is reconnecting. The heartbeat never collides with
real work or self-healing.

---

## 5. Self-healing / health watchdog

Even with the heartbeat, CH340 driver state on Android can wedge —
port stays "open" from Dart's view but every TX silently goes to
`/dev/null`. The board never sees a USB-detach event, so the
attach/detach reconnect logic doesn't fire either.

[`_startHealthWatchdog()`](../lib/board/board_client.dart) ticks
every 10 s. If `isConnected && !isHealthy` for ≥ 30 s, it runs the
factory escalation ladder modelled on `UsbUtil.isRestartApp` /
`m933reboot`:

| Reconnect # | Action |
|---|---|
| 1 | `forceReconnect()` — close + reopen port. Clears most CH340 wedges. |
| 2 | Same as #1. We just log louder so the operator notices in service mode → Плата. |
| 5 | `KioskBridge.restartApp()` — kill our own process via `Process.killProcess` and relaunch via AlarmManager (250 ms). Clears stuck driver state inside our own process. |
| ≥ 10 | `KioskBridge.rebootDevice()` — `DevicePolicyManager.reboot()`. Hard reboot of the whole tablet. Requires device-owner; silent no-op otherwise. |

The escalation counter `_reconnectAttempts` resets to 0 on the **next
successful exchange** — the watchdog forgets past outages once the
bus is back. Surfaced in service mode → Плата for diagnostics.

The factory app has the same ladder; we just plumbed the actions
through `KioskBridge` (Flutter ↔ MainActivity MethodChannel) because
the original calls relied on Android system APIs that require
device-owner anyway.

---

## 6. Motor dispense flow

[`dispense(motorIdx, type, curtain)`](../lib/board/board_client.dart):

```
1. RunAck = motorRun(idx, type, curtain)
   → invalidIndex / busy / noResponse → return failure
   → started → continue

2. Loop every 500 ms (overall timeout 20 s):
   p = poll()
   if p.state == Done:
     if p.result != 0:
       return failure(localized result code)
     if curtain != 0 AND p.curtainMs == 0:
       return "motor ran, but drop sensor never triggered"
     return success(peak mA, time ms, drop ms)
```

### 6.1 Motor type

* **2-wire (default)** — simple H-bridge spiral. Most common.
* **3-wire** — spiral with an extra control wire (older Chinese
  machines). Operator picks this in service mode → Настройка моторов
  per slot; the value lives on `inventory.motor_type`.

### 6.2 Curtain mode (drop sensor)

* `0` — no IR curtain. Success only requires `result == 0`. Used on
  cabinets without a drop sensor, or for free-fall mechanics where
  the sensor isn't reliable (large boxes occlude differently than
  small bottles).
* `1` — standard. Sensor is powered during the run; the V1 line
  pulses, and if the SIG line breaks for >0 ms during dispense, we
  count the drop. **Result `4` = curtain self-test failed before
  motor started** (broken sensor / wrong wiring / no 24 V on V1).
* `2` — priority. The board runs a sensor self-test *first* and
  refuses to start the motor if it fails. Used for high-value items
  where you'd rather refund-before-fail.

Per `api_docsM109E.txt §6.4`, V1 (sensor power) is **only** energised
during a RUN with curtain ≠ 0. There's no standalone "turn the sensor
on" opcode, which is why **Тест датчика** in motor setup forces
`curtain = 1` even if the slot's normal setting is 0 — that's the
only way to exercise the IR curtain hardware.

### 6.3 Twin spirals

[`dispenseSlot(motorIds, …)`](../lib/board/board_client.dart) runs
the slot's motors **sequentially**, short-circuiting on the first
failure. For a single-motor slot it's identical to `dispense()`. Used
for wide products where two spirals must fire together — the layout
editor lets the operator declare twin slots; the catalog tile then
shows a TWIN badge.

---

## 7. Climate control loop

[`ClimateController`](../lib/services/climate_controller.dart) drives
fan / compressor / glass heater / heater module via 0x08 Write DO.
Algorithm derived from factory `shouhj/app/C0101App.java`'s
`M102_StartRefrigeration` / `M102_StartHeating` /
`M102_finish`. Constants in code are unchanged from the factory.

### 7.1 Sampling cadence

| Tick | Period |
|---|---|
| Temperature read (0x07) + evaluate | 10 s |
| Humidity read (0x10) + glass-heater control | 30 s |

### 7.2 Hysteresis

```
hysteresis  = ±4 °C around setpoint
cooling:
  temp ≥ setpoint + 4   → start cycle
  temp ≤ setpoint        → stop cycle (all off)
  in between             → keep current state

heating:
  temp ≤ setpoint - 4   → start cycle
  temp ≥ setpoint        → stop cycle
  in between             → keep current state
```

The wide band prevents short-cycling the compressor — running it for
30 s then off then on is the fastest way to kill a refrigeration
relay.

### 7.3 Cooling start-up sequence

When a cooling cycle needs to start:

```
1. If heater module is on → turn OFF
2. If fan is off → turn ON. Bail; next tick continues.
3. Increment fan-warmup tick counter
4. After N ticks → turn compressor ON
   + turn glass heater ON (unless humidity loop owns it)
5. Compressor stays ON until temp ≤ setpoint OR forced-rest fires
```

The fan-warmup duration N depends on session history:

* **First compressor start after app boot** — 30 ticks (≈ 5 min).
  Compressor + refrigerant have been off long enough that pressure
  needs to equalize and the relay needs slow-start protection.
* **Every subsequent cycle** in the same session — 12 ticks
  (≈ 2 min). Compressor + condenser are already warm; short
  warm-up is enough.

This matches the factory app's `M102_StartRefrigeration` behaviour
exactly. The session flag (`_compressorHasRunThisSession`) resets on
every process start — a fresh power-up of the cabinet always gets the
long warmup.

### 7.4 Heating start-up sequence

```
1. If compressor is on → turn OFF (also drop glass heater if not
   owned by humidity loop)
2. If fan is off → turn ON. Bail; next tick continues.
3. Increment fan-warmup tick counter
4. After 12 ticks (≈ 2 min) → turn heater module ON
```

Shorter spin-up because heater inrush is gentler than compressor.

### 7.5 Forced rest — m102_tester safety on top of factory

After **60 minutes** of continuous compressor work, force a
**5-minute** rest:

```
if (now - compressorStartedAt >= 60 min) {
    turn everything off
    enter `resting` phase
    block any new cycle for 5 min
}
```

Catches "door left open" / "setpoint unreachable" without burning
the compressor. The factory has the code path declared but never
triggers it — we activate it.

### 7.6 Glass heater logic

Two ownership paths:

* **No humidity sensor** → glass heater follows compressor (ON during
  cooling cycle, OFF during heating / off / fan-only). Prevents
  cold-side condensation on the door.
* **Humidity sensor present** → glass heater is owned by the humidity
  loop, ON when `humidity ≥ 60 %`, OFF otherwise. More efficient on
  cabinets in dry environments.

### 7.7 Compressor phase state machine

```
idle ──(temp high)──→ warmingFan ──(30 ticks)──→ cooling
                            ↑                       │
                            │                       │
                            └────(temp low)─────────┘

cooling ──(60 min worked)──→ resting ──(5 min)──→ idle
```

Surfaced in the climate screen as a coloured phase indicator + status
text ("Прогрев вентилятора: ещё 280 с", etc.).

`noProbe` is a separate dead-end phase: the temperature sensor
returned -52 °C (or no reply at all), and the controller refuses to
run *anything* until a probe comes back. Safer than guessing.

---

## 8. Result code → user message

```
0  OK                  — "OK (пик X мА, Y мс[, drop Z ms])"
1  Overload            — "Ошибка: Перегрузка мотора"
2  Wire break          — "Ошибка: Обрыв провода"
3  Timeout             — "Ошибка: Мотор не завершил движение за лимит"
4  Curtain self-test   — "Ошибка: Датчик падения. Проверьте V1/SIG/GND"
5  Lock not opened     — "Ошибка: Замок не открылся"
10 Microswitch timeout — "Ошибка: Микропереключатель не сработал"
```

Localised strings live in `services/strings.dart` under `result_*`
keys. The full mapping is duplicated on the customer_web side
(`Admin.jsx` → `RESULT_CODE_I18N`) so the sales-history view shows the
same text the operator sees on-device.

---

## 9. Hooking it up — operator checklist

1. **First boot of a new tablet** → service mode → Плата → confirm
   "CRC-пароль" matches the firmware (mj2310 → ON, 2307 → OFF).
2. Layout Editor → pick template or build manually → save. The
   tablet auto-pushes the layout JSON to Supabase via
   `set_machine_layout` RPC.
3. Service mode → Настройка моторов → per slot:
   * Motor type (2-wire / 3-wire — match the wiring loom)
   * Drop-sensor override (or use the global toggle at the top)
   * Tap **Тест мотора** — should turn the spiral; result text below
     the slot.
   * Tap **Датчик** — forces curtain=1; result tells you whether the
     IR curtain is wired ([wiring guide §6.4 in `api_docsM109E.txt`]).
4. Service mode → Холодильник → mode + setpoint. Wait 5 min for the
   compressor (fan-spin-up). Confirm phase indicator transitions
   `idle → warmingFan → cooling`.

If `Get ID` times out after step 1, before touching anything else,
check (a) USB permission granted to the app, (b) CRC-password flag,
(c) board power. The "Плата" service-mode tab has a live RX log
showing every byte — RAW lines with no full frames means baud /
direction-pin issue; full frames but `result_code` errors mean we're
talking to the board but with the wrong CRC password.

---

## 10. References

- [`02_M102_PASSWORD.md`](02_M102_PASSWORD.md) — full CRC-password write-up
- [`03_FLEET_PROVISIONING.md`](03_FLEET_PROVISIONING.md) — getting a new tablet into device-owner kiosk mode
- [`../lib/board/board_client.dart`](../lib/board/board_client.dart) — protocol + heartbeat + watchdog
- [`../lib/services/climate_controller.dart`](../lib/services/climate_controller.dart) — refrigeration / heating loop
- [`../lib/models/climate_config.dart`](../lib/models/climate_config.dart) — DO channel enum + mode enum
- `/c/m109e/docs/01_PROTOCOL.md` — wire-format reference (repo-wide)
- `/c/m109e/api_docsM109E.txt` — original Chinese vendor doc
