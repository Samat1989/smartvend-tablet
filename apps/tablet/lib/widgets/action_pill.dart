import 'package:flutter/material.dart';

import '../theme.dart';

/// Total height the action bar occupies (button + vertical padding).
/// Both home and cart screens use this so the catalog/grid below them
/// can reserve a matching bottom padding.
const double kActionBarHeight = 104;

/// Round back button shared by the home (placeholder no-op) and cart
/// (Navigator.pop) screens. Black 4-dp outline, transparent body, 72-dp
/// diameter — matches the pill height beside it.
class RoundBackButton extends StatelessWidget {
  const RoundBackButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.iosBlack, width: 4),
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: const Icon(
            Icons.arrow_back,
            color: AppColors.iosBlack,
            size: 30,
          ),
        ),
      ),
    );
  }
}

/// Wide pill at the bottom of the catalog / cart. Three visual
/// variants — empty (gray, "пусто"), filled cart (black, "N товара"),
/// and pay (black, "N ₸") — sized identically so the bar height
/// doesn't jump as the user fills the cart or moves between screens.
class ActionPill extends StatelessWidget {
  const ActionPill({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.filled,
    required this.onTap,
  });

  /// Lead icon inside the pill — cart for catalog, QR for pay.
  final IconData icon;

  /// Small uppercase caption above the value, e.g. "В КОРЗИНЕ".
  final String label;

  /// Bold value line, e.g. "пусто", "2 товара", "2 585 ₸".
  final String value;

  /// When false the pill renders in the muted "empty" state.
  final bool filled;

  /// Tap handler. Pass null on the empty state to make the pill
  /// non-interactive (the gray colour already reads as disabled).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bg = filled
        ? AppColors.iosBlack
        : AppColors.iosGray.withValues(alpha: 0.85);
    // Fixed 320-dp width — lets the bottom bar centre back+pill as a
    // group via `Row.mainAxisAlignment: center`, instead of having
    // the pill stretch to whatever space the parent gives it.
    return SizedBox(
      width: 320,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(1000),
          child: InkWell(
            borderRadius: BorderRadius.circular(1000),
            onTap: onTap,
            child: SizedBox(
              height: 60,
              child: Padding(
                padding: const EdgeInsets.only(left: 20, right: 8),
                child: Row(
                  children: [
                    Icon(icon, color: Colors.white, size: 22),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label.toUpperCase(),
                            style: const TextStyle(
                              color: Color(0xCCFFFFFF),
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1.4,
                              height: 1,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.4,
                              height: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 42,
                      height: 42,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.arrow_forward,
                        color: AppColors.iosBlack,
                        size: 28,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
