import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../board/board_client.dart';
import '../models/machine_layout.dart';
import '../services/strings.dart';
import '../services/vending_service.dart';
import '../theme.dart';
import 'layout_editor_screen.dart';

/// Operator-facing motor tester.
///
/// Walks the operator-built [MachineLayout] (shelves + slots, including
/// twin spirals) and shows one card per slot grouped under its shelf
/// header. Tapping a card fires every motor in the slot via
/// [BoardClient.dispenseSlot] with the currently-selected curtain mode
/// and shows the result inline.
///
/// Curtain mode at the top of the screen is the per-test override —
/// includes the priority (=2) variant that's intentionally NOT offered
/// in the main «Режим выдачи» dialog. Useful for one-off diagnostics
/// of the drop sensor without changing how real sales behave.
class TesterScreen extends StatefulWidget {
  const TesterScreen({super.key});

  @override
  State<TesterScreen> createState() => _TesterScreenState();
}

class _TesterScreenState extends State<TesterScreen> {
  /// Curtain mode used for tests started from this screen. Reset to 0
  /// (off) when entering — the operator picks per-session if needed.
  int _curtain = 0;

  /// Currently-running slot key (primary motor id) or null when idle.
  /// Used to disable other cards while a test is in flight (board can
  /// only run one motor at a time).
  int? _runningSlotKey;

  /// Last result per slot, keyed by primary motor id of the slot.
  /// `null` = never tested, `true` = success, `false` = error.
  final Map<int, bool> _results = {};

  /// Optional human label for the result (e.g. localized poll code).
  final Map<int, String> _resultText = {};

