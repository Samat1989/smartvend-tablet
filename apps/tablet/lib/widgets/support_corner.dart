import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/support_screen.dart';
import '../services/device_storage.dart';
import '../services/strings.dart';
import '../theme.dart';

/// Corner badge: the machine number, and — once the operator has filled in
/// a support contact in service mode — the way into [SupportScreen].
///
/// Lives on every customer-facing screen rather than just the catalog. The
/// moment a customer needs support is the moment a slot failed to drop or a
/// QR expired, and by then they are on the dispense or payment screen, not
/// browsing the shelf.
///
/// Two states, deliberately the same height so nothing stacked below shifts
/// when an operator fills the contact in:
///   * no contact configured — the plain grey machine number this corner
///     has always shown, inert;
///   * contact configured — the same number with a support glyph, tappable.
///
/// A «Помощь» button that opens an empty page is worse than no button, so
/// the tappable state is gated on [DeviceStorage.hasSupportInfo].
///
/// Placement is the parent's job, same as [CloseCircleButton] — the catalog
/// lays it out in its header strip, while the post-cart screens pin it
/// top-left because the close button already owns the right corner there.
class SupportCorner extends StatelessWidget {
  const SupportCorner({super.key});

  /// Height of the tap target. Kiosk tablets are used standing up, at
  /// arm's length — 44 dp is the floor, not a comfortable size. Also the
  /// height the catalog's language chip matches so the two line up.
  static const double height = 44;

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<DeviceStorage>();
    final machid = storage.machid;
    if (machid == null) return const SizedBox.shrink();

    final s = context.watch<Strings>();
    final label = '№$machid';

    if (!storage.hasSupportInfo) {
      return SizedBox(
        height: height,
        child: Align(
          // Centred, not top-pinned: this now sits inline in the catalog's
          // header strip next to the language chip rather than floating in
          // the corner on its own.
          alignment: Alignment.center,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
                color: Color.fromARGB(255, 162, 162, 175),
              ),
            ),
          ),
        ),
      );
    }

    return Semantics(
      button: true,
      label: s.t('support'),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(height / 2),
        child: InkWell(
          borderRadius: BorderRadius.circular(height / 2),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SupportScreen()),
          ),
          child: SizedBox(
            height: height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.support_agent,
                    size: 20,
                    color: AppColors.iosBlue,
                  ),
                  const SizedBox(width: 6),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.t('support'),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: AppColors.iosBlue,
                          height: 1.1,
                        ),
                      ),
                      Text(
                        label,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                          color: AppColors.iosGray,
                          height: 1.2,
                        ),
                      ),
                    ],
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
