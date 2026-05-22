import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:usb_serial/usb_serial.dart';

import 'board_client.dart';

void main() {
  runApp(const MmdApp());
}

class MmdApp extends StatelessWidget {
  const MmdApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'M109E Diagnostic',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF0088FF),
        scaffoldBackgroundColor: const Color(0xFFF2F2F7),
      ),
      home: const DiagScreen(),
    );
  }
}

class DiagScreen extends StatefulWidget {
  const DiagScreen({super.key});

  @override
  State<DiagScreen> createState() => _DiagScreenState();
}

class _DiagScreenState extends State<DiagScreen> {
  final BoardClient _board = BoardClient();
  List<UsbDevice> _devices = [];

  @override
  void initState() {
    super.initState();
    _board.addListener(_onBoardChange);
    _refreshDevices();
  }

  @override
  void dispose() {
    _board.removeListener(_onBoardChange);
    _board.disconnect();
    super.dispose();
  }

  void _onBoardChange() => setState(() {});

  Future<void> _refreshDevices() async {
    final list = await _board.listDevices();
    setState(() => _devices = list);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('M109E Diagnostic'),
          actions: [
            IconButton(
              tooltip: 'Refresh USB devices',
              icon: const Icon(Icons.usb),
              onPressed: _refreshDevices,
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(icon: Icon(Icons.power), text: 'Connect'),
              Tab(icon: Icon(Icons.precision_manufacturing), text: 'Motors'),
              Tab(icon: Icon(Icons.thermostat), text: 'Climate / DO'),
              Tab(icon: Icon(Icons.input), text: 'DI'),
              Tab(icon: Icon(Icons.code), text: 'Raw'),
            ],
          ),
        ),
        body: Column(
          children: [
            _ConnStrip(board: _board),
            Expanded(
              child: TabBarView(
                children: [
                  _ConnectTab(
                    devices: _devices,
                    board: _board,
                    onRefresh: _refreshDevices,
                  ),
                  _MotorsTab(board: _board),
                  _ClimateTab(board: _board),
                  _DiTab(board: _board),
                  _RawTab(board: _board),
                ],
              ),
            ),
            _LogPanel(board: _board),
          ],
        ),
      ),
    );
  }
}

// ─── Status strip shown above the tabs ──────────────────────────────

class _ConnStrip extends StatelessWidget {
  const _ConnStrip({required this.board});
  final BoardClient board;

  @override
  Widget build(BuildContext context) {
    final color = board.isConnected ? Colors.green : Colors.red;
    return Container(
      color: color.withValues(alpha: 0.08),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.circle, size: 12, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              board.isConnected
                  ? '${board.device?.productName ?? "device"} · '
                      'slave=${board.slaveAddr} · '
                      'fw=${board.firmwareId ?? "?"}'
                  : 'Disconnected',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Connect tab ────────────────────────────────────────────────────

class _ConnectTab extends StatelessWidget {
  const _ConnectTab({
    required this.devices,
    required this.board,
    required this.onRefresh,
  });

  final List<UsbDevice> devices;
  final BoardClient board;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('USB devices (${devices.length})',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
              onPressed: onRefresh,
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (devices.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'No USB devices found. Plug in the board and tap Refresh.',
              style: TextStyle(color: Colors.grey),
            ),
          ),
        for (final d in devices)
          Card(
            child: ListTile(
              leading: const Icon(Icons.cable),
              title: Text(d.productName ?? d.manufacturerName ?? 'Unknown'),
              subtitle: Text(
                'VID=0x${d.vid?.toRadixString(16).toUpperCase()} '
                'PID=0x${d.pid?.toRadixString(16).toUpperCase()} '
                'serial=${d.serial ?? "-"}',
              ),
              trailing: ElevatedButton(
                onPressed: board.isConnected && board.device == d
                    ? board.disconnect
                    : () => board.connect(d),
                child: Text(
                  board.isConnected && board.device == d ? 'Disconnect' : 'Open',
                ),
              ),
            ),
          ),
        const Divider(height: 32),
        Text('Identity', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.badge),
              label: const Text('Get ID (0x01)'),
              onPressed: board.isConnected ? () => board.getId() : null,
            ),
            FilledButton.icon(
              icon: const Icon(Icons.tag),
              label: Text('Slave addr: ${board.slaveAddr}'),
              onPressed: board.isConnected
                  ? () => _pickSlave(context, board)
                  : null,
            ),
            FilledButton.icon(
              icon: const Icon(Icons.travel_explore),
              label: const Text('Scan addrs 1..8'),
              onPressed: board.isConnected ? () => board.scanAddresses() : null,
            ),
            FilterChip(
              label: Text(
                board.useM102Password
                    ? 'M102 password: ON'
                    : 'M102 password: OFF',
              ),
              selected: board.useM102Password,
              onSelected: (v) => board.setUseM102Password(v),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (board.firmwareId != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.memory),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SelectableText(
                      'Firmware ID: ${board.firmwareId}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _pickSlave(BuildContext context, BoardClient board) async {
    final ctrl = TextEditingController(text: board.slaveAddr.toString());
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Slave address (1-8)'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final v = int.tryParse(ctrl.text);
              Navigator.of(ctx).pop(v);
            },
            child: const Text('Set'),
          ),
        ],
      ),
    );
    if (picked != null && picked >= 1 && picked <= 8) {
      board.setSlaveAddr(picked);
    }
  }
}

