import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../board/board_client.dart';
import '../models/motor_layout.dart';
import '../services/strings.dart';
import '../theme.dart';

/// Operator-facing motor tester.
///
/// 6×6 grid of all physical slots (labels 001..056 → motor ids 99..44).
/// One tap runs a full RUN-then-POLL cycle on that motor with the
/// currently-selected curtain mode and shows the result inline on the
/// card. The card briefly highlights green/red/orange while a result
/// is held, then returns to neutral.
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

  /// Currently-running motor id, or null when idle. Used to disable
  /// other cards while a test is in flight (board can only run one
  /// motor at a time).
  int? _runningMotorId;

  /// Last result per motor id, used to colour the cards after a test.
  /// `null` = never tested, `true` = success, `false` = error.
  final Map<int, bool> _results = {};

  /// Optional human label for the result (e.g. localized poll code).
  final Map<int, String> _resultText = {};

  Future<void> _runTest(int motorId) async {
    if (_runningMotorId != null) return;
    final s = context.read<Strings>();
    final board = context.read<BoardClient>();
    if (!board.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(s.t('board_not_found')),
        backgroundColor: const Color(0xFFB3261E),
      ));
      return;
    }
    setState(() => _runningMotorId = motorId);
    final r = await board.dispense(
      motorId,
      type: 2, // physical machine is all 2-wire; matches motor_layout doc
      curtain: _curtain,
    );
    if (!mounted) return;
    final code = r.finalStatus?.result;
    setState(() {
      _runningMotorId = null;
      _results[motorId] = r.success;
      _resultText[motorId] =
          code != null ? s.pollResult(code) : (r.success ? 'OK' : r.message);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
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
            disabled: _runningMotorId != null,
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
            child: GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: MotorLayout.cols, // 6 — matches physical layout
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 0.85,
              ),
              itemCount: MotorLayout.totalMotors,
              itemBuilder: (_, i) {
                final motorId = MotorLayout.allMotors().toList()[i];
                final shelf = MotorLayout.motorToLabel(motorId);
                final running = _runningMotorId == motorId;
                final result = _results[motorId];
                final resultText = _resultText[motorId];
                return _MotorCard(
                  shelf: shelf,
                  motorId: motorId,
                  running: running,
                  disabledByOthers:
                      _runningMotorId != null && !running,
                  lastResult: result,
                  lastResultText: resultText,
                  onTap: () => _runTest(motorId),
                );
              },
            ),
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

/// Single motor tile. Visual state in priority order:
///   1. running   → primary-tinted background, spinner under the label
///   2. last=true → green tint, localized poll code
///   3. last=false → red tint, localized poll code / error message
///   4. otherwise → neutral white card
///
/// `disabledByOthers` darkens the card when another test is mid-flight
/// so the operator doesn't queue up taps the board can't service.
class _MotorCard extends StatelessWidget {
  const _MotorCard({
    required this.shelf,
    required this.motorId,
    required this.running,
    required this.disabledByOthers,
    required this.lastResult,
    required this.lastResultText,
    required this.onTap,
  });

  final String shelf;
  final int motorId;
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
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    shelf,
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
                    'M$motorId',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppColors.onSurfaceVariant,
                      letterSpacing: 0.5,
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
          ),
        ),
      ),
    );
  }
}
