import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/strings.dart';
import 'support_corner.dart';

/// Compact language control: shows the current language, cycles on tap.
///
/// Shared by the storefront and the pairing screen. The pairing screen used
/// to carry a four-segment `SegmentedButton` instead — a different control
/// for the same job, twice the width, and one more thing to restyle whenever
/// the other changes.
class LangChip extends StatelessWidget {
  const LangChip({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    // Cycles through whatever this cabinet offers — a Kyrgyz machine steps
    // KG → EN → RU, a Kazakh one KZ → EN → RU. indexOf returns -1 for a
    // language that is not on the list, which lands the next tap on the
    // first entry: the right place to end up.
    final cycle = s.languages;
    final next = cycle[(cycle.indexOf(s.lang) + 1) % cycle.length];
    final display = Strings.label(s.lang);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => s.setLang(next),
      child: SizedBox(
        // Same height as the support button it stacks with on the storefront,
        // so the two read as one column and the tap target stays
        // finger-sized. The pairing screen inherits the same target.
        height: SupportCorner.height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.language,
                  size: 1, color: Color.fromARGB(255, 175, 188, 197)),
              const SizedBox(width: 1),
              Text(
                display,
                style: const TextStyle(
                  color: Color.fromARGB(255, 139, 151, 161),
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
