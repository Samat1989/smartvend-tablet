import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:usb_serial/usb_serial.dart';

import '../services/device_storage.dart';
import '../services/kiosk_bridge.dart';
import 'transport.dart';

class LogEntry {
  final DateTime time;
  final String dir; // TX | RX | INFO | ERR
  final String text;
  LogEntry(this.dir, this.text) : time = DateTime.now();
}

class PollStatus {
  final int state; // 0=Idle, 1=Running, 2=Done
  final int motor;
  final int result; // 0=OK, 1=Overload, 2=Underflow, 3=Timeout, 4=CurtainErr, 5=LockNotOpen
  final int peakMa;
  final int avgMa;
  final int timeMs;
  final int curtainMs;

  PollStatus({
    required this.state,
    required this.motor,
    required this.result,
    required this.peakMa,
    required this.avgMa,
    required this.timeMs,
    required this.curtainMs,
  });

  bool get isDone => state == 2;
  bool get isOk => result == 0;

  static const stateNames = {0: 'Idle', 1: 'Running', 2: 'Done'};

  /// Per `docs/01_PROTOCOL.md` and decompiled `ParseM102.m177jx`:
  /// 0 OK / 1 over-current / 2 wire break / 3 motor timeout /
  /// 4 light-curtain self-test fail / 5 solenoid didn't open /
  /// 10 micro-switch never pressed within 1.5 s
  static const resultNames = {
    0: 'OK',
    1: 'Overload',
    2: 'WireBreak',
    3: 'Timeout',
    4: 'CurtainErr',
    5: 'LockNotOpen',
    10: 'MicroSwitchTimeout',
  };

  String get resultText => resultNames[result] ?? 'Code $result';

  @override
  String toString() =>
      'state=${stateNames[state] ?? state} motor=$motor result=$resultText '
      'peak=${peakMa}mA avg=${avgMa}mA t=${timeMs}ms curtain=$curtainMs';
}

enum RunAck { started, invalidIndex, busy, noResponse }

class DispenseResult {
  final bool success;
  final String message;
  final PollStatus? finalStatus;

  DispenseResult({required this.success, required this.message, this.finalStatus});

  @override
  String toString() => '${success ? "OK" : "FAIL"}: $message';
}

/// Driver for M102 / M109E vending control board over USB-Serial.
///
/// Matches the factory app exactly (`UsbUtil.findUSB` in the decompiled
/// `com.example.shuai.vendingmachine`): the M109E control board ships with
/// an inline CH340 USB-Serial adapter (VID 0x1A86 / PID 0x7523) at
/// **9600 8N1**. We auto-detect that exact device on every USB attach event.
///
/// Frame format: 20-byte fixed, Modbus CRC-16 low-first.
class BoardClient extends ChangeNotifier {
  /// Factory app filters on this exact pair before opening — see
  /// `UsbUtil.findUSB`: `vendorId == 6790 && productId == 29987`.
  /// CH340 / CH341 USB-Serial chip from QinHeng.
  static const int ch340Vid = 0x1A86; // 6790
  static const int ch340Pid = 0x7523; // 29987

  /// VIDs we recognise as USB-Serial adapters for the manual "Connect"
  /// path in the tester UI. Auto-connect uses [ch340Vid] only (matches
  /// factory) to avoid attaching to unrelated peripherals.
  static const Set<int> knownUsbSerialVids = {
    0x1A86, // QinHeng: CH340/CH341 — factory default
    0x0403, // FTDI: FT232R/FT232H/FT2232/FT4232/FT-X
    0x10C4, // Silicon Labs: CP210x
    0x067B, // Prolific: PL2303
  };

  List<UsbDevice> _devices = [];
  UsbDevice? _selected;
  BoardTransport? _transport;
  /// Set while connected over a native UART (/dev/ttySX); null in USB mode.
  /// Lets [forceReconnect] / the health watchdog re-open the right path.
  String? _nativePath;
  StreamSubscription<Uint8List>? _rxSub;
  StreamSubscription<UsbEvent>? _usbEventSub;

  final _rxBuffer = BytesBuilder();
  Completer<Uint8List>? _pendingResponse;
  int? _pendingOpcode;
  Timer? _pendingTimeout;

  /// Factory uses `BOTELV_9600 = 9600`, 8N1.
  int _baud = 9600;
  int _slaveAddr = 1;

  /// "Password" appended to the frame body before CRC-16 is computed.
  /// The factory app calls this "M102 encryption mode" (`m964getM102()`)
  /// and it is **enabled by default** (`getBoolean("IS_M102GOTOCODE", true)`).
  ///
  /// Wire format unchanged: still 20 bytes (`addr+order+data+crc`). The
  /// password is mixed in only during CRC computation — boards with this
  /// mode active silently reject frames whose CRC was computed without it.
  ///
  /// The 11 password bytes (`0x31 0x38 ... 0x36`) decode to ASCII
  /// `"18633695826"`. See decompiled `Flag.f282CMD_M102_` /
  /// `CreatADH.m141biany()`.
  static const List<int> m102Password = <int>[
    0x31, 0x38, 0x36, 0x33, 0x33, 0x36, 0x39, 0x35, 0x38, 0x32, 0x36,
  ];

