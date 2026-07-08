import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:usb_serial/usb_serial.dart';

/// Abstract byte pipe to the M102/M109E board. The protocol layer in
/// [BoardClient] is transport-agnostic; it just needs to push 20-byte
/// frames out and receive raw bytes back. Two implementations:
///   • [UsbTransport]        — a USB-serial adapter (CH340/FTDI/…)
///   • [NativeUartTransport] — an on-SoC UART exposed as /dev/ttySX
abstract class BoardTransport {
  /// Optional sink for diagnostic lines (wired to the BUS LOG). Set by
  /// [BoardClient] before [open] so setup failures are visible.
  void Function(String msg)? logger;

  void log(String msg) => logger?.call(msg);

  /// Short human label (USB product name or the ttyS path).
  String get description;

  /// Open + configure the port at 9600 8N1. Returns false on failure.
  Future<bool> open();

  /// Send a raw frame.
  Future<void> write(Uint8List data);

  /// Incoming bytes as they arrive (raw, still to be de-framed).
  Stream<Uint8List> get onData;

  /// Release the port.
  Future<void> close();
}

/// USB-serial transport via the `usb_serial` plugin. Behaviour matches
/// the original BoardClient exactly, including the deliberate choice to
/// NOT touch DTR/RTS (the CH340 uses RTS as automatic RS-485 direction
/// control; pinning it low would keep the transceiver out of TX).
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
    if (port == null || !await port.open()) {
      log('USB open() failed');
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
  Future<void> write(Uint8List data) async => _port?.write(data);

  @override
  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _port?.close();
    } catch (_) {}
    _port = null;
    if (!_rx.isClosed) await _rx.close();
  }
}

/// Native on-SoC UART transport for industrial tablets that expose the
/// serial port directly as `/dev/ttySX` (with a hardware 232/485 toggle),
/// i.e. WITHOUT a USB-serial converter — so the `usb_serial` plugin can't
/// see it.
///
/// Android has no Dart-level termios API, so ALL of the work is delegated
/// to the device's **busybox** (which the tablet ships in /system/xbin):
///   • config — `busybox stty` sets 9600 8N1, raw, `clocal`;
///   • RX     — a persistent `busybox cat <path>` streams incoming bytes
///              to its stdout (cat raw-writes each chunk as it reads, and
///              in the port's raw mode a read returns as soon as ≥1 byte
///              is available, so 20-byte frames arrive promptly);
///   • TX     — a persistent `busybox dd of=<path> bs=64` whose stdin we
///              feed frames into (dd writes each read straight to the tty).
///
/// Doing I/O through busybox (rather than `dart:io` File on the character
/// device) matches exactly the shell path that was verified to talk to an
/// M109E on /dev/ttyS2, and avoids dart:io's char-device quirks.
///
/// Requirements (true on the BKP910PRO-class tablets): the node is
/// world-rw (0666) so no root is needed, busybox is present, and SELinux
/// is permissive so the app (untrusted_app) may exec it.
class NativeUartTransport extends BoardTransport {
  NativeUartTransport(
    this.path, {
    this.baud = 9600,
    this.busybox = defaultBusybox,
  });

  /// e.g. `/dev/ttyS2`.
  final String path;
  final int baud;

  /// Path to the busybox multi-call binary used for stty/cat/dd.
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
    //    lets cat/dd not block waiting for carrier. Some drivers reject a
    //    couple of the ioctls busybox tries (harmless "Not a typewriter"
    //    on -a readback) but still apply speed + framing — so we log a
    //    non-zero exit as a warning rather than treating it as fatal.
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
    _reader!.stderr.listen((e) => log('cat stderr: ${String.fromCharCodes(e).trim()}'));

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

    log('native UART ready on $path @ ${baud}bps 8N1');
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
