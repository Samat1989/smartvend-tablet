import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../board/board_client.dart';
import '../services/device_storage.dart';
import '../services/strings.dart';

/// Service-mode "Плата" screen — connection control, M102 CRC-password
/// switch, and a live bus log mirroring the MMD diagnostic UI. Lets the
/// operator (or whoever is debugging on-site) see exactly what's
/// going out and coming back, flip the password by hand if auto-detect
/// got it wrong, and drop / re-establish the USB-serial link without
/// rebooting the app.
class BoardDiagScreen extends StatefulWidget {
  const BoardDiagScreen({super.key});

  @override
  State<BoardDiagScreen> createState() => _BoardDiagScreenState();
}

class _BoardDiagScreenState extends State<BoardDiagScreen> {
  final _logScroll = ScrollController();
  StreamSubscription<LogEntry>? _logSub;

  /// Native UART nodes discovered under /dev on this device (varies by
  /// SoC), for the port picker.
  List<String> _nativePorts = [];
  bool _detecting = false;

  @override
  void initState() {
    super.initState();
    final board = context.read<BoardClient>();
    board.listNativePorts().then((l) {
      if (mounted) setState(() => _nativePorts = l);
    });
    _logSub = board.logStream.listen((_) {
      // Re-render is driven by the watch() in build(); we just need
      // to nudge the scroll view down after the new line is laid out.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScroll.hasClients) {
          _logScroll.animateTo(
            _logScroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _logScroll.dispose();
    super.dispose();
  }

  Future<void> _toggleConnection() async {
    final board = context.read<BoardClient>();
    final storage = context.read<DeviceStorage>();
    if (board.isConnected) {
      await board.disconnect();
    } else {
      final path = storage.serialPortPath;
      if (path != null) {
        await board.connectNative(path);
      } else {
        await board.autoConnect();
      }
    }
  }

  /// Switch the board link between a USB adapter (`null`) and a native
  /// on-SoC UART node. Persists the choice and reconnects immediately.
  Future<void> _selectPort(String? path) async {
    final board = context.read<BoardClient>();
    final storage = context.read<DeviceStorage>();
    await storage.setSerialPortPath(path);
    await board.disconnect();
    if (path != null) {
      await board.connectNative(path);
    } else {
      await board.autoConnect();
    }
  }

  /// Probe every discovered node for a live board and, on a hit, persist +
  /// connect to it. Handles fleets of mixed tablets where the node number
  /// (or even name prefix) differs per model.
  Future<void> _autoDetect() async {
    final board = context.read<BoardClient>();
    final storage = context.read<DeviceStorage>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _detecting = true);
    final candidates =
        _nativePorts.isNotEmpty ? _nativePorts : await board.listNativePorts();
    final found = await board.autoDetectNativePort(candidates);
    if (!mounted) return;
    if (found != null) {
      await storage.setSerialPortPath(found);
      await board.connectNative(found);
    }
    if (!mounted) return;
    setState(() => _detecting = false);
    messenger.showSnackBar(SnackBar(
      content: Text(found != null
          ? 'Плата найдена: $found'
          : 'Плата не найдена ни на одной ноде'),
      backgroundColor: found != null ? Colors.green : Colors.redAccent,
    ));
  }

  Future<void> _togglePassword(BuildContext context) async {
    final board = context.read<BoardClient>();
    final storage = context.read<DeviceStorage>();
    final next = !board.useM102Password;
    board.setUseM102Password(next);
    await storage.setUseM102Password(next);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final board = context.watch<BoardClient>();
    return Scaffold(
      backgroundColor: Colors.grey.shade900,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          s.t('service_board'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _StatusCard(board: board, s: s),
            _ControlsCard(
              board: board,
              s: s,
              onToggleConnection: _toggleConnection,
              onTogglePassword: () => _togglePassword(context),
            ),
            _SerialModeCard(
              selectedPath: context.watch<DeviceStorage>().serialPortPath,
              nodes: _nativePorts,
              detecting: _detecting,
              onSelectPort: _selectPort,
              onAutoDetect: _autoDetect,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _LogPanel(
                board: board,
                scrollController: _logScroll,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Board-link selector: USB adapter (auto-detect CH340) vs a native
/// on-SoC UART node (/dev/ttySX) for industrial tablets. The choice is
/// persisted so the board auto-connects the right way on boot.
class _SerialModeCard extends StatelessWidget {
  const _SerialModeCard({
    required this.selectedPath,
    required this.nodes,
    required this.detecting,
    required this.onSelectPort,
    required this.onAutoDetect,
  });

  /// Null = USB adapter; otherwise the /dev/ttySX node.
  final String? selectedPath;

  /// Native UART nodes discovered under /dev on this device.
  final List<String> nodes;
  final bool detecting;
  final Future<void> Function(String? path) onSelectPort;
  final VoidCallback onAutoDetect;

  @override
  Widget build(BuildContext context) {
    // Union of discovered nodes + the persisted one, so a node this build
    // didn't enumerate (e.g. a ttyMT* on another tablet) still shows.
    final paths = <String>{
      ...nodes,
      ?selectedPath,
    }.toList()
      ..sort();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'ПОРТ ПЛАТЫ',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              if (detecting)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.greenAccent),
                )
              else
                TextButton.icon(
                  icon: const Icon(Icons.search,
                      size: 16, color: Colors.greenAccent),
                  label: const Text('Автопоиск',
                      style:
                          TextStyle(color: Colors.greenAccent, fontSize: 12)),
                  onPressed: onAutoDetect,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _chip(label: 'USB', path: null),
              for (final p in paths)
                _chip(label: p.replaceFirst('/dev/', ''), path: p),
            ],
          ),
          if (paths.isEmpty) ...[
            const SizedBox(height: 6),
            const Text(
              'Нативные порты не найдены — нажмите «Автопоиск».',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip({required String label, required String? path}) {
    final selected = selectedPath == path;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) {
        if (!selected) onSelectPort(path);
      },
      labelStyle: const TextStyle(
        color: Colors.black,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      backgroundColor: Colors.grey.shade300,
      selectedColor: Colors.greenAccent,
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.board, required this.s});

  final BoardClient board;
  final Strings s;

  @override
  Widget build(BuildContext context) {
    final connected = board.isConnected;
    final healthy = board.isHealthy;
    final Color dot;
    final String label;
    if (!connected) {
      dot = Colors.redAccent;
      label = s.t('board_connect');
    } else if (!healthy) {
      dot = Colors.orange;
      label = s.t('board_health_lost');
    } else {
      dot = Colors.greenAccent;
      label = s.t('board_health_ok');
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: dot,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${s.t('board_firmware')}: '
            '${board.firmwareId ?? "—"}    '
            '${s.t('board_slave_addr')}: ${board.slaveAddr}    '
            'baud: ${board.baud}',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
          if (board.selectedDevice != null) ...[
            const SizedBox(height: 4),
            Text(
              '${board.selectedDevice!.productName ?? "?"}  '
              'VID=0x${board.selectedDevice!.vid?.toRadixString(16).toUpperCase()}  '
              'PID=0x${board.selectedDevice!.pid?.toRadixString(16).toUpperCase()}',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ControlsCard extends StatelessWidget {
  const _ControlsCard({
    required this.board,
    required this.s,
    required this.onToggleConnection,
    required this.onTogglePassword,
  });

  final BoardClient board;
  final Strings s;
  final VoidCallback onToggleConnection;
  final VoidCallback onTogglePassword;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              icon: Icon(board.isConnected ? Icons.link_off : Icons.link),
              label: Text(board.isConnected
                  ? s.t('board_disconnect')
                  : s.t('board_reconnect')),
              style: FilledButton.styleFrom(
                backgroundColor: board.isConnected
                    ? Colors.redAccent
                    : Colors.green,
              ),
              onPressed: onToggleConnection,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.icon(
              icon: Icon(board.useM102Password
                  ? Icons.lock
                  : Icons.lock_open),
              label: Text(
                  '${s.t('service_m102_password')}: '
                  '${board.useM102Password ? "ON" : "OFF"}'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.purple,
              ),
              onPressed: onTogglePassword,
            ),
          ),
        ],
      ),
    );
  }
}

class _LogPanel extends StatelessWidget {
  const _LogPanel({
    required this.board,
    required this.scrollController,
  });

  final BoardClient board;
  final ScrollController scrollController;

  Color _colorFor(String dir) => switch (dir) {
        'TX' => Colors.lightBlueAccent,
        'RX' => Colors.greenAccent,
        'RAW' => Colors.tealAccent,
        'INFO' => Colors.white70,
        'ERR' => Colors.redAccent,
        _ => Colors.white70,
      };

  String _ts(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}'
        '.${three(t.millisecond)}';
  }

  @override
  Widget build(BuildContext context) {
    final logs = board.logHistory;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: const BoxDecoration(
              color: Color(0xFF1A1A1A),
              borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Row(
              children: [
                const Text(
                  'BUS LOG',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '(${logs.length})',
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                  ),
                ),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.clear_all,
                      color: Colors.white70, size: 18),
                  onPressed: board.clearLog,
                  tooltip: 'Clear',
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              itemCount: logs.length,
              itemBuilder: (ctx, i) {
                final e = logs[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: SelectableText(
                    '${_ts(e.time)}  ${e.dir.padRight(4)}  ${e.text}',
                    style: TextStyle(
                      color: _colorFor(e.dir),
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.25,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