  /// Whether to mix [m102Password] into outgoing CRC. Default `true` to
  /// match the factory app's `IS_M102GOTOCODE = true` default. Loaded
  /// from [DeviceStorage.useM102Password] in the constructor when
  /// present. Operator flips it manually in the "Плата" service-mode
  /// tab — there is no runtime auto-detect (the factory app doesn't
  /// either; it's set once in the driver-board setup dialog).
  bool _useM102Password = true;
  bool get useM102Password => _useM102Password;

  /// Optional reference to persist the chosen [_useM102Password] across
  /// launches. May be null in unit-tests / debug runs.
  final DeviceStorage? _storage;

  /// Flip the CRC-password flag and persist it via [_storage] so the
  /// next launch starts with the same setting. Mirrors how the
  /// factory app's SN setup dialog writes IS_M102GOTOCODE once and
  /// then trusts it forever — no auto-detect, no flip-on-reconnect.
  void setUseM102Password(bool v) {
    _useM102Password = v;
    // ignore: unawaited_futures — fire-and-forget; SharedPreferences
    // writes are quick and we don't want to block the UI on disk.
    _storage?.setUseM102Password(v);
    notifyListeners();
  }

  final _logCtrl = StreamController<LogEntry>.broadcast();
  final _logHistory = <LogEntry>[];

  /// Number of consecutive request failures (timeouts or transport errors).
  /// Resets to 0 on any successful response. Factory app flags a cabinet
  /// "communication broken" after **4 missed POLLs** (`docs/01_PROTOCOL.md`),
  /// so we surface [isHealthy] as `consecutiveFailures < 4`.
  int _consecutiveFailures = 0;
  int get consecutiveFailures => _consecutiveFailures;

  /// Last firmware ID returned by [getId], or null if never queried / lost.
  /// Refreshed on connect for diagnostics in service mode.
  String? _firmwareId;
  String? get firmwareId => _firmwareId;

  /// True while we have at least one fresh exchange under the comm-loss
  /// threshold. False means the board is unresponsive even though USB is
  /// physically attached — UI should show a "maintenance" overlay.
  bool get isHealthy => isConnected && _consecutiveFailures < 4;

  List<UsbDevice> get devices => List.unmodifiable(_devices);
  UsbDevice? get selectedDevice => _selected;
  bool get isConnected => _transport != null;
  int get baud => _baud;
  int get slaveAddr => _slaveAddr;
  Stream<LogEntry> get logStream => _logCtrl.stream;
  List<LogEntry> get logHistory => List.unmodifiable(_logHistory);

  /// Optional [storage] lets BoardClient (a) preload the last known
  /// `useM102Password` value so the first post-connect Get ID hits
  /// the right CRC formula immediately, and (b) persist the new
  /// value after the auto-probe flips it. Pass null in tests / when
  /// storage isn't available — we just won't remember the choice
  /// across launches in that case.
  BoardClient({DeviceStorage? storage}) : _storage = storage {
    final pref = storage?.useM102Password;
    if (pref != null) _useM102Password = pref;
    _usbEventSub = UsbSerial.usbEventStream?.listen((event) async {
      _info('USB event: ${event.event} ${event.device?.productName ?? ""}');
      // On any USB attach, refresh and try to auto-connect if we're not already.
      await refreshDevices();
      if (!isConnected &&
          event.event == UsbEvent.ACTION_USB_ATTACHED &&
          _storage?.serialPortPath == null) {
        // Ask the OS to grant permission *before* trying to open the
        // port. usb_serial does this implicitly via open(), but in
        // kiosk mode with no recent foreground activity the dialog
        // sometimes fails to surface. Calling it explicitly via the
        // native MethodChannel forces the dialog every time.
        await KioskBridge.requestUsbPermission();
        await Future.delayed(const Duration(milliseconds: 500));
        await autoConnect();
      }
      // On detach, drop our handle so we can re-attach cleanly later —
      // but only when we're actually on USB; a native-UART session must
      // survive an unrelated USB unplug event.
      if (event.event == UsbEvent.ACTION_USB_DETACHED &&
          isConnected &&
          _nativePath == null) {
        await disconnect();
      }
    });
    // Listen for the system "Allow USB access?" dialog result. When the
    // operator taps OK, retry connect — without this they'd have to
    // open service-mode → Плата → Connect manually.
    _usbPermissionSub = KioskBridge.usbPermissionResultStream.listen(
      (granted) async {
        _info('USB permission ${granted ? "granted" : "denied"}');
        if (granted && !isConnected && _storage?.serialPortPath == null) {
          await refreshDevices();
          await autoConnect();
        }
      },
    );
    _startHealthWatchdog();
    // Probe permission at construction. If the cable was already plugged
    // before the app launched (the common case on cabinet boot), the
    // USB_DEVICE_ATTACHED intent never fired — so the OS has never
    // prompted, and our usbEventStream listener above will never trigger
    // either. Forcing the request here gets the dialog on first launch
    // and then connects immediately if permission already exists.
    Future.delayed(const Duration(milliseconds: 800), () async {
      // Native-UART tablets: skip the USB probe entirely and open the
      // configured /dev/ttySX. The health watchdog keeps it re-opened.
      final nativePath = _storage?.serialPortPath;
      if (nativePath != null) {
        _info('Boot: connecting native UART $nativePath');
        await connectNative(nativePath);
        return;
      }
      await refreshDevices();
      final state = await KioskBridge.requestUsbPermission();
      _info('Initial USB permission probe: $state');
      if (state == 'granted' && !isConnected) {
        await autoConnect();
      }
    });
  }

