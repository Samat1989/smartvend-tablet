# Peripherals, Configuration & Cloud Integration

> Reverse-engineered from `c:\m109e\snack_jadx\snack_jadx\sources\` and `c:\m109e\snack_apktool\snack_apktool\`.

App package: `com.shengma.huishu.hasakesitan` (Java root: `com.example.shuai.vendingmachine`). Target market: **Kazakhstan** (app label "哈萨克斯坦", currency `KZT`, country `KZ`). Board family is **盛马 ShengMa M102 / 毅普腾 EPTON ADH** with sub-boards **815** (lane driver), **812** (lift/elevator), **404** (cash controller).

---

## 1. Peripheral controls

All peripherals on M109E sit behind one of two control boards over the UART. The "M102" driver board is the one this hardware uses. Lighting, compressor, glass heater, fan and heating module are exposed as five **digital outputs** addressed by 1-byte device ID + 1-byte state.

Source: `mserialport/eptonADH/entity/Flag.java:266-302`

```
00 = 风机     fan
01 = 压缩机   compressor
02 = 加热玻璃 glass heater (anti-fog)
03 = 灯带     LED light strip
04 = 加热模块 heating module
state byte: 00 = off, 01 = on
```

Frame: address (`01`/`02`/`03` = main / sub-1 / sub-2 cabinet) + opcode `08` + 16-byte payload `<deviceId><state>00…`.

Helpers in `UtilADH.java:984-1101` (`setADH814E风机开/关`, `setADH814E压缩机开/关`, `setADH814E加热玻璃开/关`, `setADH814E加热模块开/关`, `setADH814E灯带开/关`, plus `openLightM102/closeLightM102`). State mirrored in `AppConfig.isStart_M102_maps` keyed `<addr><deviceId>` (e.g. `"0101"` = main cabinet compressor).

### Lighting (灯带, LED strip)
- Toggle: `UtilADH.m275onOFF("01"|"00")` at `UtilADH.java:317-334`. For each cabinet `01..04`, sends M102 cmd `08` payload `0301...` ON or `0300...` OFF.
- Schedule: SP key `SP_FLAG_灯带模式` (mode 0=all-day on, 1=all-day off, 2=time slots). Time slots stored under `f711..f713SP_FLAG_灯带设置时间_1组/_2组/_3组`. Wired into `AlarmReceiver` (`com.gcc.alarm5..10`) and `ControlService.m554set设置灯带闹钟` (`ControlService.java:182-202`).

### Refrigeration / compressor (压缩机) and the temperature loop

- **Temperature read-back**: M102 opcode `07`. Polled every 10 s by `TimerM102.java:115` for `01` then conditionally `02`/`03` (sub cabinets). Reply parsed in `ParseM102.java:308-371` — temperature in °C is `(int16(rawHex) − 20) / 10`. Probe-missing sentinel = −52 °C; after 5 such reads the cabinet is flagged "no probe".

- **Set-point storage**: per cabinet "mode" + integer °C (`UtilADH.java:336-403`, `setMain/Sub1/Sub2温控`). Mode codes:
  - `00` 常温 ambient (off)
  - `01` 制冷 cooling
  - `02→10` 加热 heating
  - `03→11` 禁用 disabled

- **Hysteresis** in `ParseM102.operate(...)` (`ParseM102.java:392-477`): constant `4.0` is added/subtracted from set-point.
  - Cooling (mode `01`): `temp < setpoint` → EventBus `FLAG_M102_判断强停` (force compressor off). When `temp ≥ setpoint+4` → `FLAG_M102_开始制冷`. When `temp < setpoint` → `FLAG_M102_结束`.
  - Heating (mode `10`): `temp ≤ setpoint−4` → `FLAG_M102_开始加热`. `temp > setpoint` → `FLAG_M102_结束`.
  - Ambient/disabled (`00`/`11`) → always `FLAG_M102_结束`.

- **Compressor protection** (`shouhj/app/C0101App.java`):
  - **Spin-up debouncing** in `M102_StartRefrigeration` (lines 1975-2038): app first turns ON the **fan** (`00 01`), then increments a per-cabinet counter every poll where compressor is still off. Only after counter exceeds **30** ticks (≈5 min at 10 s polling) does it actually energize compressor (`08 0101…`) and glass heater (`08 0201…` unless humidity-control disables it).
  - **Forced-rest cycle**: `setM102CountDownTimer(int workMin, int restMin)` (lines 1860-1942). After `workMin` minutes cabinet is marked `M102_isForciblyClose=true`, compressor + glass heater turn off, after `restMin` minutes the flag clears. Stored in SP `RBSHOUMAI/SHOUMAIKAI/SHOUMAIJIE`, `RBQINGXI`.
  - Cut-off temperature is whatever operator types in `Aty设置灯带和温控界面` — no hard-coded ceiling. Hysteresis fixed at ±4 °C around setpoint.

### Heating
- Heating module = device id `04`. Same temp loop (`C0101App.M102_StartHeating` lines 2040-2085). After compressor force-off, fan starts; once per-cabinet counter exceeds **12** ticks (~2 min) heater (`04 01…`) energizes. `M102_finish` (lines 2087-2122) turns fan, compressor, glass heater and heater all off.

### Light curtain / drop sensor (光幕)
- Modes (`Flag.f274..f276 CMD_M102_光幕`): `00` none, `01` present, `02` priority.
- App reads active mode from `C0085UtilADH.f174M102_光幕模式`. `UtilADH.m286pdM102()` returns true if curtain mode is `01` or `02`, meaning **drop detection** active.
- During vend, M102 returns dispense result (opcode `03` poll, parsed in `ParseM102.m177jx`/`m179zx` lines 103-233):
  - `result` byte: 0 OK / 1 overcurrent / 2 wire break / 3 motor timeout / 4 light-curtain self-test fail / 5 solenoid didn't open / 10 micro-switch never pressed within 1.5 s
  - `i2` = curtain-blocked time in ms (×0.001 = seconds)
  - With drop-detect on: `i2 > 0 && result == 0` → product confirmed delivered → `m365xg(true)`. `i2 == 0` → "电机正常，没有检测到商品掉落" → refund/retry.
- Vend command sent with `RUN2` (`05` plain or `15` with-params on 815).

### Door / lock sensors (DI inputs)
- 815 board has **scan柜门反馈** opcode `02` (`CreatADH.m160scan815`, `CreatADH.java:90-95`). Returns cabinet door state for addressed cabinet.
- Per-cabinet enable flags in `Contants.java:8-12` (`ADH812_ISENABLE`, `ADH812_ISENABLEFG1`, `ADH812_ISENABLEFG2`, `ADH812_TOTALLAYERCOUNT`).
- Comm-loss watchdogs (`CreatADH.m130cl815`, `m129cl812`, `m131clM102`) treat 4-5 missed pollings as "故障/fault".

### Coin / bill validators
- **EPTON 404 现金控制板** native (`mserialport/eptonADH/Parse404.java`, `CreatADH.m154poll404`). Frame headers `6B … 0D0A`, opcode `03` poll, `01` ID, "把NV11的纸币压入钱箱" (push NV11 banknote) `01`, "退币" (return coins) in `CreatADH.m167tuib404`.
- Generic NV-11/coin via direct UART: `mserialport/BillCoinSerialPort.java` opens `/dev/ttyS<port>` at `BILLCOIN_BOTELV/PORT_CHUANKOU` (defaults 38400 / `ttyS4`).
- MDB peripherals: `mserialport/mdb/`. DAOs `MDBBillEntityDao`, `MDBCoinEntityDao`, `MDBCashEntityDao`. SP keys `BILLCOIN_*`, `MDB*`, `SETTING_XIANJIN`, `SETTING_BAIFU_POS`.

### Card readers / payment terminals
- `mserialport/huiyin/` — 慧银 POS. SP keys `HUIYIN_*`, `HUIYIN_POS_PAY`, `HUIYIN_POS_PAY_QR`.
- `mserialport/uca2/` — UCA2 reader. `SETTING_UCA2`, `UCA2_*`.
- `mserialport/ick_sm/` — ShengMa IC card (`Jiexick`, `Shengcick`, `Utilick`). SP keys `ICKA_*`, `ICK_SHUAKA`, `ICK_PAY`, `ICK_PAY_USB`.
- `mserialport/sy/` — 商盈 SmilePay (`SY_API`/`SY_HEZI`).
- `mserialport/trusbcom/` — generic USB-CDC bridge.
- 百富 Pax/POS via TCP at `AppConfig.BAIFU_IP=192.168.1.56:10009`.

### Camera
- Activities `AtyCamera2`, `AtySmCamera2..5`, `AtyUVCCamera`, `AtyPoliceVideos` (`shouhj/activity/other/`).
- CAMERA permission used for: face-recognition payment (微信刷脸 / Smile face-pay) — `WxPayFaceUtil.java`, `Contants.f65SP_微信刷脸_摄像头序列号`; AND policing/security recording (`UtilAppSP` keys `IS_HAVEPOLICING`, `IS_OPENPOLICING`, `POLICING_STORE_ID`, `POLICING_CAMERA2_ID`, `POLICING_UVCCAMERA_ID`).
- No in-app QR camera scanner — QR is presented by the screen, scanned by external readers.
- Hongruan face SDK keys: `AppConfig.HONGRUAN_APP_ID`, `HONGRUAN_SDK_KEY`. License file `/sdcard/mipsLic/mipsAi.lic`.

### Fans, glass heater
- Fan = M102 device id `00`. Always turned ON first when starting cooling or heating, then left running (`C0101App.java:1985-1993`, `2061-2068`).
- Glass heater = M102 device id `02`. Two control sources race on the same output:
  1. **Cooling cycle** in `M102_StartRefrigeration` — when starting compressor also issues `02 01…` UNLESS humidity-control flag (`M109SDKZZG/FG1/FG2`) is true.
  2. **Humidity loop** `ControlService.getSd(ReportSdEvent)` (`ControlService.java:242-313`): when humidity ≥ `M109XZSDMAXZG/FG1/FG2` (default 60%), turn `02` ON; below threshold or read error, turn OFF. Humidity polled every 30 s by `C0083TimerM102.java` using M102 opcode `10`. Reply parsed `ParseM102.m176jx` (294-305) as plain percent.

---

## 2. Configuration storage

### SharedPreferences

All keys are constants in `base/Contants.java`. Wrappers in `shouhj/app/UtilAppSP.java` and `shouhj/app/C0102App.java`. Defaults from `base/AppConfig.java`. SP file: `AppConfig.SYSTEM_FILE_SHARE = "spUtils.xml"` (uses `mvvmhabit` `SPUtils` wrapper).

| Domain | Key | Notes |
|---|---|---|
| Server TCP | `SOCKET_SERVER` (default `192.168.31.194`) / `SOCKET_PORT` (5005) | TCP heartbeat target |
| Server HTTP | `DOMAINNAME`, `DOMAINNAME_HS` | Defaults `http://merchant.sy1999.com/`, `https://www.iotpay.club/posp-api/`. Real server `SERVER_NEWSM=ff.smshj.com` |
| Driver board | `DRIVER_BOARD_TYPE` | `ADH815驱动卡` or `M102驱动卡` |
| Driver model | `IS_ADH_MODEL` (`ADH815`/`ADH814E`), `IS_ADH_CODE` (encrypted), `ADH815_MAIN_MODE`, `ADH815_FU1_MODE`, `ADH815_FU2_MODE` | Modes 4-char hex |
| Cabinets | `SETTING_DEPUTY01/02/03` | Sub cabinets enabled |
| Cabinets (812) | `ADH812_ISENABLE/FG1/FG2`, `ADH812_TOTALLAYERCOUNT` | Layer count for elevator |
| Lighting | `SP_FLAG_灯带模式`, `SP_FLAG_灯带设置时间_1/2/3组`, `ZHAOMINGKAI`, `ZHAOMINGJIE` | Mode + time windows |
| Temp | `WKMODE_*`, `WKWND_*` (runtime), persisted via `Aty设置灯带和温控界面` | Mode + °C per cabinet |
| Humidity | `M109SDKZZG`, `M109SDKZFG1`, `M109SDKZFG2` (boolean), `M109XZSDMAXZG/FG1/FG2` (int %, default 60) | `Contants.java:146-151` |
| Compressor protection | `RBSHOUMAI`, `SHOUMAIKAI`, `SHOUMAIJIE`, `RBQINGXI`, `RBTINGJI`, `SBTUODONG` | Work-min / rest-min etc. |
| Cash | `BILLCOIN_BOTELV/CHUANKOU/PORT_CHUANKOU`, `MERCHANTID`, `MERCHANTNAME`, `XJ_现金找零金额`, `MANAGERVIEWMODEL_ZHIBI_ZHAOLJINE` | |
| Payments | `SETTING_WEIXIN`, `SETTING_ALIPAY`, `SETTING_FACEPAY`, `SETTING_FANSAOPAY`, `SETTING_QUHUOMAPAY`, `SETTING_UCA2`, `SETTING_PAY_HUISHU`, `SETTING_BAIFU_POS`, `SETTING_SY` + Southeast Asia variants | |
| Device ID | `SERVICE_NUM` (default 15 zeros), `SERVICE_VERSION` (default `ADH825KV3.0.45 `) | |
| Engineer | `SETTING_PASSWORD` (default `12345678`), `SETTING_ENGINEERPASSWORD` (default `789123`) | |

