import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:usb_serial/usb_serial.dart';

/// Abstract byte pipe to the M102/M109E board. [BoardClient]'s protocol,
/// heartbeat and self-heal logic are transport-agnostic — they push
/// 20-byte frames out and receive raw bytes back. Two implementations:
///   • [UsbTransport]        — a USB-serial adapter (CH340/FTDI/…)
///   • [NativeUartTransport] — an on-SoC UART exposed as /dev/ttySX
abstract class BoardTransport {
  /// Optional sink for diagnostic lines (wired to the board log).
  void Function(String msg)? logger;
  void log(String msg) => logger?.call(msg);

  /// Short human label (USB product name or the ttyS path).
  String get description;

  Future<bool> open();
  Future<void> write(Uint8List data);
  Stream<Uint8List> get onData;
  Future<void> close();
}

/// USB-serial transport via the `usb_serial` plugin. Preserves the exact
/// factory behaviour, including the deliberate choice to NOT touch
/// DTR/RTS: the M109E CH340 uses RTS as automatic RS-485 direction
/// control; pinning it low would keep the transceiver out of TX.
class UsbTransport extends BoardTransport {
  UsbTransport(this.device, {this.baud = 9600});

  final UsbDevice device;
  final int baud;

  UsbPort? _port;
  StreamSubscription<Uint8List>? _sub;
  final _rx = StreamController<Uint8List>.broadcast();

  @override
  String get description =>
      device.productName ?? device.manufacturerName ?? 'USB device';

  @override
  Stream<Uint8List> get onData => _rx.stream;

  @override
  Future<bool> open() async {
    final port = await device.create();
    if (port == null) {
      log('create() returned null');
      return false;
    }
    if (!await port.open()) {
      log('port.open() failed (permission denied?)');
      return false;
    }
    await port.setPortParameters(
      baud,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );
    _port = port;
    _sub = port.inputStream!.listen(_rx.add, onError: _rx.addError);
    return true;
  }

  @override
  Future<void> write(Uint8List data) async {
    await _port?.write(data);
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _port?.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    _port = null;
    if (!_rx.isClosed) await _rx.close();
  }
}

/// Native on-SoC UART transport for industrial tablets that expose the
/// board's serial port directly as `/dev/ttySX` (with a hardware 232/485
/// toggle), i.e. WITHOUT a USB-serial converter — so `usb_serial` can't
/// see it.
///
/// Android has no Dart termios API, so config + I/O go through the
/// device's coreutils (`stty`/`cat`/`dd`):
///   • config — `stty` sets baud 8N1, raw, `clocal`;
///   • RX     — a persistent `cat <path>` streams incoming bytes;
///   • TX     — a persistent `dd of=<path> bs=64` fed via stdin.
///
/// The coreutils are provided by busybox OR toybox OR direct PATH
/// commands — which one, and where, varies per tablet. [_resolveRunner]
/// auto-detects a working provider (this used to hardcode
/// `/system/xbin/busybox`, which silently failed on tablets that keep
/// it elsewhere — the doc's §9.1 grabli, hit again on the BarysVend
/// machine where only manual port selection appeared to "not work").
/// Requires the node to be world-rw and SELinux permissive; no root.
class NativeUartTransport extends BoardTransport {
  NativeUartTransport(this.path, {this.baud = 9600});

  /// e.g. `/dev/ttyS2`.
  final String path;
  final int baud;

  // ── Coreutils runner resolution (busybox / toybox / direct) ────────
  // `_runner` is the argv prefix: ['/system/xbin/busybox'] means run
  // `<prefix> stty …`; [] (empty) means run `stty …` straight from PATH.
  static List<String>? _runner;

  static List<String> _argv(String cmd, List<String> args) =>
      [...?_runner, cmd, ...args];

  static Future<bool> _resolveRunner(void Function(String)? log) async {
    if (_runner != null) return true;
    final candidates = <List<String>>[
      ['/system/xbin/busybox'],
      ['/system/bin/busybox'],
      ['/vendor/bin/busybox'],
      ['/system/bin/toybox'],
      ['/vendor/bin/toybox'],
      <String>[], // direct — toolbox/toybox symlinks in PATH
    ];
    for (final pref in candidates) {
      try {
        final argv = [...pref, 'ls', '/dev'];
        final res = await Process.run(argv.first, argv.sublist(1));
        if (res.exitCode == 0) {
          _runner = pref;
          log?.call('serial: команды через '
              '${pref.isEmpty ? "(прямые в PATH)" : pref.first}');
          return true;
        }
      } catch (_) {}
    }
    log?.call('serial: НЕ найден busybox/toybox — нативный порт недоступен');
    return false;
  }

