import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:usb_serial/usb_serial.dart';

/// Per-line entry shown in the diagnostic log panel.
class LogLine {
  LogLine(this.timestamp, this.direction, this.text);

  final DateTime timestamp;
  final LogDir direction;
  final String text;

  String get hhmmssms {
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${two(timestamp.hour)}:${two(timestamp.minute)}:'
        '${two(timestamp.second)}.${three(timestamp.millisecond)}';
  }
}

enum LogDir { tx, rx, info, warn, err }

/// Result of a Motor Run poll cycle (opcode 0x03).
class PollResult {
  PollResult({
    required this.state,
    required this.motorId,
    required this.result,
    required this.peakMa,
    required this.avgMa,
    required this.runtimeMs,
    required this.curtainMs,
    required this.rawHex,
  });

  /// 0 idle, 1 executing, 2 finished
  final int state;
  final int motorId;
  final int result;
  final int peakMa;
  final int avgMa;
  final int runtimeMs;
  final int curtainMs;
  final String rawHex;

  static const _resultLabels = {
    0: 'OK',
    1: 'Overcurrent / stuck',
    2: 'Undercurrent / wire broken',
    3: 'Timeout (>7 s)',
    4: 'Light curtain self-test fail',
    5: 'Feedback EM door not open',
  };

  String get resultText => _resultLabels[result] ?? 'Code $result';
}

/// Direct client for the M102/M109E control board.
///
/// All public methods return raw protocol values so the diagnostic UI
/// can surface exactly what the board said — no abstractions, no
/// silent retries. Every TX/RX hex stream is mirrored into [logs] for
/// the UI's hex log panel.
class BoardClient extends ChangeNotifier {
  // ─── Protocol constants from docs ──────────────────────────────────
  static const int defaultSlaveAddr = 0x01;
  static const int defaultBaud = 9600;
  static const int frameLength = 20;
  static const int dataLength = 16;
  static const int crcLength = 2;

  static const int opGetId = 0x01;
  static const int opPoll = 0x03;
  static const int opScan = 0x04;
  static const int opRun = 0x05;
  static const int opReadTemp = 0x07;
  static const int opWriteDo = 0x08;
  static const int opReadDi = 0x09;
  static const int opReadHum = 0x10; // M109E extension — humidity probe
  static const int opSetAddr = 0xFF;

  /// CH340 VID/PID — used to filter the device list.
  static const int ch340Vid = 0x1A86;
  static const int ch340Pid = 0x7523;

  /// 11-byte M102 "password" — ASCII `18633695826` (a Chinese phone
  /// number, baked into the factory firmware). The board mixes these
  /// bytes into its expected CRC-16 input alongside the frame's first
  /// 18 bytes; if the host computes CRC without them, the frame is
  /// silently dropped (no reply ever comes back). Source: factory
  /// app `Flag.f282CMD_M102_` / `CreatADH.m141biany()`. Default ON
  /// (matches factory `IS_M102GOTOCODE = true`); flip via [setUseM102Password]
  /// for bench boards that don't enforce it (e.g. firmware `2307`).
  static const List<int> m102Password = <int>[
    0x31, 0x38, 0x36, 0x33, 0x33, 0x36, 0x39, 0x35, 0x38, 0x32, 0x36,
  ];

  // ─── State ─────────────────────────────────────────────────────────
  UsbPort? _port;
  UsbDevice? _device;
  StreamSubscription<Uint8List>? _rxSub;
  final List<int> _rxBuffer = [];
  Completer<Uint8List?>? _pending;
  Timer? _pendingTimeout;
  int _slaveAddr = defaultSlaveAddr;
  bool _useM102Password = true;
  String? _firmwareId;

  final List<LogLine> _logs = [];
  static const int _logCap = 500;
  List<LogLine> get logs => List.unmodifiable(_logs);

  bool get isConnected => _port != null;
  UsbDevice? get device => _device;
  String? get firmwareId => _firmwareId;
  int get slaveAddr => _slaveAddr;
  bool get useM102Password => _useM102Password;

  /// Toggle whether the 11-byte [m102Password] is mixed into the CRC.
  /// Factory M109E firmware (e.g. `mj2310`) requires ON; some bench
  /// boards (`2307`) ignore the password — flip OFF if frames echo
  /// without password but get silently dropped with it.
  void setUseM102Password(bool v) {
    _useM102Password = v;
    notifyListeners();
  }

