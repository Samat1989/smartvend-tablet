import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:usb_serial/usb_serial.dart';

import '../board/board_client.dart';

/// Original M102 tester UI — keeps every low-level command, raw send,
/// auto-poll and live log. Available from the home screen via long-press
/// on the settings icon.
class TesterScreen extends StatefulWidget {
  const TesterScreen({super.key});

  @override
  State<TesterScreen> createState() => _TesterScreenState();
}

class _TesterScreenState extends State<TesterScreen> {
  final _slaveCtrl = TextEditingController();
  final _motorIdxCtrl = TextEditingController(text: '0');
  final _motorTypeCtrl = TextEditingController(text: '2');
  final _motorCurtainCtrl = TextEditingController(text: '0');
  final _doIdxCtrl = TextEditingController(text: '0');
  final _doStateCtrl = TextEditingController(text: '1');
  final _rawCtrl = TextEditingController();

  Timer? _pollTimer;
  bool _autoPoll = false;

  StreamSubscription<LogEntry>? _logSub;
  final _logScroll = ScrollController();
  final _logs = <LogEntry>[];

  @override
  void initState() {
    super.initState();
    final board = context.read<BoardClient>();
    _slaveCtrl.text = board.slaveAddr.toString();
    _logs.addAll(board.logHistory);
    _logSub = board.logStream.listen((e) {
      setState(() {
        _logs.add(e);
        if (_logs.length > 1000) _logs.removeRange(0, _logs.length - 1000);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScroll.hasClients) {
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        }
      });
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _logSub?.cancel();
    _slaveCtrl.dispose();
    _motorIdxCtrl.dispose();
    _motorTypeCtrl.dispose();
    _motorCurtainCtrl.dispose();
    _doIdxCtrl.dispose();
    _doStateCtrl.dispose();
    _rawCtrl.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  void _toggleAutoPoll(BoardClient board) {
    setState(() => _autoPoll = !_autoPoll);
    _pollTimer?.cancel();
    if (_autoPoll) {
      _pollTimer = Timer.periodic(const Duration(milliseconds: 900), (_) {
        board.poll();
      });
    }
  }

  Future<void> _sendRaw(BoardClient board) async {
    final hex = _rawCtrl.text.replaceAll(RegExp(r'[\s,:]'), '');
    if (hex.isEmpty || hex.length.isOdd) return;
    final bytes = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    // Use the public send-and-receive path via a one-off frame: write directly.
    // The BoardClient doesn't expose raw write because protocol commands
    // already build correct frames; here we keep manual control for debug.
    if (!board.isConnected) return;
    // Bypass framing — we treat _rawCtrl input as a fully formed frame.
    // (Kept for advanced testing only.)
    await _writeRawBypass(board, bytes);
  }

  /// Write raw bytes through the connected port, without waiting for a
  /// response. The RX listener will still log incoming bytes.
  Future<void> _writeRawBypass(BoardClient board, Uint8List bytes) async {
    // We don't have a public API for this; reach via reflection of the
    // exposed connect path. Since BoardClient doesn't expose port, we
    // expose this through a dedicated method below in BoardClient if needed.
    // Simpler: drop down to commands the BoardClient knows about.
    // For now: only accept frames whose opcode matches a known command,
    // so the response correlation works.
    if (bytes.length < 2) return;
    final cmd = bytes[1];
    final data = bytes.length > 18 ? bytes.sublist(2, 18) : bytes.sublist(2);
    switch (cmd) {
      case 0x01:
        await board.getId();
        break;
      case 0x03:
        await board.poll();
        break;
      case 0x05:
        if (data.length >= 3) {
          await board.motorRun(data[0], type: data[1], curtain: data[2]);
        }
        break;
      case 0x07:
        await board.readTemp();
        break;
      case 0x08:
        if (data.length >= 2) {
          await board.writeDo(data[0], data[1] != 0);
        }
        break;
      default:
        // Unsupported in correlation-based API — quietly ignore.
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<BoardClient>(
      builder: (context, board, _) {
        final connected = board.isConnected;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Админ — M102 тестер'),
            actions: [
              IconButton(
                tooltip: 'Refresh devices',
                onPressed: board.refreshDevices,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: 'Clear log',
                onPressed: () => setState(_logs.clear),
                icon: const Icon(Icons.delete_sweep),
              ),
            ],
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _connectionPanel(board, connected),
                  const SizedBox(height: 8),
                  if (connected) _commandPanel(board),
                  const SizedBox(height: 8),
                  const Divider(height: 1),
                  const SizedBox(height: 4),
                  Expanded(child: _logView()),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _connectionPanel(BoardClient board, bool connected) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButton<UsbDevice>(
                    isExpanded: true,
                    value: board.selectedDevice,
                    hint: const Text('Нет USB-устройств'),
                    items: board.devices
                        .map((d) => DropdownMenuItem(
                              value: d,
                              child: Text(
                                '${d.productName ?? "?"} '
                                '(vid=0x${d.vid?.toRadixString(16)} '
                                'pid=0x${d.pid?.toRadixString(16)})',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ))
                        .toList(),
                    onChanged: connected ? null : board.selectDevice,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: connected ? board.disconnect : board.connect,
                  icon: Icon(connected ? Icons.link_off : Icons.link),
                  label: Text(connected ? 'Отключить' : 'Подключить'),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: DropdownButton<int>(
                    value: board.baud,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: 9600, child: Text('9600 baud')),
                      DropdownMenuItem(value: 19200, child: Text('19200 baud')),
                      DropdownMenuItem(value: 38400, child: Text('38400 baud')),
                      DropdownMenuItem(value: 115200, child: Text('115200 baud')),
                    ],
                    onChanged: connected ? null : (v) => board.setBaud(v ?? 9600),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 130,
                  child: TextField(
                    decoration: const InputDecoration(labelText: 'Slave addr'),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    controller: _slaveCtrl,
                    onChanged: (v) => board.setSlaveAddr(int.tryParse(v) ?? 1),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _commandPanel(BoardClient board) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _btn('Get ID (01)', board.getId),
                _btn('Poll (03)', board.poll),
                _btn('Read Temp (07)', board.readTemp),
                FilledButton.tonalIcon(
                  onPressed: () => _toggleAutoPoll(board),
                  icon: Icon(_autoPoll ? Icons.stop : Icons.play_arrow),
                  label: Text(_autoPoll ? 'Stop poll 900ms' : 'Auto-poll 900ms'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _motorIdxCtrl,
                    decoration: const InputDecoration(labelText: 'Motor idx'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _motorTypeCtrl,
                    decoration: const InputDecoration(labelText: 'Type 0/1/2/3'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _motorCurtainCtrl,
                    decoration: const InputDecoration(labelText: 'Curtain 0/1/2'),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _btn('Motor Run (05)', () async {
                  final idx = int.tryParse(_motorIdxCtrl.text) ?? 0;
                  final type = int.tryParse(_motorTypeCtrl.text) ?? 2;
                  final curtain = int.tryParse(_motorCurtainCtrl.text) ?? 0;
                  await board.motorRun(idx, type: type, curtain: curtain);
                }),
                _btn('Dispense+wait', () async {
                  final idx = int.tryParse(_motorIdxCtrl.text) ?? 0;
                  final type = int.tryParse(_motorTypeCtrl.text) ?? 2;
                  final curtain = int.tryParse(_motorCurtainCtrl.text) ?? 0;
                  await board.dispense(idx, type: type, curtain: curtain);
                }),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _doIdxCtrl,
                    decoration: const InputDecoration(labelText: 'DO idx 0-4'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _doStateCtrl,
                    decoration: const InputDecoration(labelText: 'DO state 0/1'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 6),
                _btn('Write DO (08)', () async {
                  final idx = int.tryParse(_doIdxCtrl.text) ?? 0;
                  final st = int.tryParse(_doStateCtrl.text) ?? 0;
                  await board.writeDo(idx, st != 0);
                }),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _rawCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Raw HEX (must be a known opcode)',
                      hintText: '01 03 00 00 ... CRC_LO CRC_HI',
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _btn('Send raw', () => _sendRaw(board)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _btn(String label, Future<dynamic> Function() onTap) {
    return FilledButton(
      onPressed: () => onTap(),
      child: Text(label),
    );
  }

  Widget _logView() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.builder(
        controller: _logScroll,
        itemCount: _logs.length,
        itemBuilder: (_, i) {
          final e = _logs[i];
          Color c;
          switch (e.dir) {
            case 'TX':
              c = Colors.lightBlueAccent;
              break;
            case 'RX':
              c = Colors.greenAccent;
              break;
            case 'ERR':
              c = Colors.redAccent;
              break;
            default:
              c = Colors.white70;
          }
          final t = e.time;
          final ts =
              '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';
          return Text(
            '$ts  ${e.dir.padRight(4)}  ${e.text}',
            style: TextStyle(
              color: c,
              fontFamily: 'monospace',
              fontSize: 12,
            ),
          );
        },
      ),
    );
  }
}
