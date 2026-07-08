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
/// Android has no Dart termios API, so ALL I/O goes through the device's
/// **busybox** (shipped in /system/xbin on these tablets):
///   • config — `busybox stty` sets 9600 8N1, raw, `clocal`;
///   • RX     — a persistent `busybox cat <path>` streams incoming bytes;
///   • TX     — a persistent `busybox dd of=<path> bs=64` fed via stdin.
///
/// Driving I/O through busybox (rather than `dart:io` File on the char
/// device, which proved unreliable) matches the shell path verified to
/// talk to an M109E on /dev/ttyS2. Requires the node to be world-rw
/// (0666), busybox present, and SELinux permissive — all true on the
/// BKP910PRO-class tablets. No root needed.
class NativeUartTransport extends BoardTransport {
  NativeUartTransport(
    this.path, {
    this.baud = 9600,
    this.busybox = defaultBusybox,
  });

  /// e.g. `/dev/ttyS2`.
  final String path;
  final int baud;
  final String busybox;
  static const String defaultBusybox = '/system/xbin/busybox';

  Process? _reader; // busybox cat <path>
  Process? _writerProc; // busybox dd of=<path>
  final _rx = StreamController<Uint8List>.broadcast();

  @override
  String get description => path;

  @override
  Stream<Uint8List> get onData => _rx.stream;

  @override
  Future<bool> open() async {
    // 1) Configure the line. `clocal` (ignore modem-control lines) is what
    //    lets cat/dd not block on carrier. A non-zero exit from busybox
    //    hitting an unsupported ioctl ("Not a typewriter" on -a readback)
    //    is a warning, not fatal — speed + framing still get applied.
    try {
      final stty = await Process.run(busybox, [
        'stty', '-F', path, '$baud',
        'cs8', '-cstopb', '-parenb', 'clocal', 'raw', '-echo',
      ]);
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
      _reader = await Process.start(busybox, ['cat', path]);
    } catch (e) {
      log('cat $path failed: $e');
      return false;
    }
    _reader!.stdout.listen(
      (chunk) => _rx.add(Uint8List.fromList(chunk)),
      onError: _rx.addError,
    );
    _reader!.stderr.listen(
        (e) => log('cat stderr: ${String.fromCharCodes(e).trim()}'));
    // 3) TX writer — dd reads our stdin and writes straight to the node.
    try {
      _writerProc = await Process.start(busybox, ['dd', 'of=$path', 'bs=64']);
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
