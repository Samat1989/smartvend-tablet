import 'package:flutter/material.dart';

/// Square action tile used by the service-mode grids.
///
/// Lives here rather than inside one screen because service mode is now two
/// grids — the machine itself and [SystemSettingsScreen] — and both need to
/// look identical. An operator who learns one grid should not have to learn
/// the other.
class ServiceTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  /// Причина, по которой плитка неактивна. Null — плитка работает.
  ///
  /// Выключаем, а не прячем: у пропавшей плитки нет объяснения, и техник на
  /// точке будет искать её в обновлении или в другой прошивке. Серая плитка с
  /// подписью «нет моторов на этой плате» отвечает на вопрос сразу.
  final String? disabledReason;

  const ServiceTile({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.disabledReason,
  });

  @override
  Widget build(BuildContext context) {
    final off = disabledReason != null;
    final tint = off ? Colors.grey : color;
    return Material(
      color: tint.withValues(alpha: off ? 0.08 : 0.15),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: off ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: off ? Colors.white24 : color, size: 36),
              const SizedBox(height: 12),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: off ? Colors.white38 : Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600),
              ),
              if (off) ...[
                const SizedBox(height: 4),
                Text(
                  disabledReason!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white24, fontSize: 11),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
