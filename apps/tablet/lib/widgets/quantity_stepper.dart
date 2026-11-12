import 'package:flutter/material.dart';

import '../theme.dart';

/// «−  3  +» в нижней строке выбранной карточки. Кнопки светлые, чтобы
/// на экране не множились синие и красные кружки; число по центру.
/// Тап вне кнопок попадает в саму карточку и добавляет единицу.
class QuantityStepper extends StatelessWidget {
  const QuantityStepper({
    super.key,
    required this.count,
    required this.canAdd,
    required this.onRemove,
    required this.onAdd,
  });

  final int count;
  final bool canAdd;
  final VoidCallback onRemove;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StepButton(
            icon: Icons.remove,
            onTap: onRemove,
            // Приглушённые красный и синий: различаются с первого взгляда,
            // но не кричат на фоне фото.
            background: const Color(0xFFF3DCDA),
            foreground: const Color(0xFFB0524C),
          ),
        ),
        SizedBox(
          width: 52,
          child: Center(
            child: Text(
              '$count',
              style: const TextStyle(
                color: AppColors.iosBlack,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
          ),
        ),
        Expanded(
          child: _StepButton(
            icon: Icons.add,
            onTap: canAdd ? onAdd : null,
            background: const Color(0xFFD9E7F7),
            foreground: const Color(0xFF3B79B8),
          ),
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.onTap,
    required this.background,
    required this.foreground,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: enabled ? background : AppColors.iosBackground,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(
          height: double.infinity,
          child: Icon(
            icon,
            size: 26,
            color: enabled ? foreground : AppColors.iosGray,
          ),
        ),
      ),
    );
  }
}