  Future<void> _runTest(Slot slot) async {
    if (_runningSlotKey != null) return;
    final s = context.read<Strings>();
    final board = context.read<BoardClient>();
    if (!board.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(s.t('board_not_found')),
        backgroundColor: const Color(0xFFB3261E),
      ));
      return;
    }
    final key = slot.primaryMotorId;
    setState(() => _runningSlotKey = key);
    final r = await board.dispenseSlot(
      slot.motorIds,
      type: 2, // physical machine is all 2-wire; matches motor_layout doc
      curtain: _curtain,
    );
    if (!mounted) return;
    final code = r.finalStatus?.result;
    setState(() {
      _runningSlotKey = null;
      _results[key] = r.success;
      _resultText[key] =
          code != null ? s.pollResult(code) : (r.success ? 'OK' : r.message);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final layout = context.watch<VendingService>().layout;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(s.t('service_test_motors').toUpperCase(),
            style: const TextStyle(
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
                fontSize: 20)),
      ),
      body: Column(
        children: [
          _TopBar(
            curtain: _curtain,
            disabled: _runningSlotKey != null,
            onChanged: (v) => setState(() => _curtain = v),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                const Icon(Icons.info_outline,
                    size: 14, color: AppColors.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    s.t('tap_to_test'),
                    style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: layout.isEmpty
                ? const _EmptyLayoutHint()
                : _ShelvesList(
                    layout: layout,
                    runningSlotKey: _runningSlotKey,
                    results: _results,
                    resultText: _resultText,
                    onTap: _runTest,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Shown when the operator hasn't configured a layout yet. Offers a
/// one-tap jump straight to the editor (where they can pick one of the
/// pre-baked templates) so they don't have to back out through the
/// service menu.
class _EmptyLayoutHint extends StatelessWidget {
  const _EmptyLayoutHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.grid_off,
                size: 56, color: AppColors.onSurfaceVariant),
            const SizedBox(height: 16),
            const Text(
              'Раскладка не настроена',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Откройте редактор раскладки, выберите шаблон '
              '(«Заводская 6×6» или «MP2404 (5 + 5×10)») и затем '
              'возвращайтесь сюда — слоты появятся автоматически.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, color: AppColors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.dashboard_customize),
              label: const Text('Открыть редактор'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const LayoutEditorScreen(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShelvesList extends StatelessWidget {
  const _ShelvesList({
    required this.layout,
    required this.runningSlotKey,
    required this.results,
    required this.resultText,
    required this.onTap,
  });

  final MachineLayout layout;
  final int? runningSlotKey;
  final Map<int, bool> results;
  final Map<int, String> resultText;
  final ValueChanged<Slot> onTap;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      itemCount: layout.shelves.length,
      itemBuilder: (_, i) {
        final shelf = layout.shelves[i];
        return _ShelfBlock(
          shelf: shelf,
          runningSlotKey: runningSlotKey,
          results: results,
          resultText: resultText,
          onTap: onTap,
        );
      },
    );
  }
}

class _ShelfBlock extends StatelessWidget {
  const _ShelfBlock({
    required this.shelf,
    required this.runningSlotKey,
    required this.results,
    required this.resultText,
    required this.onTap,
  });

  final Shelf shelf;
  final int? runningSlotKey;
  final Map<int, bool> results;
  final Map<int, String> resultText;
  final ValueChanged<Slot> onTap;

  @override
  Widget build(BuildContext context) {
    final slots = shelf.slots;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Row(
              children: [
                Text(
                  shelf.label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                    color: AppColors.onSurface,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '× ${slots.length}',
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (slots.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Text(
                'нет слотов',
                style: TextStyle(
                    fontSize: 12, color: AppColors.onSurfaceVariant),
              ),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate:
                  SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: slots.length <= 5 ? slots.length : 5,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 0.95,
              ),
              itemCount: slots.length,
              itemBuilder: (_, j) {
                final slot = slots[j];
                final key = slot.primaryMotorId;
                final running = runningSlotKey == key;
                return _SlotCard(
                  slot: slot,
                  running: running,
                  disabledByOthers: runningSlotKey != null && !running,
                  lastResult: results[key],
                  lastResultText: resultText[key],
                  onTap: () => onTap(slot),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// Curtain-mode segmented selector with section label above it. Disabled
/// while a test is mid-flight so the operator can't change the param
/// while a motor is already running with the previous setting.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.curtain,
    required this.disabled,
    required this.onChanged,
  });

  final int curtain;
  final bool disabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: const BoxDecoration(
        color: AppColors.surfaceContainerLowest,
        border: Border(
          bottom:
              BorderSide(color: AppColors.surfaceContainerHigh, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.t('test_mode_override').toUpperCase(),
            style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
                color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 0, label: Text(s.t('curtain_off'))),
              ButtonSegment(value: 1, label: Text(s.t('curtain_standard'))),
              ButtonSegment(value: 2, label: Text(s.t('curtain_priority'))),
            ],
            selected: {curtain},
            onSelectionChanged:
                disabled ? null : (set) => onChanged(set.first),
          ),
        ],
      ),
    );
  }
}

/// Single slot tile. Visual state in priority order:
///   1. running   → primary-tinted background, spinner under the label
///   2. last=true → green tint, localized poll code
///   3. last=false → red tint, localized poll code / error message
///   4. otherwise → neutral white card
///
/// `disabledByOthers` darkens the card when another test is mid-flight
/// so the operator doesn't queue up taps the board can't service.
///
/// Twin / wide-spiral slots show every motor id (e.g. "M99+M95") and
/// fire all of them sequentially via [BoardClient.dispenseSlot].
class _SlotCard extends StatelessWidget {
  const _SlotCard({
    required this.slot,
    required this.running,
    required this.disabledByOthers,
    required this.lastResult,
    required this.lastResultText,
    required this.onTap,
  });

  final Slot slot;
  final bool running;
  final bool disabledByOthers;
  final bool? lastResult;
  final String? lastResultText;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color border;
    if (running) {
      bg = const Color(0x1A9C3F00);
      border = AppColors.primary;
    } else if (lastResult == true) {
      bg = const Color(0x1A2E7D32);
      border = const Color(0x4D2E7D32);
    } else if (lastResult == false) {
      bg = const Color(0x1AB3261E);
      border = const Color(0x4DB3261E);
    } else {
      bg = AppColors.surfaceContainerLowest;
      border = AppColors.surfaceContainerHigh;
    }

    final motorsLabel = slot.motorIds.map((m) => 'M$m').join('+');

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border, width: 1.5),
        boxShadow: const [appCardShadow],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: disabledByOthers ? null : onTap,
          child: Opacity(
            opacity: disabledByOthers ? 0.4 : 1.0,
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        slot.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.5,
                          color: AppColors.onSurface,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        motorsLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: AppColors.onSurfaceVariant,
                          letterSpacing: 0.5,
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (running)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppColors.primary),
                        )
                      else if (lastResultText != null)
                        Text(
                          lastResultText!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: lastResult == true
                                ? const Color(0xFF2E7D32)
                                : const Color(0xFFB3261E),
                          ),
                        )
                      else
                        const Icon(
                          Icons.precision_manufacturing,
                          size: 18,
                          color: AppColors.onSurfaceVariant,
                        ),
                    ],
                  ),
                ),
                if (slot.isTwin)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.iosOrange.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'TWIN',
                        style: TextStyle(
                          color: AppColors.iosOrange,
                          fontSize: 8,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.0,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