### SQLite (greenDAO)

DB: `vendingMachine.db` (`greendao/DBManager.java:9`). Helper extends `DaoMaster$OpenHelper` in `greendao/GreenDaoOpenHelper.java`.

| Table | DAO | Purpose |
|---|---|---|
| `GOOD_ENTITY` | `GoodEntityDao` | Lanes/products. Columns: `_id, NAME, IMG, HD, INVENTORY, PRICE, STATUS__HD, RL_HD, SHOW, SET_NO, EXPIRED_TIME, SHOPPING_CART, ZHEK, IS_HEBHD, IS_SHOW_BUKGM, CONTENT, MANUFACTURER, SPECIFICATION, USE_STATE__HD` |
| `OUT_GOOD_STATUS_ENTITY` | `OutGoodStatusEntityDao` | Pending TCP frames to retry |
| `KONGZ_CHUHUO_GUOC_ENTITY` | `KongzChuhuoGuocEntityDao` | Dispense process log per slot |
| `OPERATING_MODE` | `OperatingModeDao` | Per-layer hardware config: `_id, MACHINE_ID, LAYER_ID, NAME, MOTOR_TYPE, LIGHT_CURTAIN_TYPE, TYPE` |
| `GOODS_LIBRARY_ENTITY` | `GoodsLibraryEntityDao` | Downloaded master goods catalog |
| `ORDER_VIDEOS_ENTITY` | `OrderVideosEntityDao` | Police camera video metadata per order |
| `ORDER_ENTITY` | `OrderEntityDao` | Transaction log: `_id, ORDER_SN, TIME, TIME_MIAO, MONEY, UNIT_PRICE, NUM, GOODSNAME, TYPE, KAHAO, STATUS, NAME, THIRD_SN, REFOUND_SN, FAIL_TOTAL_PRICE, PAY_TYPE, HDS, IS_UP, IS_OUT` |
| `MDB_BILL/COIN/CASH_ENTITY` | matching DAOs | Per-denomination MDB counters |
| `LIN_SHI_ORDER` | `LinShiOrderDao` | Temporary/staged orders |

