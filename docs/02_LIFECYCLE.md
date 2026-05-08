# Vending Machine App — Operational Lifecycle Spec

> Reverse-engineered from `c:\m109e\snack_jadx\snack_jadx\sources\com\example\shuai\vendingmachine\`.
> Manifest entry: `activity.ShanpingYeActivity` (LAUNCHER). APK ID `com.shengma.huishu.hasakesitan`.

The codebase is a multi-protocol cabinet controller. It supports several driver-board generations:
- **815** (yipu-teng / eptonADH 815) and **814E** — primary lane drivers (default)
- **M102** — newer driver-board (this is what M109E hardware uses)
- **812** — lift/elevator board (sub-cabinets)
- **404** — coin/cash module
- **MDB**, **UCA2**, **ICK**, **SY**, **HuiYin POS**, **BaiFu POS**, **TR030/TR031/TR126/RY/RX/QY/DC** — payment / accessory peripherals

---

## Part A — Startup sequence

### A.1 `MyApplication.onCreate()` — `base/MyApplication.java:50-69`

Lightweight; does **not** open any serial ports. Initializes:

```java
public void onCreate() {
    super.onCreate();
    instance = this; mContext = this;
    beginCheckAPPRunning();         // LocalService + RemoteService keep-alive pair
    KLog.init(true);
    C0101App.getInstance().setExecutorService();
    Utils.init(this);
    SQLiteStudioService.instance().start(this);   // remote DB inspection
    UtilAPPHelper.getInstance(mContext);
    initCaocConfig();               // crash-restart -> ShanpingYeActivity
    initTecentBugly();              // Bugly + Beta auto-update
    m81init友盟();                   // UMeng analytics
    initAppConfig();                 // also startService(RebootService)
    m82init屏幕适配();                // AutoSize density adapter
    new NetWorkListenerUtils(mContext).startShowNetSpeed();
    PRDownloader.initialize(this, ...);          // OTA/asset download
    WCHUARTManager.getInstance().init(this);     // WCH USB-UART (CH340/CH341) driver
    setLanguage(this);               // 14 locales: zh-CN, zh-TW, en, ru, fr, mn, vi, es, km, sq, tl, lt, ur, de
}
```

### A.2 `ShanpingYeActivity` (splash) — `activity/ShanpingYeActivity.java`

The splash is the workhorse. Sequence (`onCreate` → `m37ks开始判断` → `m38ks开始进入程序`):

1. Single-instance guard (line 198) → restart whole APP if already running.
2. DNS / IP validation — `AppStaticMethods.checkIPAndDomainName()` registers 5 backend candidates (SM1, SM2, GX1, GX2, ZG).
3. **Reboot-loop protection** (line 362): 5 quick restarts within 20 s → `AtyGuZhangActivity` fault screen.
4. **First-run dialogs** (line 894):
   - Server selection + face-pay type
   - SN dialog: choose mainboard `恰友/定昌/其他`, write 23-char SN
   - Driver-board picker (line 587-660): **815 vs M102**, baud rate, serial path, 814E variant, encryption flag.
5. Fake-update animation (5 s sleep), sets `f2is假更新是否完毕 = true`.
6. **Network gate** — if `开机自启检测网络` is enabled, polls `checkNetWork()` every 2 s **forever** until network is up.
7. **App init** (`m38ks`, line 836): `initAppSystem` → `initAppConfigDate` (line 1012) loads server/socket settings, ad/screensaver mode, default password, lane creation if DB empty (`m24create创建货道`, line 1051).
8. **`beginSkip()`** (line 922) waits for both `f2is假更新是否完毕` && `f3is创建货道是否完毕`, sleeps 500 ms, calls `skip()` → `startActivity(HomeActivity.class)`, then `m33init初始化APP` (face-pay SDK init, cloud registration via `App.m852ljip3`).

### A.3 Background services

| Service | Process | Purpose | File |
|---|---|---|---|
| `LocalService` | main | Watchdog: foreground service, re-binds `RemoteService`; restarts app if dead | `service/LocalService.java:23-47` |
| `RemoteService` | `:RemoteProcess` | Counter-watchdog, AIDL stub | manifest line 130 |
| `ControlService` | main | EventBus consumer; humidity/temperature heater control; payment polling for SY/HS APIs; refunds | `service/ControlService.java` |
| `RebootService` | main | Daily auto-reboot at randomized time; runs every 50 s, fires `m933reboot(9)` if time matches | `service/RebootService.java:51-69` |
| `killSelfService` | main | Process-kill helper | `service/killSelfService.java` |
| `BootReceiver` | — | `BOOT_COMPLETED` → `appRestart()` | `receiver/BootReceiver.java` |
| `AlarmReceiver` | — | 12 alarms `com.gcc.alarm5..16` for light-strip and temperature schedules | `receiver/AlarmReceiver.java` |
| `APSService` | main | Amap geolocation foreground service | manifest line 135 |
| `AliveService` | main | Alipay zoloz/Smile2Pay liveness | manifest line 146 |
| `TinkerResultService` | — | Bugly hot-fix install | manifest line 145 |
| `TimerUpInsert` | thread | Periodic data uplink | `service/TimerUpInsert.java` |

### A.4 Initial board handshake (boot-time discovery)

The board is **not** opened by `MyApplication`. It's opened later from `HomeActivity.initData()` → `AppStaticMethods.appStartMainAty(mContext)` (`HomeActivity.java:593`, `AppStaticMethods.java:757`):

```java
public static void appStartMainAty(Context context) {
    SocketThreadManager.sharedInstance();   // 9 socket threads (in/out/heartbeat/ping/net/...)
    TimerUpInsert.getInstance().m555start();// periodic upload
    UtilADH.getInstance().m251dk();         // OPEN DRIVER SERIAL PORT
    UtilMDBControler.getInstance().getCountry();
    if (cashEnabled || icCardEnabled) { ... openCOM or USB ... }
    if (printer) TTLManager...open(...);
    if (sySerial) UtilSY.m523dk();
    if (huiYinPos) UtilHuiYin.m459dk();
    if (uca2) UtilUca2.m541dk();
    if (baiFuPos) BaiFuUtils.init(true).getTerminalInfo(...);
}
```

`UtilADH.m251dk打开串口客户端` (`UtilADH.java:72-81`):

```java
public void m251dk打开串口客户端() {
    startThreadSendCMD();         // ThreadADH (TX queue)
    startThreadPollCMD();         // C0082ThreadADH (poll timer)
    getInstance().m274initADH814E();
    if (getWhichSerialport() == 1) UsbUtil.getInstance().findUSB();   // TR030/RY use USB-CDC
    else COMADH.getInstance();    // standard /dev/ttyS*
}
```

After serial port opens, `UtilADH.initADH()`:

```java
public void initADH() {
    if (!C0085UtilADH.f173FLAG_.equals("M102")) m242go815设置815驱动板的工作模式();
    else m241goM102查询M102驱动板的版本号();
    setTemAndLight();
}
```

**M102 boot-time handshake** (`m241goM102`, `UtilADH.java:225-260`):
1. `m253gbM102关闭M102货道控制板所有开关量` — closes all 5 relays per cabinet (4 stations × 5 outputs).
2. `m247cxM102` queries firmware ID for each station via cmd `0x01`.
3. After 3 s, EventBus broadcasts "set light & temp" events.

Polling thread `C0082ThreadADH` starts after 1000 ms delay, polls every **900 ms** (`C0082ThreadADH.java:97`) to station 01 (always) plus stations 02/03 if sub-cabinet flags `SETTING_DEPUTY01/02` are enabled.

**Inventory on boot is read from local GreenDAO `GoodEntity` table**, not from the board. Cloud sync via `socket/ParseSocket` can rewrite prices/statuses (`parseSetVendorPrice` at line 59).

**Time sync**: not done at boot; app sends its own timestamp upstream in every command frame (`Utils.getCurrTime()` → 6-byte yyMMddHHmmss UTC).

---

## Part B — Idle/home behavior

### B.1 `HomeActivity` UI (`shouhj/activity/HomeActivity.java`)

`onCreate` → `initData` → `initView` → `initFgm`. Layout `R.layout.activity_home`:

- Top bar: device-ID, signal indicator, temp/humidity for main cabinet + sub-1 + sub-2.
- **Product grid**: `goodsRecyclerview` is `GridLayoutManager(3 or 4 cols)` with `GoodsNewListAdapter` showing `ShowGoodsItem`s.
- Side rail `layerRecyclerview` shows cabinet floors via `CFLayerAdapter`.
- Banner / Video attract loop based on `Contants.GUANGGAOTYPE` and `ADVTYPE`.
- Auto-scroll every 10 s (idle handler `SCROLL=2`).
- Cart popup `GoodsCarPopupWindow` from `goodscarLayout`.
- USB IC card reader: `usbIck` EditText with IME action listener; on Enter → `Jiexick.parse(string)` (line 717-731).
- PoliceCamera: 1 s after launch, `UtilPoliceCamera.initPolicing` starts UVC live recording (line 821-839).

**Hidden admin gestures** (line 733-748):
- 5 s long-press on `topLayout` → device-QR (`AtySbidErwm`)
- 5 quick taps → EventBus `f669FLAG_SHANGHAIMAINACTIVITY_` enters settings

### B.2 Periodic polling (two layers, both ~900-1000 ms)

1. **Driver-board polling** — `C0082ThreadADH.java:97` `Thread.sleep(900)`. Sends 815/M102 poll cmd `0x03` to each connected station.
2. **Server heartbeat** — `SocketHeartThread.java:38-58`, default 30 s. Each tick:
   - Retransmits pending out-good-status reports from local DB
   - Calls `CMD.m1254fs发送上报售货机所有状态的命令()` → `vendorStatusReport()` (`CMD.java:243-312`) — frame `01710022...` containing device-ID, software version, lane count, **per-lane status hex byte**, **per-lane inventory hex byte**, **per-lane price**, signal level, current time. **Critical status report packet.**

### B.3 Sensor readings (temp/humidity)

Driver-board poll response carries SD/WD readings → `ReportSdEvent` on EventBus → `ControlService.getSd(ReportSdEvent)` (line 241-313):

For each address `01` (main), `02` (sub1), `03` (sub2):
- If humidity ≥ threshold (`sd_zg`/`sd_fg1`/`sd_fg2`, default 60% from SP `M109XZSDMAXZG/FG1/FG2`) AND heater (`isStart_M102_maps[addr+"02"]`) is OFF → send `sendM102Order(addr, "08", "02010000…")` to **turn heater ON**.
- Else if heater ON → `…02000000…` to turn OFF.
- Sensor-read failure also turns heater OFF (safety).

Light-strip and temperature schedules driven by `AlarmReceiver`. Three modes per `m1037get`:
- `0` = always on (`UtilADH.m275onOFF("01")`)
- `1` = always off (`m275onOFF("00")`)
- `2` = scheduled (3 ON + 3 OFF alarms)

---

## Part C — Dispense flow (CRITICAL)

### C.1 Selection → cart

User taps tile → `GoodsNewListAdapter` looks up `GoodEntity` by `HD` (lane code, hex 2-byte) → adds to static cart `ShanghaiMainActivity.list_goodscar` → opens `GoodsCarActivity` or jumps to `PayActivity` if cart-mode is disabled.

`GoodsCarActivity.initData` (`gouwc/GoodsCarActivity.java:307`) reads payment-mode SP flags and calls `initShowPay()` which picks UI by priority: `showFacePay` → `showQRCodePay` → `showWxCodePay` → `showAliCodePay` → `showCashPay` → `showICCardPay` → `showFSPay`.

On confirm: `SocketThreadManager.sendMsg(CMD.payRequestCore_more("08"|"07"|"06"|..., list_goodscar))` sends "payment request" → server replies with QR via `ParseSocket.m1202jx (cmd 7102)` rendered into `imgEwm`.

### C.2 Payment (`PayActivity`)

`singleTask` activity. Pay-type extras: `HUIYIN`, `BAIFUPOS`, `WECHATPAY`, `ALIPAY`, `ICCARDPAY`, `ICCARDPAYUSB`, `FSPAY`, plus 20+ Southeast-Asia variants (`MOMO_PAY`, `VNPAY`, `VIETQR_PAY`, `QPAY_MNT`, `JEJSST_QR`, `YLK_QR`, `AIJI_QR`, `ZaloPay`, `THQR_PAY`, `QR_PH_PAY`, `WECHAT_ALIPAY`, `QRIS_PAY`, `DUITNOW_PAY`, `WECHAT_SY_PAY`, `KHQR_PAY`, plus `_API` variants, `SETTING_PAY_HUISHU`).

Three pay-channel families:

| Family | Implementation | Notes |
|---|---|---|
| **Server-mediated QR** (`08`/`07`/`06`) | `SocketThreadManager.sendMsg(CMD.payRequestCore_more)` → server QR → user scans → server pushes `01710003` → `GotoOutGoodsThread` parses and dispenses | Alipay/WeChat/generic via own backend |
| **Direct REST API** (`SY`, `HS`, `BaiFu`, `HuiYin`) | `getQrCodeSYAPI` → `RetrofitClientSY.createOrderSY()` → QR rendered → `CheckPaySYResultEvent` → `ControlService.pollSyOrderPay` polls every 2 s, max 150 attempts (5 min) | Each region has its own client class |
| **Hardware** (`ICCARDPAY`, `FSPAY`, `MDB`, `UCA2`, `BaiFuPos`, `HuiYinPos`, cash) | Routed through serial-port helpers (`UtilMDBControler`, `UtilUca2`, `Utilick`, `BaiFuUtils`, `UtilHuiYin`) | |

Pay-type lookup keys (`utils/CMD.java:31-77`):
- `04` online, `06` pickup-code, `07` IC card, `88` test
- `FA` MDB POS, `FB` desk-swipe, `FC` finger, `FD` POS, `FE` cash bill, `FF` cash coin
- `AB` SY box, `AC` SY API, `AD` BaiFu POS, `AE` Hui-Shu API

Successful payment ultimately produces `01710003`/`01710004`/`0130xx` frame → feeds `GotoOutGoodsThread`.

### C.3 `OutGoodsActivity` and the dispense engine

`OutGoodsActivity` is a **status view only** — registers EventBus, builds per-item list with status `0`(queued)/`1`(success)/`2`(fail), self-finishes after 150 s. Real motor logic is in **`GotoOutGoodsThread`** (background thread receiving via `SocketThreadManager.goRunThreadGotoOutGoods(cmdHex)`).

**Dispense engine — `socket/GotoOutGoodsThread.java`:**

```java
public void run() {
    while (this.isStart) {
        synchronized (this.list_cmd) {
            for (String str : this.list_cmd) {
                parseCmd(str);              // (1) parse server frame
                Thread.sleep(1000);         // (2) 1 s gap between frames
            }
        }
        if (list_cmd.empty) wait();
    }
}
```

`parseCmd` (line 134) recognizes:
- `01 71 03/04 ...` — single-lane dispense
- `01 30 ...` — multi-lane (cart) dispense; second byte = pay-type code

Extracts 28-char `orderNo`, sends ack `CMD.return_chhf(orderNo)` (server frame `0230001D...`), drives motors:

```java
private synchronized int outGoods(int i) {                  // i = lane index (0-based)
    boolean is812 = AppStaticMethods.m72get(i);             // 812 lift?
    boolean isMerged = C0101App.getInstance().m905get(i);   // merged-lane?
    boolean isDouble = SPUtils.MESSAGE_HEBINGHUODAO;
    this.is_suc = true; this.outGoods_suc = 0;
    this.m1198xg(this.nolog_outgood_more, "03");            // mark in-progress in DB
    C0085UtilADH.getInstance().m362out_(isDouble, isMerged, is812, i, new ListenerADH() {
        public void onSuc(int i, String code, String msg) { m1199set(0); }
        public void onFai(int i, String code, String msg) { m1199set(1); }
    });
    while (this.is_suc) Thread.sleep(100);                  // block
    return this.outGoods_suc;                                // 0=ok, 1=fail
}
```

**Motor command — `C0085UtilADH.m362out控制电机出货_购买` (`C0085UtilADH.java:245`):**

```java
public void m362out_(boolean isDouble, boolean isMerged, boolean has812, int laneIdx, ListenerADH cb) {
    if (m353pd(laneIdx) /* range check */) {
        m349get(laneIdx);                       // resolve f178dj (motor index 1..n) and station addr
        f188is.put(addr, true);
        m348get(laneIdx);
        if (laneIdx==-1 || addr=="FF") { m358hd("DIS","站地址不合法"); return; }
        if (!App.m850get(addr) /* board comm-OK */) { m358hd("RUN2","驱动板通讯故障"); return; }
        if (has812) {                           // first move the lift
            m347get812(laneIdx);
            f186dj = (f178dj/10)+1;             // floor index
            m350kq开启升降机;                    // run 812 elevator
            return;                              // motor RUN happens after lift completes
        }
        m352kz控制货道电机转动出货();             // direct motor RUN
        return;
    }
    m358hd("13","电机号不合法");
}
```

`m352kz` decides single vs double motor:

```java
private void m352kz() {
    if (this.f191isDouble) m355run启动双电机(this.f192isMerged);
    else m354run启动单电机();
    m351kq开启出货等待计时器;
}
private void m354run() {                         // SINGLE MOTOR
    String idHex = HexUtil.m1301get0(HexUtil.m1293getInt(f178dj), 1);
    if (f173FLAG_.equals("M102")) {
        CreatADH.sendM102Order(addr, "05", idHex+f176M102+f174M102+f175M102+"00"+f177M102+"0".repeat(20));
    } else {
        CreatADH.m159run(addr, idHex);            // 815 RUN cmd 0x05
    }
}
```

Wire format summary:
- **0x05** = single-motor RUN
- **0x07** = double-motor RUN2 (815 only)
- **0x03** = poll
- **0x06** = ACK
- **M102 0x08** = relay/switch
- **M102 0x05** = motor

Polling thread receives status frames:
- "good fall" / "出货完成" → `m359hd出货成功回调` → `ListenerADH.onSuc`
- timeout / no-fall → `m358hd出货失败回调` → `onFai`

For 812 lifts: success/failure first sends `wc812出货完成` frame (`CreatADH.m168wc812(floor, "01"|"02"|"03")`) so lift returns; then listener fires.

**Multi-item carts — sequential, one motor at a time** (`outGoodMore`, line 374):

```java
private void outGoodMore(int i) {
    int idx = nolog_outgood_more;
    if (idx >= nolog_outgood_more_max) { Thread.sleep(1000); m1188gwc(i); return; }
    int laneIdx = Integer.valueOf(list_outgood_more.get(idx), 16) - 1;
    GoodEntity good = GoodHelper.where(getHD(laneIdx));
    if (good == null) { m1191lj(1, i, laneIdx); return; }
    if (!"88".equals(payType)) {                                                        // skip checks in test
        if (Integer.valueOf(good.getInventory(),16) <= 0) { m1191lj(1,i,laneIdx); return; }   // OUT OF STOCK
        if (!"00".equals(good.getStatus_HD())) { m1191lj(1,i,laneIdx); return; }              // FAULTY LANE
    }
    if (mergedLane && !validForMerged) { m1191lj(1,i,laneIdx); return; }
    if (i == 1 /* cash */ && coinAcceptedTotal < good.price) { m1191lj(1,i,laneIdx); return; }
    m1191lj(outGoods(laneIdx), i, laneIdx);                                             // FIRE motor (blocks)
}
```

**No retry** at the engine level — failed lane is reported and sequence moves on.

### C.4 Failure handling

- **Inventory check** before each motor pulse — refuses if `inventory == 0`
- **Fault check** — refuses if `status_HD != "00"`
- **Lift fail** — handled in 812 listener; if lift returns code `"03"` (test) it's tolerated
- **Communication loss** — 4 missed polls → station DOWN → dispense rejected with `RUN2/驱动板通讯故障`
- **No light-curtain logic in app** — fall-detection delegated to driver-board firmware
- **Refund** — failed item after payment → `m1188gwc` builds `CMD.outGoodsCarOutResult(...)` encoding `"E3"` (fail) per item. For HS/SY/BaiFu API pays this triggers upstream refund (`HsRefund` for `pay_type=HS_API_PAY`, `ControlService.getRefundHs` line 622). For server-pushed pays, server reads `E3` and refunds user account.
- **Local fallback** — failed orders kept in `LinShiOrder` (`LinShiOrderHelper`); deleted after 150 poll failures
- **Timeout** — `OutGoodsActivity` self-finishes after 150 s

### C.5 Logging / report-back

For each dispense:
1. Per-item status to `KongzChuhuoGuocEntity` GreenDAO table with `stateChuoh = "FF"` (in progress) → `"03"` (success) / `"E3"` (fail)
2. Out-good result frame via `CMD.outGoodsCarOutResult(...)` (cart) or `CMD.outGoodOneOutResult(...)` (single) → `SocketThreadManager.sendMsg(...)` → `goRunThreadOutGoodStatus()` queues retransmit until server acks (rows in `OutGoodStatusEntity` until ack `01710003`/`01710001`)
3. **OrderEntity** local DB: `goodsname`, `hds`, `unit_price`, `money`, `pay_type`, `orderSn`, `thirdSn`, `time`, `status`, `isUp`, `isOut`
4. Next 30-s `CMD.m1254fs` heartbeat includes new inventory and lane status
5. **Police camera**: `EncodCamera2OrderMp4`/`EncoderOrderMp4` (UVC) saves per-order mp4 keyed on `orderNo` if `IsOpenPolicing` set

---

## Part D — Operator/maintenance

### D.1 Service-mode entry

| Activity | Trigger |
|---|---|
| `ShanpingYeActivity` (splash) | 5 s long-press OR 5 quick taps on 4 invisible regions (`rlSz`, `rlJrsz`, `rlFhzm`, `rlSerial`) → `ViewOnClickListenerC0088Aty.startActivity(ctx, 3)` (settings) or `4` (return-to-launcher). `activity/ShanpingYeActivity.java:251-298` |
| `HomeActivity` (idle) | 5 s long-press on `topLayout` → device-QR; 5 quick taps → settings. `shouhj/activity/HomeActivity.java:733-748` |
| `SettingActivity` engineer mode | Password validated against `MD5("shengma" + last4(deviceSN) + yyyyMMdd).substring(-4)` (last 4 hex chars of MD5, daily-rotating). `setting/SettingActivity.java:638-651` |

Default settings password: `AppConfig.SETTING_PASSWORD` (set first-run).

### D.2 `MachineTestActivity` modes (`setting/MachineTestActivity.java`)

Four modes:
- `"全部测试"` — fire every lane once sequentially
- `"按层测试"` — fire all lanes on a single layer
- `"按号测试"` — fire one specific lane (range)
- `"压力测试"` — repeatedly fire lanes with counter

All call `C0085UtilADH.m361out控制电机出货(...)` — same code path as a real purchase but bypasses payment.

### D.3 Lane / motor / inventory schema

`entity/greendao/GoodEntity.java`, table `GOOD_ENTITY`:

| Field | Type | Meaning |
|---|---|---|
| `id` | Long | PK |
| `name`, `img`, `content`, `manufacturer`, `specification` | String | Display |
| `HD` | String (hex) | **Lane code** — 2-digit hex `"01"`...`"96"` (1-based on wire) |
| `inventory` | String (hex) | Stock count (max FF=255) |
| `price` | String (hex) | Hex-encoded cents — `getPrice() × 0.01` = display unit |
| `status_HD` | String | `"00"` OK, else fault |
| `rl_hd` | String (hex) | "Real lane" — physical motor index for merged lanes |
| `setNo` | String | Grouping/floor key |
| `expiredTime` | int | Best-before days |
| `shoppingCart` | bool | Included in cart-mode |
| `zhek` | int | Discount % 1-99 |
| `isHebhd` | bool | This lane merged with adjacent (double-wide products) |
| `isShowBukgm`, `show` | bool | UI flags |

**Lane code → station address + motor index** mapping in `C0085UtilADH.m349get`/`m348get`:
- `f134CMD__` (station addr) is `"01"` (main), `"02"` (sub-1), `"03"` (sub-2), `"04"` (sub-3); decoded from high digit of lane number.
- `f178dj` (motor index 1..50) is the low part.
- For 812-lift cabinets, floor is `(f178dj/10)+1`.

Sub-cabinet enable flags: `Contants.SETTING_DEPUTY01/02` SP keys.

`OperatingModeHelper` stores per-station per-floor work-mode for M102.

`KongzChuhuoGuocEntity` is live "lane-action audit" table (cleared after each cart cycle).
`OrderEntity` is persistent transaction log (uploaded by `TimerUpInsert`).

---

## Summary parameters

| Parameter | Value |
|---|---|
| Driver-board poll interval | 900 ms |
| Server heartbeat interval | 30 s default |
| Comm-loss tolerance | 4 missed polls per station |
| Out-good page timeout | 150 s |
| Reboot-loop guard | 5 restarts in 20 s → fault screen |
| Auto-reboot | random `0[3-7]:[10-50]` daily |
| Inventory hex range | 00..FF per lane |
| Lane status 00 = OK, else fault | |
| Pay-types | `04` online, `06` pickup, `07` IC, `88` test, `FA` MDB, `FB` desk, `FC` finger, `FD` POS, `FE` bill, `FF` coin, `AB`/`AC` SY, `AD` BaiFu, `AE` HS |
| Default password | `SETTING_PASSWORD` or daily MD5 from `shengma + SN-last-4 + yyyyMMdd` |
| Serial defaults | parity=0, data=8, stop=1 |
| Driver families | 815 (default) / 814E / M102, plus 812 lift, plus 404 cash |
| Station addresses | `01`=main, `02`=sub1, `03`=sub2, `04`=sub3; lift = `0A/0B/0C` |
| Wire cmds (815) | `01` ID, `03` poll, `05` RUN1, `06` ACK, `07` RUN2, `20/21` work-mode rd/wr, `30/31` motor-threshold rd/wr |
| Wire cmds (M102) | `01` version, `03` poll, `05` motor, `08` relay/switch |
| Wire cmds (812 lift) | `08` complete, `09` clear-fault, `0C` set-coords, `11` floor-position |

Architecture cleanly separates: **(a) UI flow** (Activities), **(b) state engine** (`GotoOutGoodsThread`, `ControlService` event-bus), **(c) board protocol** (`UtilADH`/`CreatADH`/`C0082ThreadADH` polling, `C0085UtilADH` motor logic), **(d) cloud protocol** (`SocketThreadManager` + `CMD`/`ParseSocket`), **(e) persistence** (GreenDAO entities).