  StreamSubscription<bool>? _usbPermissionSub;

  /// Force a clean disconnect → autoConnect cycle. Same effect as the
  /// operator hitting "Disconnect" then "Connect" in service mode,
  /// just done by the [_healthWatchdog] when comms have been silently
  /// dead long enough that we suspect the USB-Serial chip / OS driver
  /// is stuck rather than the board itself.
  Future<void> forceReconnect() async {
    _info('Forcing reconnect (close + reopen port)');
    final native = _nativePath;
    await disconnect();
    await Future.delayed(const Duration(milliseconds: 400));
    if (native != null) {
      await connectNative(native);
    } else {
      await autoConnect();
    }
  }

  /// Self-heal: USB autosuspend, a stuck CH340/FTDI driver, or a
  /// flaky cable can leave the port "open" from Dart's view but with
  /// every TX silently going nowhere. The board client never sees a
  /// USB detach, so the usbEventStream-based reconnect doesn't fire.
  ///
  /// This watchdog ticks every 10 s and, if [isConnected] but
  /// [isHealthy] has been false for at least [_unhealthyGracePeriod],
  /// runs the same close+open cycle the operator would do manually.
  static const Duration _unhealthyGracePeriod = Duration(seconds: 30);
  Timer? _healthWatchdog;
  DateTime? _unhealthySince;
  bool _selfHealing = false;

  /// Counter mirroring the factory app's `numTr30ReconUSBCOMUSB`
  /// (`UsbUtil.java:216`): how many times in a row the watchdog has
  /// had to force-reconnect without the bus coming back healthy.
  /// Reset to 0 on the next successful exchange in [_sendAndReceive].
  /// Surfaced via [reconnectAttempts] so the service-mode log can
  /// show 3-of-5 etc., and we escalate the message at the factory
  /// thresholds (2 = restart USB, 5 = would-restart-app, 10 = would-
  /// reboot-mainboard). We only log — the app-restart and mainboard-
  /// reboot are factory-specific and need device-owner privileges we
  /// don't have here.
  int _reconnectAttempts = 0;
  int get reconnectAttempts => _reconnectAttempts;

  void _startHealthWatchdog() {
    _healthWatchdog?.cancel();
    _healthWatchdog = Timer.periodic(
      const Duration(seconds: 10),
      (_) async {
        if (_transport == null || _selfHealing) {
          _unhealthySince = null;
          return;
        }
        if (isHealthy) {
          _unhealthySince = null;
          return;
        }
        _unhealthySince ??= DateTime.now();
        final unhealthyFor = DateTime.now().difference(_unhealthySince!);
        if (unhealthyFor < _unhealthyGracePeriod) return;
        _selfHealing = true;
        try {
          _reconnectAttempts++;
          _info('Health watchdog: ${unhealthyFor.inSeconds}s unhealthy '
              '→ auto-reconnect #$_reconnectAttempts');

          // Escalation ladder modelled on factory app
          // (UsbUtil.isRestartApp / m933reboot):
          //   • #5 reconnects in a row  → restart the app to clear any
          //     stuck USB-Serial driver state inside our own process
          //   • #10 reconnects in a row → reboot the whole tablet
          //     (DevicePolicyManager.reboot, device-owner only;
          //     silent no-op if we haven't been provisioned).
          // We *also* trigger forceReconnect() in the same tick for
          // the in-process attempts — the escalation just adds a
          // hammer on top once we've established the soft path isn't
          // enough.
          if (_reconnectAttempts == 5) {
            _err('Reconnect #5 — restarting app to clear stuck '
                'USB-driver state (factory pattern)');
            // ignore: unawaited_futures
            KioskBridge.restartApp();
            return; // process is about to die, no point continuing
          }
          if (_reconnectAttempts >= 10) {
            _err('Reconnect #$_reconnectAttempts — rebooting device '
                '(factory pattern; needs device-owner)');
            try {
              await KioskBridge.rebootDevice();
              return; // device is rebooting
            } on PlatformException catch (e) {
              if (e.code == 'not_device_owner') {
                _err('Cannot reboot device — app is not device-owner. '
                    'Provision with `adb shell dpm set-device-owner '
                    'kz.smartvend.m102_tester/.KioskAdminReceiver`.');
              } else {
                _err('Reboot failed: ${e.message}');
              }
            }
          }
          if (_reconnectAttempts == 2) {
            _err('Reconnect #2 — board still silent after one full '
                'close+open cycle');
          }
          await forceReconnect();
        } finally {
          _selfHealing = false;
          _unhealthySince = null;
        }
      },
    );
  }