Second DB `greendao/shjdb/`: `XIAOSJILU_ENTITY` (sales-record summaries).

### Files & assets
- `assets/RUNCTL.bin` — boot helper binary
- `assets/pay.json`, `button_pay.json`, `miandan.json` — payment-method UI configs
- `assets/zk/SIMYOU.ttf` — Chinese font
- App-data folders (`AppConfig.java:155-220`): `smkjFiles`, `售货机(不可删除)`, `售货机数据库`, `APP系统(不可删除)`, `APP数据库`, `smkj_log`, `plc_bin`, `imagesAD`/`imagesPB`, `videosAD`/`videosPB`, `goodsImg`, `imagesPeople`, `导出`, `销售记录`, `驱动板异常记录`, `主板疲劳测试`, `刷脸压力测试`
- License: `/sdcard/mipsLic/mipsAi.lic`

### Server config / endpoints / keys (`base/AppConfig.java`)

- `DOMAINNAME = http://merchant.sy1999.com/`
- `DOMAINNAME_HS = https://www.iotpay.club/posp-api/`
- `SERVER_SM_OPENBOX = https://api.cabinet.smshj.com`
- `SERVER_NEWSM = ff.smshj.com`, `SERVER_OLDSM = vm.smshj.com`
- `SERVER_NEWGX = gx.smshj.com`, `SERVER_OLDGX = xx.smshj.com`
- `SERVER_ZHIGOU = zg.zhigoukeji.com`
- `backnotifyurl = https://ff.smshj.com/`
- TCP `SERVER_PORT = 5005` (overridable via `SOCKET_PORT`)
- API keys baked in: `SY_APPID`, `SY_APP_SECRET`, `PKEY_HS`, `SHID_HS`, `HONGRUAN_APP_ID/SDK_KEY`, Bugly `TECENT_BUGLY_APPID`, Umeng appkey, `APP_PAY_MCH_ID`
- OSS: `OSS_ENDPOINT = http://oss-accelerate.aliyuncs.com`, asset bucket `https://smshjoss.oss-cn-shenzhen.aliyuncs.com/`
- ZhiWen (fingerprint) server `Contants.ZHIWEN_SERVER = 666.ekecao.com`

