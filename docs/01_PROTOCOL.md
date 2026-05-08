# M109E / M102 Vending Driver Board — Serial Protocol

> Reverse-engineered from the factory app at `c:\m109e\snack_jadx\snack_jadx\sources\com\example\shuai\vendingmachine\` (internal brand "毅普腾" / Yi-Pu-Teng).

The decompiled app speaks **five different serial protocols** depending on which sub-board is attached. The one matching `vending_ctrl.py` and the M109E hardware is the **M102 driver board** — the wire format is identical: 20-byte fixed-length frame, Modbus CRC-16, 9600 baud.

All M102-related code lives under `…\mserialport\eptonADH\` and `…\mserialport\usb\`. The other directories (`huiyin`, `mdb`, `ick_sm`, `uca2`, `trusbcom`, `sy`) are for payment terminals — ignore them for the driver board.

---

## Transport layer

The app supports two transport modes chosen by the system "flag":

1. **Direct UART** — TTL serial through `/dev/ttyS<N>` or `/dev/ttyUSB<N>` opened via `com.deemons.serialportlib.SerialPort`.
2. **USB-to-UART bridge** — uses `com.hoho.android.usbserial` to talk to a CH340/CH341 chip.

| Setting | Value (M102) | File:line |
|---|---|---|
| Library | `com.deemons.serialportlib.SerialPort` (jni wrapper) | `mserialport/eptonADH/COMADH.java:6` |
| Default port name | `ttyS` + index (default 1, configurable in SP) | `base/AppConfig.java:31, 91` |
| Format | `/dev/ttyS<N>`, e.g. `/dev/ttyS1` | `mserialport/eptonADH/COMADH.java:46-50` |
| Baud rate (M102) | **9600** (`AppConfig.BOTELV1 = 9600`) | `base/AppConfig.java:28`, `shouhj/app/C0100App.java:15` |
| Baud rate (ADH815) | 38400 (`AppConfig.BOTELV`) | `base/AppConfig.java:27` |
| Data bits / parity / stop | **8 / none / 1** | `mserialport/eptonADH/COMADH.java:53-55, 60` |
| USB VID / PID | **0x1A86 / 0x7523** = QinHeng CH340/CH341 | `mserialport/usb/UsbUtil.java:100` |
| USB params | `9600, 8, 1, 0` (parity = NONE) | `mserialport/usb/UsbUtil.java:145` |

**Auto-discovery** — `Util.searchSerial()` (`Util.java:46-105`) iterates ports, sends a probe at each baud, accepts the first that returns ≥ 2 valid replies. Hard-coded probe for M102:

```
01 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 EA D1   @ 9600
```

(addr=01, FUNC=03 POLL, 16 zero data bytes, CRC=EAD1).

### Frame format (M102)

Fixed-length **20 bytes** for both request and response (`Parse.java:84` rejects ≠ 40-char hex).

```
+-------+-------+----------------------------------------+-------+
| ADDR  | FUNC  |  16-byte DATA payload (zero-padded)    | CRC16 |
|  1B   |  1B   |              16B                       |  2B   |
+-------+-------+----------------------------------------+-------+
```

- **ADDR** — 1-byte slave address (`01`–`04`), `00` broadcast. Reply uses the same address.
- **FUNC** — 1-byte function/opcode.
- **DATA** — exactly 16 bytes, unused trailing bytes = `0x00`. Constant `Flag.f291CMD_M102_ = "00000000000000000000000000000000"` (`entity/Flag.java:237`).
- **CRC16** — 2-byte Modbus CRC-16, **low-byte first on the wire**.

Frame builder: `entity/M102.java:20` (`getM102出货驱动板指令`) concatenates `address+order+data+check`. CRC appended in `CreatADH.m141biany()` at `CreatADH.java:386`.

### Multi-board / RS-485 addressing

The bus is RS-485 multi-drop. The app supports up to **four M102 boards**:

| Address | Role | Constant | File:line |
|---|---|---|---|
| `00` | Broadcast (used for SET-ADDRESS reply) | `f277` | `entity/Flag.java:195` |
| `01` | 主柜 — main cabinet | `f278` | `entity/Flag.java:198` |
| `02` | 副柜1 — sub-cabinet 1 | `f279` | `entity/Flag.java:201` |
| `03` | 副柜2 — sub-cabinet 2 | `f280` | `entity/Flag.java:204` |
| `04` | 副柜3 — sub-cabinet 3 | `f281` | `entity/Flag.java:207` |
| `FF` | "未配置" / unset / probe | `C0085UtilADH.f134` | `C0085UtilADH.java:32` |

Poll thread `C0082ThreadADH.run()` cycles every **900 ms** and sends a separate POLL to each enabled cabinet (`C0082ThreadADH.java:139-166`). After 4 missed POLLs a cabinet is flagged "通讯中断" / comm fault (`CreatADH.java:667-717`).

---

## CRC implementation

Modbus CRC-16, polynomial `0xA001`, init `0xFFFF`, reflected, then byte-swapped before sending. From `utils/CRC.java:39-52`:

```python
def crc16_modbus(data: bytes) -> bytes:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return bytes([crc & 0xFF, (crc >> 8) & 0xFF])  # low byte first
```

This matches the implementation in `vending_ctrl.py:30-40`.

---

## Command catalog

Source: `entity/Flag.java:218-234` + `mserialport/eptonADH/CreatADH.java:333-389` + `ParseM102.java:46-66`. All sends go through `CreatADH.sendM102Order(addr, order, dataHex)`.

| Func | Name | Constant (Flag.java) | Request DATA (16 B) | Response DATA |
|---|---|---|---|---|
| `0x01` | **ID** — query firmware | `f285` (line 219) | 16 × `0x00` | bytes 10..(N-4) ASCII firmware |
| `0x03` | **POLL** — controller status | `f286` (line 222) | 16 × `0x00` | b0=state (00 idle / 01 dispensing / 02 finished); b1=motor#; b2=result; b3-4=Imax mA; b5-6=Iavg mA; b7-8=runtime×0.1s; b9=light-curtain blocked time×0.1s |
| `0x05` | **RUN** — start motor | `f287` (line 225) | b0=motor index (0..299); b1=type; b2=curtain; b3=switch delay; b4=00; b5=A0/00 timeout flag; rest=0 | b0 = 00 OK / 01 invalid index / 02 busy |
| `0x07` | **TEMP** | `f289` (line 231) | 16 × `0x00` | b2-3 = (raw_int16 − 20) × 0.1 °C; -52.0 = no sensor |
| `0x08` | **DO** — relay output | `f288` (line 228) | b0=output#; b1=state (00/01); rest=0 | echo + verify |
| `0x10` | **HUM** — humidity | `f290` (line 234) | 16 × `0x00` | b1=%RH; b3 < 10 ⇒ sensor OK |
| `0xFF` | **SET-ADDR** | (only RX side parsed) | — | board echoes new addr as `<NEW>FF…CRC`; parsed at `Parse.java:90-93` |

> **Note:** `vending_ctrl.py` also implements `0x04` (SCAN) and `0x09` (DI). The factory app does NOT use these for M102; it reads switch states implicitly via POLL response. They likely still work on the M109E firmware.

### Motor RUN (0x05) payload — exact byte map

From `C0085UtilADH.m354run()` (`C0085UtilADH.java:319-326`):

```
DATA[0]  motor index 0..299  (100..199 = sub1, 200..239 = sub2, 240..299 = sub3)
DATA[1]  motor type code:
            00 / 0C  electromagnetic lock  (forward / reversed)
            02 / 0A  2-wire motor          (forward / reversed)
            03 / 0B  3-wire motor          (forward / reversed)