  Future<void> refreshDevices() async {
    final devs = await UsbSerial.listDevices();
    _devices = devs;
    if (_selected != null && !devs.any((d) => d.deviceId == _selected!.deviceId)) {
      _selected = null;
    }
    // Prefer the CH340 (factory default) when present.
    _selected ??= devs.where((d) => d.vid == ch340Vid && d.pid == ch340Pid).firstOrNull
        ?? (devs.isNotEmpty ? devs.first : null);
    _info('Found ${devs.length} USB device(s)');
    for (final d in devs) {
      _info('  ${d.productName ?? "?"}  vid=0x${d.vid?.toRadixString(16)} pid=0x${d.pid?.toRadixString(16)}');
    }
    notifyListeners();
  }

  void selectDevice(UsbDevice? device) {
    if (isConnected) return;
    _selected = device;
    notifyListeners();
  }

  void setBaud(int baud) {
    if (isConnected) return;
    _baud = baud;
    notifyListeners();
  }

  void setSlaveAddr(int addr) {
    _slaveAddr = addr;
    notifyListeners();
  }

  /// Auto-detect the M109E CH340 (VID 0x1A86 / PID 0x7523) the same way
  /// `UsbUtil.findUSB` does in the factory app, and connect at 9600 8N1.
  /// Falls back to any other known USB-Serial chip if no CH340 is present
  /// (useful on bench tablets with FTDI dongles).
  Future<bool> autoConnect() async {
    if (isConnected) return true;
    await refreshDevices();
    final ch340 = _devices.where(
      (d) => d.vid == ch340Vid && d.pid == ch340Pid,
    ).firstOrNull;
    final fallback = _devices.where(
      (d) => knownUsbSerialVids.contains(d.vid),
    ).firstOrNull;
    final pick = ch340 ?? fallback;
    if (pick == null) {
      _info('Auto-connect: no USB-Serial adapter found '
          '(expected CH340 vid=0x1A86 pid=0x7523)');
      return false;
    }
    _info('Auto-connect: trying ${pick.productName ?? "device"} '
        '(vid=0x${pick.vid?.toRadixString(16)} '
        'pid=0x${pick.pid?.toRadixString(16)})');
    return connect(device: pick);
  }

  Future<bool> connect({UsbDevice? device, int? baud, int? slaveAddr}) async {
    final dev = device ?? _selected;
    if (dev == null) {
      _err('No device selected');
      return false;
    }
    if (baud != null) _baud = baud;
    if (slaveAddr != null) _slaveAddr = slaveAddr;
    _selected = dev;
    return _attach(UsbTransport(dev, baud: _baud), usbDevice: dev);
  }

  /// Connect over a native on-SoC UART (`/dev/ttySX`) instead of a USB
  /// adapter — for industrial tablets whose serial port is wired straight
  /// to the SoC (no USB-serial chip, so `usb_serial` can't see it). See
  /// [NativeUartTransport]. Verified against an M109E on `/dev/ttyS2`.
  Future<bool> connectNative(String path, {int? baud, int? slaveAddr}) async {
    if (baud != null) _baud = baud;
    if (slaveAddr != null) _slaveAddr = slaveAddr;
    return _attach(NativeUartTransport(path, baud: _baud), nativePath: path);
  }

  /// Shared open path for both transports: (re)connect, wire RX to
  /// [_onRx], start the heartbeat + firmware probe.
  Future<bool> _attach(
    BoardTransport transport, {
    UsbDevice? usbDevice,
    String? nativePath,
  }) async {
    await disconnect();
    transport.logger = _info;
    try {
      if (!await transport.open()) {
        _err('open() failed for ${transport.description}');
        await transport.close();
        return false;
      }
      _transport = transport;
      _nativePath = nativePath;
      if (usbDevice != null) _selected = usbDevice;
      _consecutiveFailures = 0;
      _rxSub =
          transport.onData.listen(_onRx, onError: (e) => _err('rx: $e'));
      _info('Opened ${transport.description} @ $_baud 8N1');
      notifyListeners();
      // Mirror the factory app's 900 ms 0x03 poll thread — keeps the bus
      // warm, feeds the health watchdog, and surfaces a stuck board fast.
      _startPollHeartbeat();
      // Best-effort firmware probe (don't await — a missing reply here
      // shouldn't delay the UI's "connected" state).
      // ignore: unawaited_futures
      _refreshFirmwareId();
      return true;
    } catch (e) {
      _err('connect error: $e');
      return false;
    }
  }