---

## 3. Data model

### Lane (`GoodEntity`)
- `HD` — physical lane code, 4-hex-digit ASCII like `"0101"` … cabinet (01 main / 02 sub1 / 03 sub2) + 2-digit motor index
- `RL_HD` — physical lane(s) merged into UI slot (e.g. `"0101,0102"` for double-width)
- `STATUS__HD` — fault code matching `Flag.f317…f335` (815) / `Flag.f338…f344` (M102): `"00"` healthy, `"02"` over-current, `"04"` motor wire break, `"FF"` controller timeout
- Mapping UI grid → motor: each on-screen slot is one row, `HD` is sent as motor address. `RL_HD` lets one entry drive multiple physical motors. Layered slots (812 elevator) carry layer in `OPERATING_MODE.LAYER_ID`

### Operating mode per layer (`OperatingMode`)
- `(_id, machine_id, layer_id, name, motor_type, light_curtain_type, type)`
- Motor types from `Flag.f292..f297`: `02/03/0A/0B` (2/3-wire normal/reversed), `00/0C` (solenoid normal/reversed)
- Curtain `00/01/02` none/present/priority

### Order (`OrderEntity`)
- `ORDER_SN, TIME, TIME_MIAO, MONEY, UNIT_PRICE, NUM, GOODSNAME, TYPE, KAHAO, STATUS, NAME, THIRD_SN, REFOUND_SN, FAIL_TOTAL_PRICE, PAY_TYPE, HDS, IS_UP, IS_OUT`
- Pay-type codes (`utils/CMD.java:33-77`): `01` bill, `02` coin, `03` no-pay, `04` online, `06` pickup-code, `07` IC card, `88` test, `AB` SY-hezi, `AC` SY-API, `AD` Baifu-POS, `AE` HS-API, `FA` MDB-POS, `FB` desk-swipe, `FC` finger, `FD` POS, `FE` net-cash, `FF` cash