DATA[2]  light-curtain mode:  00=none, 01=present, 02=priority
DATA[3]  micro-switch delay (seconds, hex). 00 unless type ∈ {4,5}, then = ys setting
DATA[4]  0x00
DATA[5]  motor-timeout flag: A0 if extended timeout, else 00
DATA[6..15]  ten zero bytes
```

### DO (0x08) payload table

| DATA[0] | Channel | Constant | DATA[1] |
|---|---|---|---|
| `00` | Fan / 风机 | `f302` | `00` off / `01` on |
| `01` | Compressor / 压缩机 | `f300` | same |
| `02` | Heater-glass / 加热玻璃 | `f299` | same |
| `03` | Light strip / 灯带 | `f301` | same |
| `04` | Heater module / 加热模块 | `f298` | same |

Real frames seen in source:
- `01 01 00…` — compressor ON  (`C0101App.java:2024`)
- `02 01 00…` — heater-glass ON  (`ControlService.java:250`)
- `04 01 00…` — heater module ON  (`C0101App.java:2082`)

### Error / result codes (POLL byte 2 / RUN result)

From `ParseM102.m179zx()` (`ParseM102.java:131-233`):

| Code | Meaning |
|---|---|
| `0` | OK / no error |
| `1` | Overcurrent (jam, stuck) |
| `2` | Motor wire broken |
| `3` | Timeout, position signal not detected (jam, heavy load, PSU noise) |
| `4` | Light-curtain self-test failed; motor not started |
| `5` | Solenoid door didn't open (no feedback) |
| `10` | 3-wire motor: micro-switch not pressed within 1.5 s |

When light curtain is enabled, drop detection uses POLL byte 9 (blocked time > 0 ⇒ product fell).

---

## Real frame examples

### 1. Auto-detect probe (POLL @ addr 01)
Hard-coded at `Util.java:70`:

```
01 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 EA D1
```

### 2. RUN motor #15 (3-wire, no curtain) on main cabinet

```
ADDR=01  FUNC=05  DATA[0]=0F  [1]=03  [2]=00  [3]=00  [4]=00  [5]=00  [6..15]=00
01 05 0F 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 3F C9
```

CRC16-Modbus(0x01050F03000000000000000000000000000000000) = 0xC93F → on wire low-first: `…3F C9`.

Board ack: 20 bytes with FUNC=`05` and DATA[0]=`00` (accepted), `01` (bad index), or `02` (busy).

### 3. Turn ON compressor, sub-cabinet 1
From `C0101App.java:2036`. `sendM102Order("02", "08", "01010000…")`:

```
02 08 01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 <CRC>
```

### 4. POLL response — dispense finished OK

```
state=02 finished, motor=0F, result=00 OK, Imax=0x05C8 (1480 mA),
Iavg=0x0398 (920 mA), runtime=0x2F (4.7 s), curtain=00 (no drop)

