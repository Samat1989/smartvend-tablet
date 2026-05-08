import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:usb_serial/usb_serial.dart';

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

/// Driver for M102 / M109E vending control board over USB-Serial (FTDI / CH340).
///
/// Handles low-level frame building (20-byte fixed, Modbus CRC-16 low-first),
/// transport over a UsbPort, and request/response correlation.
class BoardClient extends ChangeNotifier {
  /// Known USB-to-Serial chip VIDs we'll try to auto-connect to.
  static const Set<int> knownUsbSerialVids = {
    0x0403, // FTDI: FT232R/FT232H/FT2232/FT4232/FT-X
    0x1A86, // QinHeng: CH340/CH341
    0x10C4, // Silicon Labs: CP210x
    0x067B, // Prolific: PL2303
  };

  List<UsbDevice> _devices = [];
  UsbDevice? _selected;
  UsbPort? _port;
  StreamSubscription<Uint8List>? _rxSub;
  StreamSubscription<UsbEvent>? _usbEventSub;

  final _rxBuffer = BytesBuilder();
  Completer<Uint8List>? _pendingResponse;
  int? _pendingOpcode;
  Timer? _pendingTimeout;

  int _baud = 9600;
  int _slaveAddr = 1;

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
  bool get isConnected => _port != null;
  int get baud => _baud;
  int get slaveAddr => _slaveAddr;
  Stream<LogEntry> get logStream => _logCtrl.stream;
  List<LogEntry> get logHistory => List.unmodifiable(_logHistory);

  BoardClient() {
    _usbEventSub = UsbSerial.usbEventStream?.listen((event) async {
      _info('USB event: ${event.event} ${event.device?.productName ?? ""}');
      // On any USB attach, refresh and try to auto-connect if we're not already.
      await refreshDevices();
      if (!isConnected && event.event == UsbEvent.ACTION_USB_ATTACHED) {
        await Future.delayed(const Duration(milliseconds: 500));
        await autoConnect();
      }
      // On detach, drop our handle so we can re-attach cleanly later.
      if (event.event == UsbEvent.ACTION_USB_DETACHED && isConnected) {
        await disconnect();
      }
    });
  }

  Future<void> refreshDevices() async {
    final devs = await UsbSerial.listDevices();
    _devices = devs;
    if (_selected != null && !devs.any((d) => d.deviceId == _selected!.deviceId)) {
      _selected = null;
    }
    _selected ??= devs.isNotEmpty ? devs.first : null;
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

  /// Auto-detect a known USB-Serial adapter (FTDI / CH340 / CP210x / PL2303)
  /// and connect to the first one found. Returns true if connected.
  Future<bool> autoConnect() async {
    if (isConnected) return true;
    await refreshDevices();
    final candidates = _devices.where((d) => knownUsbSerialVids.contains(d.vid));
    final first = candidates.isNotEmpty ? candidates.first : null;
    if (first == null) {
      _info('Auto-connect: no known USB-serial adapter found');
      return false;
    }
    _info('Auto-connect: trying ${first.productName ?? "device"} '
        '(vid=0x${first.vid?.toRadixString(16)})');
    return connect(device: first);
  }

  Future<bool> connect({UsbDevice? device, int? baud, int? slaveAddr}) async {
    final dev = device ?? _selected;
    if (dev == null) {
      _err('No device selected');
      return false;
    }
    await disconnect();
    if (baud != null) _baud = baud;
    if (slaveAddr != null) _slaveAddr = slaveAddr;

    try {
      final port = await dev.create();
      if (port == null) {
        _err('create() returned null');
        return false;
      }
      final opened = await port.open();
      if (!opened) {
        _err('port.open() failed (permission denied?)');
        return false;
      }
      await port.setDTR(true);
      await port.setRTS(true);
      await port.setPortParameters(
        _baud,
        UsbPort.DATABITS_8,
        UsbPort.STOPBITS_1,
        UsbPort.PARITY_NONE,
      );
      _port = port;
      _selected = dev;
      _consecutiveFailures = 0;
      _rxSub = port.inputStream!.listen(_onRx, onError: (e) => _err('rx: $e'));
      _info('Opened ${dev.productName ?? "device"} @ $_baud 8N1');
      notifyListeners();
      // Best-effort firmware probe so service mode can show it. Don't await —
      // a missing reply here shouldn't delay the UI's "connected" state.
      // ignore: unawaited_futures
      _refreshFirmwareId();
      return true;
    } catch (e) {
      _err('connect error: $e');
      return false;
    }
  }

  Future<void> _refreshFirmwareId() async {
    try {
      final id = await getId();
      if (id != null && id != _firmwareId) {
        _firmwareId = id;
        notifyListeners();
      }
    } catch (_) {
      // Probe failure is non-fatal; isHealthy will reflect comm status.
    }
  }

  Future<void> disconnect() async {
    _failPending('disconnected');
    await _rxSub?.cancel();
    _rxSub = null;
    await _port?.close();
    _port = null;
    _rxBuffer.clear();
    _firmwareId = null;
    _consecutiveFailures = 0;
    notifyListeners();
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

  Uint8List buildFrame(int cmd, List<int> data) {
    final frame = Uint8List(20);
    frame[0] = _slaveAddr & 0xFF;
    frame[1] = cmd & 0xFF;
    for (int i = 0; i < data.length && i < 16; i++) {
      frame[2 + i] = data[i] & 0xFF;
    }
    final crc = _crc16Modbus(frame.sublist(0, 18));
    frame[18] = crc[0];
    frame[19] = crc[1];
    return frame;
  }

  /// Send a raw frame and await the next 20-byte response (within [timeout]).
  /// Returns null on timeout or no connection.
  Future<Uint8List?> _sendAndReceive(int opcode, List<int> data,
      {Duration timeout = const Duration(milliseconds: 800)}) async {
    if (_port == null) {
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
      await _port!.write(frame);
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
    return resp;
  }

  void _onRx(Uint8List data) {
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

  Future<String?> getId() async {
    final r = await _sendAndReceive(0x01, List.filled(16, 0));
    if (r == null || r.length < 14) return null;
    final sn = String.fromCharCodes(r.sublist(2, 14).where((b) => b >= 0x20 && b <= 0x7E)).trim();
    return sn.isEmpty ? null : sn;
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
      // Debug-only fake-success path so the full payment → sale → stock
      // pipeline can be exercised on the emulator without USB hardware.
      // Release builds skip this and surface the real "no board" failure.
      if (kDebugMode) {
        _info('--- FAKE DISPENSE motor=$motorIdx (debug, no board attached) ---');
        await Future.delayed(const Duration(milliseconds: 800));
        return DispenseResult(
          success: true,
          message: 'OK (demo, нет реальной платы)',
          finalStatus: PollStatus(
            state: 2,
            motor: motorIdx,
            result: 0,
            peakMa: 0,
            avgMa: 0,
            timeMs: 800,
            curtainMs: curtain == 0 ? 0 : 250,
          ),
        );
      }
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

  void _tx(Uint8List data) => _addLog(LogEntry('TX', _hex(data)));
  void _logRx(Uint8List data) => _addLog(LogEntry('RX', _hex(data)));
  void _info(String s) => _addLog(LogEntry('INFO', s));
  void _err(String s) => _addLog(LogEntry('ERR', s));

  @override
  void dispose() {
    _failPending('disposed');
    _rxSub?.cancel();
    _port?.close();
    _usbEventSub?.cancel();
    _logCtrl.close();
    super.dispose();
  }
}