### Errors / logs
- `OUT_GOOD_STATUS_ENTITY` — pending TCP report frames to retry
- `KONGZ_CHUHUO_GUOC_ENTITY` — dispense process trace
- `ORDER_VIDEOS_ENTITY` — police video filename ↔ order id
- `驱动板异常记录` folder — per-event text logs via `C0101App.m948write驱动板异常记录写入到文件`
- Runtime fault flags: `C0100App.f583..f595FLAG_*` (404 cash, 815 main/sub1/sub2, 812 main/sub1/sub2, M102 main/sub1/sub2). Each "fault" → R.string `guzhang` over EventBus

---

## 4. Networking / cloud integration

### REST (Retrofit2 + RxJava2)
- Base URL: `RetrofitClient.java:31` ← `AppConfig.getServer_baseUrl() = "https://" + IP_FROM_SP + "/hbshengma/api/"`
- Other clients: `RetrofitClientHS.java`, `RetrofitClientLaobao.java`, `RetrofitClientSY.java`
- Endpoints — `service/APIService.java`:
  - `phone-api-queryshelfdatas.do` — pull shelf data
  - `phone-api-updateonlinestate.do` — heartbeat / online state
  - `getMachineInfo.action` — machine + lane details
  - `getMachineType.action`
  - `addMachine.action`, `updateMachineInfo.action`, `updateSN.action`
  - `getHdGoodsInfo.action`, `refreshHuodaoInfo.action`, `updateHuoDaoGoodsName.action`, `getSysGoodsList.action`
  - `getMachineOrder.action`
  - `getReportOrder.action`, `uploadThirdOrder.action`
  - `phone-api-chuhuozt.do`, `phone-api-chuhuoztByOrderNo.do` — dispense status
  - `getAndroidVersion.action` — OTA
  - `downloadFile` (`@Streaming GET @Url`) — generic download
  - `cloudsaleInit.action`, `cloudsaleApiPay.action` — Aliyun cloud-sale
  - `smilePay.action`, `smilePayInitialize.action` — Smile face pay
  - `wxFaceOrder.action`, `queryFaceWxAuthinfo.action` — WeChat face pay
  - `micropay.action`, `ghl/seamless.action` — reverse-scan pay
  - `sPay`/`sPayqry`/`RefundPay` — HS payment
  - `setLnglat.action`, `setSVLC.action` — geo / SVLC
  - `pickUpCode.action`, `updatePickUpCode.action`
  - `queryCardNoList.action`, `inquiryCardNo.action`, `getCardNumber.action` — IC card
  - `phone-api-cpByUserbh.do`, `phone-api-dologin.do`, `phone-api-userVerify.do`, `phone-api-selectjine.do` — labour-PPE module
  - `getSbExpire.action`, `machineUserPhone.action`
  - SY: `api/services/app/overseasopenapi/createorder`, `…/checkorder`
  - Cabinet open: `/api/getGoodsInfo` against `SERVER_SM_OPENBOX`

