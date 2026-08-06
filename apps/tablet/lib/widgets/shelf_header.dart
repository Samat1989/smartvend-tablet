import 'package:flutter/material.dart';

import '../theme.dart';

/// Header above a shelf's product grid: a muted numbered square plus the
/// shelf's label ("001 — 006", "Напитки"). Toned down to gray-on-gray so the
/// shelf dividers don't compete with the product cards.
///
/// Lives in its own file so the storefront-settings preview can show the real
/// header rather than a copy that would drift the moment either is edited —
/// same reasoning as [ProductCard].
class ShelfHeader extends StatelessWidget {
  const ShelfHeader({
    super.key,
    required this.shelfNumber,
    required this.label,
  });

  final int shelfNumber;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 25,
          height: 25,
          decoration: BoxDecoration(
            color: AppColors.iosGray.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(
            '$shelfNumber',
            style: const TextStyle(
              color: AppColors.iosGray,
              fontSize: 14,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
              height: 1,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.iosGray,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