// ─── Motors tab ─────────────────────────────────────────────────────

class _MotorsTab extends StatefulWidget {
  const _MotorsTab({required this.board});
  final BoardClient board;

  @override
  State<_MotorsTab> createState() => _MotorsTabState();
}

class _MotorsTabState extends State<_MotorsTab> {
  final _idCtrl = TextEditingController(text: '0');
  int _type = 2; // default 2-wire
  int _curtain = 0;
  PollResult? _lastPoll;
  int? _lastRunZ1;
  int? _lastScan;
  String? _scanReport;

  Future<void> _run() async {
    final id = int.tryParse(_idCtrl.text) ?? 0;
    final z1 = await widget.board.run(id, type: _type, curtain: _curtain);
    setState(() => _lastRunZ1 = z1);
  }

  Future<void> _poll() async {
    final p = await widget.board.poll();
    setState(() => _lastPoll = p);
  }

  Future<void> _scanOne() async {
    final id = int.tryParse(_idCtrl.text) ?? 0;
    final r = await widget.board.scan(id);
    setState(() => _lastScan = r);
  }

  /// Scan motor IDs 0..99 sequentially. Reports the codes per motor.
  Future<void> _scanAll() async {
    setState(() => _scanReport = 'Scanning…');
    final report = StringBuffer();
    for (var i = 0; i <= 99; i++) {
      if (!mounted) return;
      final r = await widget.board.scan(i);
      final tag = switch (r) {
        0xAA => 'OK',
        0xBB => 'ABN',
        0xCC => 'OVR',
        null => 'TO',
        _ => '0x${r.toRadixString(16)}'
      };
      report.write('${i.toString().padLeft(2, '0')}:$tag  ');
      if ((i + 1) % 6 == 0) report.write('\n');
      if (i % 10 == 9) {
        setState(() => _scanReport = report.toString());
      }
    }
    setState(() => _scanReport = report.toString());
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Motor Run (0x05)',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _idCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Motor index (0..99)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _type,
                        decoration: const InputDecoration(
                          labelText: 'Motor type (Y2)',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                              value: 0, child: Text('0 — EM (no fb)')),
                          DropdownMenuItem(
                              value: 1, child: Text('1 — EM (with fb)')),
                          DropdownMenuItem(
                              value: 2, child: Text('2 — 2-wire motor')),
                          DropdownMenuItem(
                              value: 3, child: Text('3 — 3-wire motor')),
                        ],
                        onChanged: (v) => setState(() => _type = v ?? 2),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _curtain,
                        decoration: const InputDecoration(
                          labelText: 'Light curtain (Y3)',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 0, child: Text('0 — ignore')),
                          DropdownMenuItem(
                              value: 1, child: Text('1 — expect drop')),
                          DropdownMenuItem(
                              value: 2, child: Text('2 — stop on drop')),
                        ],
                        onChanged: (v) => setState(() => _curtain = v ?? 0),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Run motor'),
                      onPressed: widget.board.isConnected ? _run : null,
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: const Text('Poll status'),
                      onPressed: widget.board.isConnected ? _poll : null,
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.search),
                      label: const Text('Scan this motor'),
                      onPressed: widget.board.isConnected ? _scanOne : null,
                    ),
                  ],
                ),
                if (_lastRunZ1 != null) ...[
                  const SizedBox(height: 12),
                  Text('Last Run Z1: $_lastRunZ1 (${switch (_lastRunZ1) {
                    0 => 'started',
                    1 => 'invalid index',
                    2 => 'another motor running',
                    _ => 'unknown',
                  }})'),
                ],
                if (_lastScan != null) ...[
                  const SizedBox(height: 4),
                  Text(
                      'Last Scan: 0x${_lastScan!.toRadixString(16).toUpperCase()} '
                      '(${switch (_lastScan) {
                        0xAA => 'normal',
                        0xBB => 'abnormal',
                        0xCC => 'overload',
                        _ => 'unknown',
                      }})'),
                ],
                if (_lastPoll != null) ...[
                  const SizedBox(height: 12),
                  const Divider(),
                  Text(
                    'Poll  state=${_lastPoll!.state}  motor=${_lastPoll!.motorId}\n'
                    'result=${_lastPoll!.result} (${_lastPoll!.resultText})\n'
                    'peak=${_lastPoll!.peakMa} mA  avg=${_lastPoll!.avgMa} mA  '
                    'runtime=${_lastPoll!.runtimeMs} ms  curtain=${_lastPoll!.curtainMs} ms',
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Motor Scan sweep (0x04, 0..99)',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.bolt),
                  label: const Text('Scan all 100 motor channels'),
                  onPressed: widget.board.isConnected ? _scanAll : null,
                ),
                if (_scanReport != null) ...[
                  const SizedBox(height: 12),
                  SelectableText(
                    _scanReport!,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Climate / DO tab ───────────────────────────────────────────────

class _ClimateTab extends StatefulWidget {
  const _ClimateTab({required this.board});
  final BoardClient board;

  @override
  State<_ClimateTab> createState() => _ClimateTabState();
}

class _ClimateTabState extends State<_ClimateTab> {
  double? _temp;
  int? _humidity;
  final Map<int, bool> _doStates = {};

  Future<void> _readTemp() async {
    final t = await widget.board.readTemp();
    setState(() => _temp = t);
  }

  Future<void> _readHum() async {
    final h = await widget.board.readHumidity();
    setState(() => _humidity = h);
  }

  Future<void> _toggleDo(int i) async {
    final next = !(_doStates[i] ?? false);
    final ok = await widget.board.writeDo(i, next);
    if (ok) setState(() => _doStates[i] = next);
  }

  static const _doLabels = {
    0: 'Fan',
    1: 'Compressor',
    2: 'Glass heater',
    3: 'Light strip',
    4: 'Heater module',
    5: 'DO5',
    6: 'DO6',
    7: 'DO7',
  };

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Sensors', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    FilledButton.icon(
                      icon: const Icon(Icons.thermostat),
                      label: const Text('Read Temp (0x07)'),
                      onPressed: widget.board.isConnected ? _readTemp : null,
                    ),
                    const SizedBox(width: 12),
                    Text(_temp == null
                        ? '—'
                        : '${_temp!.toStringAsFixed(1)} °C'),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton.icon(
                      icon: const Icon(Icons.water_drop),
                      label: const Text('Read Humidity (0x10)'),
                      onPressed: widget.board.isConnected ? _readHum : null,
                    ),
                    const SizedBox(width: 12),
                    Text(_humidity == null ? '—' : '$_humidity %'),
                  ],
                ),
                if (_temp == -50.0) ...[
                  const SizedBox(height: 8),
                  const Text(
                    '−50.0 °C — probe not connected (per docs).',
                    style: TextStyle(color: Colors.orange),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Digital outputs (Write DO 0x08)',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                for (var i = 0; i < 8; i++)
                  SwitchListTile(
                    title: Text('DO$i — ${_doLabels[i] ?? "?"}'),
                    value: _doStates[i] ?? false,
                    onChanged: widget.board.isConnected
                        ? (_) => _toggleDo(i)
                        : null,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─── DI tab ─────────────────────────────────────────────────────────

class _DiTab extends StatefulWidget {
  const _DiTab({required this.board});
  final BoardClient board;

  @override
  State<_DiTab> createState() => _DiTabState();
}

class _DiTabState extends State<_DiTab> {
  Uint8List? _last;

  Future<void> _read() async {
    final r = await widget.board.readDi();
    setState(() => _last = r);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Read DI (0x09)',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        FilledButton.icon(
          icon: const Icon(Icons.refresh),
          label: const Text('Read inputs'),
          onPressed: widget.board.isConnected ? _read : null,
        ),
        const SizedBox(height: 16),
        if (_last != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < _last!.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          SizedBox(width: 60, child: Text('DI${i + 1}')),
                          Icon(
                            _last![i] == 1
                                ? Icons.circle
                                : Icons.circle_outlined,
                            size: 14,
                            color:
                                _last![i] == 1 ? Colors.green : Colors.grey,
                          ),
                          const SizedBox(width: 8),
                          Text(_last![i] == 1
                              ? 'connected (1)'
                              : 'open (0)'),
                          const SizedBox(width: 16),
                          Text(
                            'raw=0x${_last![i].toRadixString(16).padLeft(2, '0').toUpperCase()}',
                            style: const TextStyle(
                                fontFamily: 'monospace',
                                color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ─── Raw frame tab ──────────────────────────────────────────────────

class _RawTab extends StatefulWidget {
  const _RawTab({required this.board});
  final BoardClient board;

  @override
  State<_RawTab> createState() => _RawTabState();
}

class _RawTabState extends State<_RawTab> {
  final _opCtrl = TextEditingController(text: '01');
  final _dataCtrl = TextEditingController(
      text: '00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00');
  String? _result;

  Future<void> _send() async {
    final op = int.tryParse(_opCtrl.text, radix: 16);
    if (op == null) {
      setState(() => _result = 'bad opcode');
      return;
    }
    final bytes = _dataCtrl.text
        .replaceAll(RegExp(r'[^0-9a-fA-F]'), ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .map((s) => int.tryParse(s, radix: 16) ?? 0)
        .toList();
    while (bytes.length < 16) {
      bytes.add(0);
    }
    final data = Uint8List.fromList(bytes.take(16).toList());
    final resp = await widget.board.sendRaw(opcode: op, data16: data);
    setState(() {
      _result = resp == null
          ? '(timeout / null)'
          : resp
              .map(
                  (b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
              .join(' ');
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Send raw 20-byte frame',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text(
          'Frame = [slave] [opcode] [16 data bytes] [CRC16 lo] [CRC16 hi]. '
          'Enter opcode (hex) + the 16 data bytes (hex, any whitespace). '
          'CRC is computed for you.',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _opCtrl,
          decoration: const InputDecoration(
            labelText: 'Opcode (hex)',
            border: OutlineInputBorder(),
            prefixText: '0x',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _dataCtrl,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'Data (16 bytes hex, space-separated)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: const Icon(Icons.send),
          label: const Text('Send frame'),
          onPressed: widget.board.isConnected ? _send : null,
        ),
        const SizedBox(height: 16),
        if (_result != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                'Response: $_result',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ),
        const SizedBox(height: 16),
        Text('Quick presets',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          children: [
            for (final p in const [
              ('Get ID', '01',
                  '00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00'),
              ('Poll', '03',
                  '00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00'),
              ('Run M0 (2w)', '05',
                  '00 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00'),
              ('Temp', '07',
                  '00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00'),
              ('DI', '09',
                  '00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00'),
            ])
              ActionChip(
                label: Text(p.$1),
                onPressed: () {
                  setState(() {
                    _opCtrl.text = p.$2;
                    _dataCtrl.text = p.$3;
                  });
                },
              ),
          ],
        ),
      ],
    );
  }
}

// ─── Log panel pinned to the bottom ─────────────────────────────────

class _LogPanel extends StatefulWidget {
  const _LogPanel({required this.board});
  final BoardClient board;

  @override
  State<_LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<_LogPanel> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.board.addListener(_autoScroll);
  }

  @override
  void dispose() {
    widget.board.removeListener(_autoScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _autoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Color _colorFor(LogDir d) => switch (d) {
        LogDir.tx => Colors.blue.shade300,
        LogDir.rx => Colors.green.shade300,
        LogDir.info => Colors.grey.shade400,
        LogDir.warn => Colors.orange.shade300,
        LogDir.err => Colors.red.shade300,
      };

  String _prefix(LogDir d) => switch (d) {
        LogDir.tx => 'TX',
        LogDir.rx => 'RX',
        LogDir.info => 'i ',
        LogDir.warn => 'W ',
        LogDir.err => 'E ',
      };

  @override
  Widget build(BuildContext context) {
    final logs = widget.board.logs;
    return Container(
      height: 180,
      decoration: const BoxDecoration(
        color: Color(0xFF111111),
        border: Border(top: BorderSide(color: Color(0xFF333333))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            color: const Color(0xFF1A1A1A),
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
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.clear_all,
                      color: Colors.white70, size: 18),
                  onPressed: widget.board.clearLog,
                  tooltip: 'Clear',
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              itemCount: logs.length,
              itemBuilder: (ctx, i) {
                final e = logs[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text(
                    '${e.hhmmssms}  ${_prefix(e.direction)}  ${e.text}',
                    style: TextStyle(
                      color: _colorFor(e.direction),
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.2,
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