01 03 02 0F 00 05 C8 03 98 00 2F 00 00 00 00 00 00 00 <CRC>
```

---

## Implementation gotchas

- **100 ms inter-command spacing** in `ThreadADH.run()` (`ThreadADH.java:64`) is mandatory.
- **Comm-loss recovery**: 4 missed POLLs → cabinet "故障" flag. 2 of those at system level → `UsbUtil.restartCOM()` and eventually tablet reboot via `C0101App.m933reboot(5)`.
- **Two-board rules**: when running M102 the app forces `C0085UtilADH.f173FLAG_ = "M102"` (`C0082ThreadADH.java:81`), disabling the ADH815 polling path.
- **Power-on init sequence** (`UtilADH.m241goM102` at `UtilADH.java:131-142`):
  1. Turn off all DOs (sends 0x08 with each output index = 0)
  2. Query firmware (0x01) on every enabled cabinet
  3. Once any 0x01 response arrives, start temperature timer (0x07 every 10 s, `TimerM102.java:82-93`), humidity timer (0x10, `C0083TimerM102.java:79-87`), and the 900 ms POLL loop.

---

## Key file references

- `mserialport/eptonADH/COMADH.java` — direct-UART transport
- `mserialport/usb/UsbUtil.java:100` — CH34x USB-serial transport (VID/PID)
- `mserialport/eptonADH/Util.java` — auto-port discovery + probe frames
- `mserialport/eptonADH/CreatADH.java` — frame factory (`sendM102Order`, `m141biany` adds CRC)
- `mserialport/eptonADH/ParseM102.java` — response dispatcher (cases 01/03/05/07/08/10), result decoding
- `mserialport/eptonADH/Parse.java:84` — top-level demux + 20-byte length / CRC verification
- `mserialport/eptonADH/C0082ThreadADH.java` — 900 ms RS-485 polling loop
- `mserialport/eptonADH/C0085UtilADH.java:319-326` — high-level dispense state machine, motor RUN payload assembly
- `mserialport/eptonADH/TimerM102.java`, `C0083TimerM102.java`, `C0084TimerM102.java` — periodic timers (temp, humidity, DO refresh)
- `mserialport/eptonADH/entity/M102.java:20` — frame structure
- `mserialport/eptonADH/entity/Flag.java:218-234` — every opcode/address/motor-type/error-code constant
- `utils/CRC.java:39-52` — Modbus CRC-16 (matches `vending_ctrl.py`)
- `base/AppConfig.java:27-31` — port / baud defaults
- `shouhj/app/C0101App.java:1949-2125` — temperature/humidity control loop with real DO frames
- `service/ControlService.java:240-310` — humidity-driven DO control with concrete frame examples