  /// Enumerate plausible native serial nodes under /dev. Which node the
  /// external port maps to — and even the name prefix — varies by SoC
  /// (Spreadtrum `ttyS*`, MediaTek `ttyMT*`, Qualcomm `ttyHS*`/`ttyHSL*`),
  /// so the picker lists whatever the device actually exposes rather than a
  /// fixed set. `ttyUSB*`/`ttyACM*` are excluded — those belong to the USB
  /// path handled by [autoConnect].
  Future<List<String>> listNativePorts() async {
    final re = RegExp(r'^tty(S|MT|HS|HSL|GS)\d+$');
    final out = <String>[];
    try {
      await for (final e in Directory('/dev').list(followLinks: false)) {
        final name = e.path.split('/').last;
        if (re.hasMatch(name)) out.add('/dev/$name');
      }
    } catch (e) {
      _info('listNativePorts: $e');
    }
    out.sort();
    return out;
  }

  /// Probe each candidate node for a live board: send Get ID and watch for
  /// a 20-byte reply, trying both CRC-password modes. Returns the first
  /// responding node (and leaves [useM102Password] on the mode that
  /// worked), or null. Disconnects any current session first — the caller
  /// then persists + [connectNative]s the winner.
  Future<String?> autoDetectNativePort(List<String> candidates) async {
    await disconnect();
    for (final path in candidates) {
      for (final pw in const [false, true]) {
        if (await _probeNative(path, pw)) {
          _info('Auto-detect: board on $path '
              '(M102 password ${pw ? "ON" : "OFF"})');
          _useM102Password = pw;
          // ignore: unawaited_futures
          _storage?.setUseM102Password(pw);
          notifyListeners();
          return path;
        }
      }
    }
    _info('Auto-detect: no board found on ${candidates.length} node(s)');
    return null;
  }

  /// Transient open of [path], send Get ID with the given CRC mode, and
  /// report whether a 20-byte frame came back within a short window.
  Future<bool> _probeNative(String path, bool password) async {
    final t = NativeUartTransport(path, baud: _baud);
    t.logger = _info;
    if (!await t.open()) {
      await t.close();
      return false;
    }
    final buf = BytesBuilder();
    final completer = Completer<bool>();
    final sub = t.onData.listen((chunk) {
      buf.add(chunk);
      if (buf.length >= 20 && !completer.isCompleted) completer.complete(true);
    });
    try {
      await t.write(buildFrame(0x01, List.filled(16, 0), password: password));
    } catch (_) {}
    final ok = await completer.future
        .timeout(const Duration(milliseconds: 700), onTimeout: () => false);
    await sub.cancel();
    await t.close();
    return ok;
  }

  // ─── 900 ms Poll (0x03) heartbeat ───────────────────────────────
  //
  // Factory app's `C0082ThreadADH.java:97` is a forever-loop:
  //   while (true) { sleep(900); for (addr in 1..N) sendM102Order("03"); }
  //
  // That cadence is what keeps the M102 / MP2404 / clone boards happy:
  // USB-Serial chips on Android Go tablets autosuspend after ~few
  // seconds of TX silence (we hit this on MP2404), and some firmware
  // revisions also have their own bus-silence watchdog that drops the
  // CH340. A poll-per-second cleanly avoids both. We use Dart's
  // Timer.periodic instead of a dedicated thread.
  //
  // The tick skips itself if (a) another request is still in flight
  // (climate read, dispense, manual op from service mode), or (b) the
  // health watchdog is mid-reconnect — so the heartbeat never collides
  // with real work or self-healing.
  static const Duration _heartbeatInterval = Duration(milliseconds: 900);
  Timer? _heartbeatTimer;