### TCP socket (telemetry)
- `socket/TCPClient.java`, `SocketHeartThread.java:14-60`, `SocketHeartbeatThread.java`, `SocketInputThread.java`, `SocketOutPutThread.java`. Connects to `SOCKET_SERVER:SOCKET_PORT` (default `192.168.31.194:5005`).
- Heartbeat interval `Contants.SOCKET_HEART_TIME` (default `MANAGER_SERVERSOCKET_TIME = 90 s`)
- On every heartbeat client also drains `OUT_GOOD_STATUS_ENTITY` queue
- Frame types in `socket/FlagSocket.java`:
  - `B000` heartbeat, `B001` ice-cream dispense
  - `A001-A011` server-push: pay-done-ad, log-upload, lane-discount, lane-goods-info batch, lane-display-info batch, temperature-set, defog-set, system-reboot, face-pay enable, lane goods/name/image update, dispense-video upload
  - Frame-type bytes `10/70/71/42/43…` (IP set, light on/off, temperature config)
- Second Netty stack `socket/nettySocket/`. ShengMa-specific `socket/smSocket/`.
- **No MQTT.** WebSocket abstractions exist via Netty but used as plain TCP framed protocol.

### OTA updates
- Flow: backend → `getAppResponse(packetName)` returns `UpAppResponse` with apk URL + version → `RetrofitClient.downloadFile(@Url)` streams APK → install via `installApk(...)` in `C0101App.java:2211-2229` (`FileProvider` for SDK ≥ 24, falls back to `ApiSmRySystem.installApp` for RY board, `RyInstallApk.installApk` for kiayo/RY platform).
- Tencent Bugly provides parallel hot-fix delivery.

---

## 5. Localization / UI strings

- Folder: `c:/m109e/snack_apktool/snack_apktool/res/values*/`. Repo carries full Android system locale set (40+) — most just framework baseline.
- Locales with **app-specific translations**: `values/` (Chinese — source), `values-ru/` (Russian — `arrays.xml` + `strings.xml`), `values-kk/` (Kazakh — `strings.xml`), `values-zh-rCN/` (Simplified Chinese fallback).
- App display name: `<string name="app_name">哈萨克斯坦</string>` (`res/values/strings.xml:91`) — Kazakhstan-targeted variant.
- Currency: `KZT`; country `KZ`.

### Domain terminology

| Pinyin / 中文 | English |
|---|---|
| 货道 huodao | lane / slot |
| 主柜 / 副柜 | main / sub cabinet |
| 制冷 / 加热 / 常温 / 禁用 | cooling / heating / ambient / disabled |
| 电机 — 两线 / 三线 / 履带 / 电磁锁 | motor — 2-wire / 3-wire / belt / solenoid |
| 光幕 / 掉货检测 | light curtain / drop sensor |
| 出货 | dispense |
| 故障 | fault |
| 库存 / 盘库 | inventory / restock |
| 销售记录 | sales records |
| 取货码 | pickup code |
| 纸币 / 硬币 + 器 | banknote / coin + validator |
| 找零 | change return |
| 刷脸支付 / 扫码支付 / 刷卡支付 | face-pay / QR-pay / card-pay |
| 升降 / 层数 | elevator / layer count |
| 压缩机 / 风机 / 加热玻璃 / 加热模块 | compressor / fan / glass heater / heater |

Russian translation in `values-ru/strings.xml` is cleanest reference for Cyrillic re-labelling. Kazakh (`values-kk/`) is partial — consumer/buying screen translated, engineer screen mostly still Chinese.
