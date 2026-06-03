import 'package:flutter/material.dart';

import '../theme.dart';

/// Top-right "close / cancel" button shared by the payment and dispense
/// screens. Fixed 44 × 44 dp blue filled circle with a white "×" — same
/// size and styling everywhere so the affordance reads as one
/// consistent control across the post-cart flow.
///
/// Parents are responsible for placement (typically
/// `Positioned(top: 16, right: 16)`) so the button can be a top-layer
/// Stack child regardless of the surrounding layout.
class CloseCircleButton extends StatelessWidget {
  const CloseCircleButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.iosBlue,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: const SizedBox(
          width: 44,
          height: 44,
          child: Icon(Icons.close, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}