  void _startPollHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (_transport == null) return;
      if (_selfHealing) return;
      if (_pendingResponse != null && !_pendingResponse!.isCompleted) {
        return;
      }
      // ignore: unawaited_futures
      poll();
    });
  }

  void _stopPollHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Set while [_refreshFirmwareId] is already running so the recovery
  /// path in [_sendAndReceive] doesn't kick off a second concurrent
  /// probe-and-detect cycle.
  bool _firmwareRefreshInFlight = false;

  Future<void> _refreshFirmwareId() async {
    if (_firmwareRefreshInFlight) return;
    _firmwareRefreshInFlight = true;
    try {
      // CRC password is now a manual operator setting (mirrors the
      // factory app's `IS_M102GOTOCODE` SharedPreference, which is
      // set once during the SN/driver-board setup dialog and never
      // probed at runtime). Auto-detect used to live here — it ran
      // a flip-and-retry on every reconnect and could land on the
      // wrong setting under timing pressure, then persist it. Now we
      // just trust the stored flag and let the operator flip it in
      // the "Плата" service-mode tab if a different board needs the
      // other variant.
      final id = await getId();
      if (id != null && id != _firmwareId) {
        _firmwareId = id;
        notifyListeners();
      }
    } catch (_) {
      // Probe failure is non-fatal; isHealthy will reflect comm status.
    } finally {
      _firmwareRefreshInFlight = false;
    }
  }

  Future<void> disconnect() async {
    // CRITICAL: clear Dart-side state synchronously *before* trying
    // to close the underlying handles. If the USB chip died /
    // autosuspended, [_rxSub.cancel] or [_port.close] may hang
    // indefinitely or throw — the old code awaited those calls first,
    // so on a stuck driver `_port` stayed non-null and `isConnected`
    // stayed `true`. That made the service-mode buttons useless: the
    // user reported "disconnect не реагирует, connect не реагирует,
    // только перезагрузка приложения помогает". Now the listeners
    // already see `isConnected == false` (so they can re-render and
    // [autoConnect] doesn't bail on the early `if (isConnected)`),
    // and we tear down the actual port in the background with a
    // 2-second timeout.
    _stopPollHeartbeat();
    _failPending('disconnected');
    final oldRx = _rxSub;
    final oldTransport = _transport;
    _rxSub = null;
    _transport = null;
    _rxBuffer.clear();
    _firmwareId = null;
    _consecutiveFailures = 0;
    notifyListeners();
    try {
      await oldRx?.cancel();
    } catch (e) {
      _err('rxSub.cancel during disconnect: $e');
    }
    try {
      await oldTransport?.close().timeout(const Duration(seconds: 2));
    } catch (e) {
      _err('transport.close during disconnect: $e (handle abandoned)');
    }
  }

  // ---------- protocol ----------

  Uint8List _crc16Modbus(Uint8List data) {
    int crc = 0xFFFF;
    for (final b in data) {
      crc ^= b;
      for (int i = 0; i < 8; i++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
      }
    }
    return Uint8List.fromList([crc & 0xFF, (crc >> 8) & 0xFF]);
  }

  Uint8List buildFrame(int cmd, List<int> data, {bool? password}) {
    final usePassword = password ?? _useM102Password;
    final frame = Uint8List(20);
    frame[0] = _slaveAddr & 0xFF;
    frame[1] = cmd & 0xFF;
    for (int i = 0; i < data.length && i < 16; i++) {
      frame[2 + i] = data[i] & 0xFF;
    }
    // CRC over `addr+order+data` (18 bytes), optionally followed by the
    // 11-byte M102 password — the board firmware uses the same recipe and
    // drops frames whose CRC doesn't match.
    final crcInput = usePassword
        ? Uint8List.fromList([...frame.sublist(0, 18), ...m102Password])
        : frame.sublist(0, 18);
    final crc = _crc16Modbus(crcInput);
    frame[18] = crc[0];
    frame[19] = crc[1];
    return frame;
  }

  /// Send a raw frame and await the next 20-byte response (within [timeout]).
  /// Returns null on timeout or no connection.
  Future<Uint8List?> _sendAndReceive(int opcode, List<int> data,
      {Duration timeout = const Duration(milliseconds: 800)}) async {
    if (_transport == null) {
      _err('not connected');
      return null;
    }
    // If a previous request is still pending, wait briefly to avoid overlap.
    if (_pendingResponse != null && !_pendingResponse!.isCompleted) {
      await _pendingResponse!.future.timeout(const Duration(milliseconds: 200),
          onTimeout: () => Uint8List(0));
    }

    final frame = buildFrame(opcode, data);
    _tx(frame);

    final completer = Completer<Uint8List>();
    _pendingResponse = completer;
    _pendingOpcode = opcode;
    _pendingTimeout = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(Uint8List(0)); // signal timeout
      }
    });

    try {
      await _transport!.write(frame);
    } catch (e) {
      _err('write: $e');
      _pendingTimeout?.cancel();
      _pendingResponse = null;
      _pendingOpcode = null;
      return null;
    }

    final resp = await completer.future;
    _pendingResponse = null;
    _pendingOpcode = null;
    _pendingTimeout?.cancel();
    if (resp.isEmpty) {
      _consecutiveFailures++;
      if (_consecutiveFailures == 4) {
        _err('communication broken (4 consecutive misses)');
        notifyListeners();
      }
      return null;
    }
    if (_consecutiveFailures > 0) {
      _consecutiveFailures = 0;
      notifyListeners();
    }
    // Bus is back: reset the watchdog's escalation counter so the
    // next outage starts fresh from "reconnect #1" rather than
    // continuing whatever total survived from the previous one.
    if (_reconnectAttempts > 0) {
      _info('Bus recovered after $_reconnectAttempts reconnect attempts');
      _reconnectAttempts = 0;
    }
    // Recovery hook: if firmware ID was never determined (cold boot
    // when the board was off) or got lost (USB detach / disconnect),
    // the comms guard above tells us the bus is back online. Re-run
    // Get ID once so the operator no longer has to hit
    // "Disconnect → Connect" manually in service mode to bring the
    // firmware string back. The opcode guard prevents recursion
    // because [_refreshFirmwareId] itself sends 0x01 via getId().
    if (_firmwareId == null &&
        opcode != 0x01 && // 0x01 = Get ID — guard against recursion
        !_firmwareRefreshInFlight) {
      // ignore: unawaited_futures
      _refreshFirmwareId();
    }
    return resp;
  }

  void _onRx(Uint8List data) {
    // Log every chunk that arrives over USB — even bytes that don't make
    // up a complete 20-byte frame. Helps diagnose RS485 direction issues,
    // wrong baud (frame misalignment), or noise on the line.
    if (data.isNotEmpty) _addLog(LogEntry('RAW', _hex(data)));
    _rxBuffer.add(data);
    // Try to extract 20-byte frames.
    while (_rxBuffer.length >= 20) {
      final all = _rxBuffer.toBytes();
      final frame = Uint8List.fromList(all.sublist(0, 20));
      _rxBuffer.clear();
      if (all.length > 20) _rxBuffer.add(all.sublist(20));

      _logRx(frame);

      final pending = _pendingResponse;
      if (pending != null && !pending.isCompleted) {
        // Match if opcode equals the pending request's opcode.
        if (frame.length >= 2 && frame[1] == _pendingOpcode) {
          pending.complete(frame);
        }
      }
    }
  }

  void _failPending(String reason) {
    final p = _pendingResponse;
    _pendingResponse = null;
    _pendingOpcode = null;
    _pendingTimeout?.cancel();
    if (p != null && !p.isCompleted) {
      _err('pending request failed: $reason');
      p.complete(Uint8List(0));
    }
  }

  // ---------- high-level commands ----------

  /// Quick "is the board alive *right now*" check. Sends Get ID (0x01)
  /// with a shorter-than-normal timeout and returns true iff a frame
  /// came back. Used by cart/pay flows so payment can't be initiated
  /// against a dead bus.
  Future<bool> ping({Duration timeout = const Duration(milliseconds: 600)}) async {
    if (_transport == null) return false;
    final r = await _sendAndReceive(0x01, List.filled(16, 0), timeout: timeout);
    return r != null && r.isNotEmpty;
  }

  Future<String?> getId() async {
    final r = await _sendAndReceive(0x01, List.filled(16, 0));
    if (r == null || r.length < 14) return null;
    final sn = String.fromCharCodes(r.sublist(2, 14).where((b) => b >= 0x20 && b <= 0x7E)).trim();
    return sn.isEmpty ? null : sn;
  }

  /// 0x04 Motor Scan — non-destructive presence test. Briefly pulses
  /// the channel and reads current; per [api_docsM109E.txt §9.3] returns:
  ///   0xAA = normal (motor wired)
  ///   0xBB = abnormal (no/low current — channel empty or wire broken)
  ///   0xCC = overload (short / excessive current)
  /// `null` = no reply from board.
  ///
  /// Safe to call across all 0..99 channels — the motor doesn't actually
  /// turn the spiral, so the cabinet stays loaded.
  Future<int?> scanMotor(int motorId) async {
    final data = <int>[motorId & 0xFF, ...List.filled(15, 0)];
    final r = await _sendAndReceive(0x04, data,
        timeout: const Duration(milliseconds: 400));
    if (r == null || r.length < 3) return null;
    return r[2];
  }

  Future<PollStatus?> poll() async {
    final r = await _sendAndReceive(0x03, List.filled(16, 0));
    if (r == null || r.length < 13) return null;
    return PollStatus(
      state: r[2],
      motor: r[3],
      result: r[4],
      peakMa: (r[5] << 8) | r[6],
      avgMa: (r[7] << 8) | r[8],
      timeMs: (r[9] << 8) | r[10],
      curtainMs: r[11],
    );
  }

  Future<RunAck> motorRun(int idx, {int type = 2, int curtain = 0}) async {
    final data = <int>[idx, type, curtain, 0, 0, 0, ...List.filled(10, 0)];
    final r = await _sendAndReceive(0x05, data);
    if (r == null || r.length < 3) return RunAck.noResponse;
    switch (r[2]) {
      case 0:
        return RunAck.started;
      case 1:
        return RunAck.invalidIndex;
      case 2:
        return RunAck.busy;
      default:
        return RunAck.noResponse;
    }
  }

  Future<double?> readTemp() async {
    final r = await _sendAndReceive(0x07, List.filled(16, 0));
    if (r == null || r.length < 4) return null;
    // Factory formula (ParseM102.m175jx): °C = (signed_int16(bytes 2..3) - 20) / 10
    int raw = (r[2] << 8) | r[3];
    if (raw > 0x7FFF) raw -= 0x10000;
    final c = (raw - 20) / 10.0;
    // -52°C is the factory's "no probe" sentinel
    if (c <= -50.0) return null;
    return c;
  }

  /// Returns humidity percent (0-100) or null if no sensor / no reply.
  Future<int?> readHumidity() async {
    final r = await _sendAndReceive(0x10, List.filled(16, 0));
    if (r == null || r.length < 5) return null;
    // Factory layout (ParseM102.m176jx):
    //   byte 2 = humidity %RH
    //   byte 4 < 10 ⇒ sensor OK
    final percent = r[2];
    final sensorOk = r[4] < 10;
    if (!sensorOk || percent == 0xFF || percent > 100) return null;
    return percent;
  }

  Future<bool> writeDo(int idx, bool state) async {
    final r = await _sendAndReceive(0x08, [idx, state ? 1 : 0, ...List.filled(14, 0)]);
    if (r == null || r.length < 4) return false;
    final code = r[3];
    return code == 0xF0 || code == 0xF1;
  }

  /// Run motor and wait for completion. Used for actual product dispense.
  ///
  /// Success is determined by **two** signals when [curtain] != 0:
  ///   1. The motor reports `result == 0` (no overload / timeout / etc.)
  ///   2. The light curtain (drop sensor) reports `curtainMs > 0`,
  ///      i.e. the IR beam was actually broken by a falling product.
  ///
  /// If the motor finished OK but the curtain didn't trigger, the result is
  /// "motor ok, no drop" — caller should refund the customer.
  Future<DispenseResult> dispense(
    int motorIdx, {
    int type = 2,
    int curtain = 0,
    Duration pollInterval = const Duration(milliseconds: 500),
    Duration overallTimeout = const Duration(seconds: 20),
  }) async {
    if (!isConnected) {
      return DispenseResult(success: false, message: 'Нет связи с платой');
    }

    _info('--- DISPENSE motor=$motorIdx type=$type curtain=$curtain ---');
    final ack = await motorRun(motorIdx, type: type, curtain: curtain);
    switch (ack) {
      case RunAck.invalidIndex:
        return DispenseResult(
            success: false, message: 'Недопустимый номер мотора $motorIdx');
      case RunAck.busy:
        return DispenseResult(success: false, message: 'Плата занята');
      case RunAck.noResponse:
        return DispenseResult(success: false, message: 'Нет ответа от платы');
      case RunAck.started:
        break;
    }

    final start = DateTime.now();
    PollStatus? last;
    while (DateTime.now().difference(start) < overallTimeout) {
      await Future.delayed(pollInterval);
      final p = await poll();
      if (p == null) continue;
      last = p;
      if (!p.isDone) continue;

      // Motor finished. Decide based on result + curtain.
      if (!p.isOk) {
        // Result code 4 = light-curtain self-test failed BEFORE motor started.
        // Hint to the operator that this is a hardware/wiring issue, not the
        // motor itself.
        final extra = p.result == 4
            ? ' (проверьте питание V1, провода SIG/GND, очистите проём, '
                'или попробуйте режим завесы 2)'
            : '';
        return DispenseResult(
          success: false,
          message: 'Ошибка мотора: ${p.resultText}$extra',
          finalStatus: p,
        );
      }

      // Motor reported OK. If curtain is enabled, also require a drop.
      if (curtain != 0 && p.curtainMs == 0) {
        return DispenseResult(
          success: false,
          message: 'Мотор отработал, но датчик падения не сработал',
          finalStatus: p,
        );
      }

      final dropInfo = curtain != 0 ? ', drop ${p.curtainMs}ms' : '';
      return DispenseResult(
        success: true,
        message: 'OK (пик ${p.peakMa} мА, ${p.timeMs} мс$dropInfo)',
        finalStatus: p,
      );
    }
    return DispenseResult(
      success: false,
      message: 'Таймаут выдачи (${overallTimeout.inSeconds}с)',
      finalStatus: last,
    );
  }

  /// Dispense a slot — one or more motors in sequence. Used for twin
  /// spirals where one product is mechanically tied to two motors and
  /// both must fire for the product to fall.
  ///
  /// Short-circuits on the first failure: if motor #1 of a twin runs
  /// OK but motor #2 errors, the function returns the second motor's
  /// failure — operator gets accurate diagnostics, and we don't keep
  /// cranking motors after a confirmed jam.
  ///
  /// For a single-motor slot this behaves identically to [dispense].
  Future<DispenseResult> dispenseSlot(
    List<int> motorIds, {
    int type = 2,
    int curtain = 0,
  }) async {
    if (motorIds.isEmpty) {
      return DispenseResult(
          success: false, message: 'Пустой слот (нет motor id)');
    }
    DispenseResult? last;
    for (final id in motorIds) {
      last = await dispense(id, type: type, curtain: curtain);
      if (!last.success) return last;
    }
    return last!;
  }

  // ---------- logging ----------

  String _hex(List<int> data) =>
      data.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

  void _addLog(LogEntry e) {
    _logHistory.add(e);
    if (_logHistory.length > 1000) {
      _logHistory.removeRange(0, _logHistory.length - 1000);
    }
    if (!_logCtrl.isClosed) _logCtrl.add(e);
  }

  /// Wipe the in-memory log buffer. Doesn't touch the live stream
  /// (subscribers stay attached); just clears the history that the
  /// service-mode "Board" screen renders.
  void clearLog() {
    _logHistory.clear();
    notifyListeners();
  }

  void _tx(Uint8List data) => _addLog(LogEntry('TX', _hex(data)));
  void _logRx(Uint8List data) => _addLog(LogEntry('RX', _hex(data)));
  void _info(String s) => _addLog(LogEntry('INFO', s));
  void _err(String s) => _addLog(LogEntry('ERR', s));

  @override
  void dispose() {
    _failPending('disposed');
    _rxSub?.cancel();
    _transport?.close();
    _usbEventSub?.cancel();
    _usbPermissionSub?.cancel();
    _healthWatchdog?.cancel();
    _heartbeatTimer?.cancel();
    _logCtrl.close();
    super.dispose();
  }
}
