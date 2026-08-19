import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/support_screen.dart';
import '../services/device_storage.dart';
import '../services/strings.dart';
import '../theme.dart';

/// Round, icon-only button into [SupportScreen].
///
/// Renders nothing until the operator has filled in a support contact in
/// service mode: a support button that opens an empty page is worse than no
/// button, so the whole widget is gated on [DeviceStorage.hasSupportInfo].
///
/// The machine number used to sit here, first alone and later next to the
/// glyph. It is gone from the storefront entirely — [SupportScreen] shows it
/// under «Номер аппарата», which is the screen a customer is on when they
/// actually need to read it out.
///
/// Placement is the parent's job, same as [CloseCircleButton]: bottom-RIGHT
/// on every screen, inset to match the action bar's own right padding. The
/// action bars centre their content, so the bottom-right corner is free on
/// every screen that has one.
class SupportCorner extends StatelessWidget {
  const SupportCorner({super.key});

  /// Diameter of the button.
  ///
  /// NOTE: 26 dp is well under the 44 dp that kiosk tablets used at arm's
  /// length really want. Kept because the compact corner was asked for; if
  /// customers start missing it, grow this before anything else.
  static const double height = 26;

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<DeviceStorage>();
    if (storage.machid == null || !storage.hasSupportInfo) {
      return const SizedBox.shrink();
    }

    final s = context.watch<Strings>();
    return Semantics(
      button: true,
      // No visible caption, so the label carries the whole meaning here —
      // without it assistive tech would announce a bare glyph.
      label: s.t('support'),
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SupportScreen()),
          ),
          child: const SizedBox(
            width: height,
            height: height,
            child: Center(
              child: Icon(
                Icons.support_agent,
                size: 18,
                color: AppColors.iosBlue,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