  /// Enumerate the serial-port nodes this device actually exposes.
  /// Two passes whose results merge: a direct /dev listing (may be
  /// SELinux-blocked — swallowed), then per-candidate `ls` probes via
  /// the resolved runner, so `/dev/ttyS1` still shows up for manual
  /// selection even when the directory listing is denied. `ttyUSB*` /
  /// `ttyACM*` are excluded — the USB path owns those.
  static Future<List<String>> listPorts({void Function(String)? log}) async {
    final found = <String>{};
    try {
      for (final e in Directory('/dev').listSync(followLinks: false)) {
        final name = e.path.replaceAll('\\', '/').split('/').last;
        if (RegExp(r'^tty(S|MT|HS|HSL|GS)\d+$').hasMatch(name)) {
          found.add('/dev/$name');
        }
      }
    } catch (_) {}
    if (await _resolveRunner(log)) {
      final candidates = <String>[
        for (var i = 0; i <= 9; i++) '/dev/ttyS$i',
        for (var i = 0; i <= 3; i++) '/dev/ttyMT$i',
        for (var i = 0; i <= 3; i++) '/dev/ttyHS$i',
      ];
      for (final p in candidates) {
        if (found.contains(p)) continue;
        try {
          final argv = _argv('ls', [p]);
          final r = await Process.run(argv.first, argv.sublist(1));
          if (r.exitCode == 0) found.add(p);
        } catch (_) {}
      }
    }
    final list = found.toList()..sort();
    log?.call('порты найдены: ${list.isEmpty ? "нет" : list.join(", ")}');
    return list;
  }

  Process? _reader; // cat <path>
  Process? _writerProc; // dd of=<path>
  final _rx = StreamController<Uint8List>.broadcast();

  @override
  String get description => path;

  @override
  Stream<Uint8List> get onData => _rx.stream;

  @override
  Future<bool> open() async {
    if (!await _resolveRunner(logger)) return false;

    // 1) Configure the line. `clocal` (ignore modem-control lines) is what
    //    lets cat/dd not block on carrier. A non-zero exit from stty
    //    hitting an unsupported ioctl ("Not a typewriter" on -a readback)
    //    is a warning, not fatal — speed + framing still get applied.
    try {
      final argv = _argv('stty', [
        '-F', path, '$baud',
        'cs8', '-cstopb', '-parenb', 'clocal', 'raw', '-echo',
      ]);
      final stty = await Process.run(argv.first, argv.sublist(1));
      if (stty.exitCode != 0) {
        log('stty $path exit=${stty.exitCode} '
            '${stty.stderr.toString().trim()} (continuing)');
      }
    } catch (e) {
      log('stty $path threw: $e');
      return false;
    }
    // 2) RX reader.
    try {
      final argv = _argv('cat', [path]);
      _reader = await Process.start(argv.first, argv.sublist(1));
    } catch (e) {
      log('cat $path failed: $e');
      return false;
    }
    _reader!.stdout.listen(
      (chunk) => _rx.add(Uint8List.fromList(chunk)),
      onError: _rx.addError,
    );
    _reader!.stderr.listen((e) {
      final s = String.fromCharCodes(e).trim();
      if (s.isNotEmpty) log('cat stderr: $s'); // e.g. "Device busy"
    });
    // 3) TX writer — dd reads our stdin and writes straight to the node.
    try {
      final argv = _argv('dd', ['of=$path', 'bs=64']);
      _writerProc = await Process.start(argv.first, argv.sublist(1));
    } catch (e) {
      log('dd of=$path failed: $e');
      _reader?.kill();
      _reader = null;
      return false;
    }
    _writerProc!.stderr.drain(); // swallow dd's "records in/out"
    return true;
  }

  @override
  Future<void> write(Uint8List data) async {
    final w = _writerProc;
    if (w == null) return;
    w.stdin.add(data);
    await w.stdin.flush();
  }

  @override
  Future<void> close() async {
    try {
      await _writerProc?.stdin.close();
    } catch (_) {}
    _writerProc?.kill();
    _writerProc = null;
    _reader?.kill();
    _reader = null;
    if (!_rx.isClosed) await _rx.close();
  }
}