  // ─── Connection ────────────────────────────────────────────────────

  Future<List<UsbDevice>> listDevices() async {
    final all = await UsbSerial.listDevices();
    _log(LogDir.info, 'Found ${all.length} USB device(s): '
        '${all.map((d) => '${d.productName ?? "?"} '
            '(VID=${d.vid?.toRadixString(16)} '
            'PID=${d.pid?.toRadixString(16)})').join(", ")}');
    return all;
  }

  Future<bool> connect(UsbDevice dev, {int baud = defaultBaud}) async {
    await disconnect();
    final port = await dev.create();
    if (port == null || !await port.open()) {
      _log(LogDir.err, 'open() failed for ${dev.productName}');
      return false;
    }
    // Match m102_tester exactly: do NOT touch DTR / RTS. The CH340
    // chip in the M109E kiosk wiring uses RTS as its **automatic**
    // DE/RE direction control for the RS-485 transceiver — the chip
    // raises RTS for the duration of an outgoing UART byte and drops
    // it afterwards, so the transceiver is in TX exactly when needed
    // and RX otherwise.
    //
    // Explicitly calling setRTS(false) (or setDTR(false)) overrides
    // that auto-toggle and pins the line LOW — meaning the transceiver
    // never enters TX, and our frames are accepted by the chip but
    // never make it to the bus. Symptom: TX appears in our log, board
    // never sees it, every reply times out. Hence: leave the line
    // alone after open(), let the driver handle direction.
    await port.setPortParameters(
      baud,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );
    _port = port;
    _device = dev;
    _rxBuffer.clear();
    _rxSub = port.inputStream!.listen(
      _onRx,
      onError: (e) => _log(LogDir.err, 'rx stream: $e'),
    );
    _log(LogDir.info, 'Opened ${dev.productName ?? "device"} @ '
        '${baud}bps 8N1, slave=$_slaveAddr');
    notifyListeners();
    return true;
  }

  Future<void> disconnect() async {
    await _rxSub?.cancel();
    _rxSub = null;
    _pendingTimeout?.cancel();
    _pending?.complete(null);
    _pending = null;
    try {
      await _port?.close();
    } catch (_) {}
    _port = null;
    _device = null;
    _firmwareId = null;
    _rxBuffer.clear();
    _log(LogDir.info, 'Closed');
    notifyListeners();
  }

  /// Address the board responds to. Re-emit on change so the UI label
  /// reflects what's currently being sent.
  void setSlaveAddr(int addr) {
    _slaveAddr = addr;
    notifyListeners();
  }

  // ─── Public protocol calls ─────────────────────────────────────────

  /// Send Get ID to each slave address 1..8 and report which actually
  /// responded. Returns the list of responding addresses. Used by the
  /// UI's "find board" button when 0x01 timeouts on everything — the
  /// board may have been provisioned on a different slave address.
  Future<List<int>> scanAddresses() async {
    final saved = _slaveAddr;
    final found = <int>[];
    for (var addr = 1; addr <= 8; addr++) {
      _slaveAddr = addr;
      _log(LogDir.info, 'probing slave addr $addr…');
      final resp = await _exchange(
        opGetId,
        Uint8List(dataLength),
        timeout: const Duration(milliseconds: 400),
      );
      if (resp != null) {
        found.add(addr);
        _log(LogDir.info, '  → addr $addr responded');
      }
    }
    if (found.isNotEmpty) {
      _slaveAddr = found.first;
      _log(LogDir.info, 'switched to addr ${found.first}');
    } else {
      _slaveAddr = saved;
      _log(LogDir.warn, 'no board responded on 1..8');
    }
    notifyListeners();
    return found;
  }

  /// 0x01 Get ID — returns the 12-byte serial number as ASCII (with
  /// trailing nulls stripped).
  Future<String?> getId() async {
    final resp = await _exchange(opGetId, Uint8List(dataLength));
    if (resp == null) return null;
    final z = _payload(resp);
    final ascii = String.fromCharCodes(z.take(12))
        .replaceAll(RegExp(r'\x00+$'), '');
    _firmwareId = ascii.isEmpty ? null : ascii;
    notifyListeners();
    return _firmwareId;
  }

  /// 0x03 Motor Poll — query the last RUN's status.
  Future<PollResult?> poll() async {
    final resp = await _exchange(opPoll, Uint8List(dataLength));
    if (resp == null) return null;
    final z = _payload(resp);
    return PollResult(
      state: z[0],
      motorId: z[1],
      result: z[2],
      peakMa: (z[3] << 8) | z[4],
      avgMa: (z[5] << 8) | z[6],
      runtimeMs: (z[7] << 8) | z[8],
      curtainMs: z[9],
      rawHex: _hex(resp),
    );
  }

  /// 0x04 Motor Scan — single-motor self-test. Returns 0xAA/0xBB/0xCC
  /// per docs (normal / abnormal / overload).
  Future<int?> scan(int motorId) async {
    final data = Uint8List(dataLength)..[0] = motorId & 0xFF;
    final resp = await _exchange(opScan, data);
    if (resp == null) return null;
    return _payload(resp)[0];
  }

  /// 0x05 Motor Run — start a motor with type and curtain config.
  /// Returns Z1: 0 started / 1 invalid index / 2 another motor busy.
  Future<int?> run(
    int motorId, {
    int type = 2, // 0 no-fb EM, 1 fb EM, 2 two-wire, 3 three-wire
    int curtain = 0, // 0 ignore / 1 expect drop / 2 stop-on-drop
    int overcurrent = 0,
    int undercurrent = 0,
    int timeoutTenths = 0,
  }) async {
    final data = Uint8List(dataLength)
      ..[0] = motorId & 0xFF
      ..[1] = type & 0xFF
      ..[2] = curtain & 0xFF
      ..[3] = overcurrent & 0xFF
      ..[4] = undercurrent & 0xFF
      ..[5] = timeoutTenths & 0xFF;
    final resp = await _exchange(opRun, data);
    if (resp == null) return null;
    return _payload(resp)[0];
  }

  /// 0x07 Read Temp — returns ºC (1 decimal). `-50.0` means no probe.
  Future<double?> readTemp() async {
    final resp = await _exchange(opReadTemp, Uint8List(dataLength));
    if (resp == null) return null;
    final z = _payload(resp);
    final raw = (z[0] << 8) | z[1];
    final signed = raw >= 0x8000 ? raw - 0x10000 : raw;
    return signed / 10.0;
  }

  /// 0x10 Read Humidity — M109E extension. 0..100 %. Returns null if
  /// the board doesn't support the opcode (no response within timeout).
  Future<int?> readHumidity() async {
    final resp = await _exchange(opReadHum, Uint8List(dataLength));
    if (resp == null) return null;
    final z = _payload(resp);
    return z[0];
  }

  /// 0x08 Write DO — `on` 0/1 for the indexed output (0..7).
  Future<bool> writeDo(int index, bool on) async {
    final data = Uint8List(dataLength)
      ..[0] = index & 0xFF
      ..[1] = on ? 0x01 : 0x00;
    final resp = await _exchange(opWriteDo, data);
    if (resp == null) return false;
    final z = _payload(resp);
    // Per docs Z2 = Y2 + 0xF0 (i.e., 0xF0 for off, 0xF1 for on).
    return z[1] == (on ? 0xF1 : 0xF0);
  }

  /// 0x09 Read DI — returns the 8-byte raw payload (Z1..Z4 are DI1..4
  /// per M102 docs; M109E may surface more — we hand the caller the
  /// full payload so the UI can display each bit).
  Future<Uint8List?> readDi() async {
    final resp = await _exchange(opReadDi, Uint8List(dataLength));
    if (resp == null) return null;
    return Uint8List.fromList(_payload(resp));
  }

  /// Set the board's slave address via the broadcast (0xFF) channel.
  /// Per docs only the host + one board should be on the bus when this
  /// is called. After success, switches our local [_slaveAddr] too.
  Future<bool> setSlaveAddress(int newAddr) async {
    if (newAddr < 1 || newAddr > 8) return false;
    final data = Uint8List(dataLength)..[0] = newAddr & 0xFF;
    // Use broadcast address 0xFF for this request.
    final savedAddr = _slaveAddr;
    _slaveAddr = 0xFF;
    final resp = await _exchange(opSetAddr, data);
    _slaveAddr = savedAddr;
    if (resp == null) return false;
    final z = _payload(resp);
    if (z[0] == newAddr) {
      _slaveAddr = newAddr;
      notifyListeners();
      return true;
    }
    return false;
  }

  /// Send a raw 20-byte frame and return the raw response (or null on
  /// timeout). Useful for trying experimental opcodes the docs don't
  /// cover. Caller supplies the full data segment (16 bytes); CRC is
  /// computed for them.
  Future<Uint8List?> sendRaw({
    required int opcode,
    required Uint8List data16,
    int? overrideAddr,
  }) async {
    final addr = overrideAddr ?? _slaveAddr;
    final saved = _slaveAddr;
    if (overrideAddr != null) _slaveAddr = overrideAddr;
    try {
      return await _exchange(opcode, data16, addrOverride: addr);
    } finally {
      _slaveAddr = saved;
    }
  }

  // ─── Internals ─────────────────────────────────────────────────────

  Future<Uint8List?> _exchange(
    int opcode,
    Uint8List data16, {
    int? addrOverride,
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final port = _port;
    if (port == null) {
      _log(LogDir.err, 'not connected');
      return null;
    }
    if (data16.length != dataLength) {
      _log(LogDir.err, 'data must be $dataLength bytes, got ${data16.length}');
      return null;
    }
    final addr = addrOverride ?? _slaveAddr;
    final frame = _buildFrame(addr, opcode, data16);
    _pending = Completer<Uint8List?>();
    _pendingTimeout = Timer(timeout, () {
      if (_pending != null && !_pending!.isCompleted) {
        _log(LogDir.warn, 'rx timeout for op '
            '0x${opcode.toRadixString(16).padLeft(2, '0').toUpperCase()}');
        _pending!.complete(null);
      }
    });
    _log(LogDir.tx, _hex(frame));
    await port.write(frame);
    final resp = await _pending!.future;
    _pendingTimeout?.cancel();
    _pending = null;
    _pendingTimeout = null;
    if (resp == null) return null;
    if (!_validate(resp)) {
      _log(LogDir.err, 'frame failed CRC / length check');
      return null;
    }
    return resp;
  }


  /// Slice off the 16-byte data segment from a full 20-byte frame.
  List<int> _payload(Uint8List frame) =>
      frame.sublist(2, 2 + dataLength).toList();

  Uint8List _buildFrame(int addr, int opcode, Uint8List data16) {
    final out = Uint8List(frameLength);
    out[0] = addr & 0xFF;
    out[1] = opcode & 0xFF;
    for (var i = 0; i < dataLength; i++) {
      out[2 + i] = data16[i];
    }
    // CRC over addr+op+data (18 bytes). Optionally appended by the
    // 11-byte [m102Password] so the result matches the factory
    // firmware's check — boards that enforce the password silently
    // drop frames whose CRC was computed without it.
    final crcInput = _useM102Password
        ? <int>[...out.sublist(0, 2 + dataLength), ...m102Password]
        : out.sublist(0, 2 + dataLength).toList();
    final crc = _crc16Modbus(crcInput);
    out[18] = crc & 0xFF; // low byte first per docs
    out[19] = (crc >> 8) & 0xFF;
    return out;
  }

  /// Accept any 20-byte frame. We deliberately do NOT verify the
  /// incoming CRC — the factory M102 firmware appends [m102Password]
  /// into its CRC computation, but the exact algorithm for replies
  /// has variants across firmware revisions. m102_tester also skips
  /// CRC validation on RX and reads the payload directly; mirroring
  /// that avoids dropping legitimate replies as "CRC mismatch".
  bool _validate(Uint8List frame) => frame.length == frameLength;

  void _onRx(Uint8List chunk) {
    _rxBuffer.addAll(chunk);
    while (_rxBuffer.length >= frameLength) {
      final frame = Uint8List.fromList(_rxBuffer.sublist(0, frameLength));
      _rxBuffer.removeRange(0, frameLength);
      _log(LogDir.rx, _hex(frame));
      final p = _pending;
      if (p != null && !p.isCompleted) p.complete(frame);
    }
  }

  static int _crc16Modbus(List<int> bytes) {
    var crc = 0xFFFF;
    for (final b in bytes) {
      crc ^= b & 0xFF;
      for (var i = 0; i < 8; i++) {
        if ((crc & 1) != 0) {
          crc = (crc >> 1) ^ 0xA001;
        } else {
          crc >>= 1;
        }
      }
    }
    return crc & 0xFFFF;
  }

  String _hex(Uint8List bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');

  void _log(LogDir dir, String text) {
    _logs.add(LogLine(DateTime.now(), dir, text));
    if (_logs.length > _logCap) {
      _logs.removeRange(0, _logs.length - _logCap);
    }
    notifyListeners();
  }

  void clearLog() {
    _logs.clear();
    notifyListeners();
  }
}
