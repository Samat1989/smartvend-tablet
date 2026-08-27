import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/strings.dart';
import '../services/vending_service.dart';
import '../theme.dart';

/// Storefront view switch: product photos, or the cell number in their place.
///
/// Two round 44-dp buttons in one white pill. The size and shape are the
/// card's add button and the support corner — a customer has already been
/// taught that a blue-filled circle is the live one — and the pill behind
/// them keeps both legible while cards scroll underneath.
///
/// It sits at the top of the catalog and never scrolls away: a customer who
/// came to find cell 14 should not have to scroll back up to ask for numbers.
class ViewModeToggle extends StatelessWidget {
  const ViewModeToggle({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final svc = context.watch<VendingService>();
    final numbers = svc.numbersView;

    // No layout, no numbers to show: ProductCard reads the label out of
    // MachineLayout, so on a cabinet whose slots were never mapped the
    // right-hand button would flip the state and change nothing on screen.
    // A control that visibly does nothing is worse than no control, so it
    // stays away until the operator has built a layout in «Раскладка
    // слотов».
    //
    // Found on a freshly wiped install: the layout lives in DeviceStorage,
    // not on the server, so it does not arrive with the pairing.
    if (svc.layout.isEmpty) return const SizedBox.shrink();

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ModeButton(
              icon: Icons.image_outlined,
              label: s.t('view_photos'),
              active: !numbers,
              onTap: () => svc.setNumbersView(false),
            ),
            const SizedBox(width: 6),
            _ModeButton(
              icon: Icons.pin_outlined,
              label: s.t('view_numbers'),
              active: numbers,
              onTap: () => svc.setNumbersView(true),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;

  /// Not drawn — the buttons are icon-only by design. Read out by screen
  /// readers and used as the long-press tooltip, so the control is still
  /// nameable without spending the width two labels would cost.
  final String label;

  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        selected: active,
        button: true,
        child: Material(
          color: active ? AppColors.iosBlue : Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                icon,
                size: 24,
                color: active ? Colors.white : AppColors.iosGray,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
