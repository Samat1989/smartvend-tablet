import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/machine_layout.dart';
import '../models/product.dart';
import '../services/device_storage.dart';
import '../services/strings.dart';
import '../services/vending_service.dart';
import '../theme.dart';
import '../widgets/product_card.dart';
import '../widgets/shelf_header.dart';

/// Service-mode settings that only affect what the customer sees on the
/// catalog, with a live preview underneath them. Everything here is local to
/// this tablet — nothing is pushed to the cloud, so two machines of the same
/// owner can be laid out differently if their cabinets are.
///
/// Controls sit in a header strip and the preview gets the full width below.
/// The preview is the point of the screen, and it only tells the truth about
/// card proportions when it's as wide as the catalog it stands for — squeezed
/// into a side column it made cards look narrower than they really are.
///
/// It renders the real [ProductCard] (`interactive: false`), not a look-alike:
/// a mock would drift from the catalog the moment either is touched, and then
/// it would be lying to the operator.
class StorefrontSettingsScreen extends StatelessWidget {
  const StorefrontSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final storage = context.watch<DeviceStorage>();
    final svc = context.watch<VendingService>();

    // Sample straight from this machine's layout, so the operator sees the
    // actual numbering (1…55, 001…056 — whatever the template gave) rather
    // than a made-up example.
    String? sample;
    for (final sh in svc.layout.shelves) {
      if (sh.slots.isNotEmpty) {
        sample = sh.slots.first.label;
        break;
      }
    }

    return Scaffold(
      backgroundColor: Colors.grey.shade900,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(s.t('service_storefront'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ─── Settings header ───
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Columns
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.t('storefront_columns'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SegmentedButton<int>(
                          segments: [
                            for (var n = DeviceStorage.minGridColumns;
                                n <= DeviceStorage.maxGridColumns;
                                n++)
                              ButtonSegment(value: n, label: Text('$n')),
                          ],
                          selected: {storage.gridColumns},
                          showSelectedIcon: false,
                          onSelectionChanged: (v) =>
                              storage.setGridColumns(v.first),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    flex: 3,
                    child: _SwitchBlock(
                      value: storage.showSlotNumber,
                      onChanged: storage.setShowSlotNumber,
                      title: s.t('storefront_show_slot'),
                      hint: s.t('storefront_show_slot_hint'),
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    flex: 3,
                    child: _SwitchBlock(
                      value: storage.showShelfLabels,
                      onChanged: storage.setShowShelfLabels,
                      title: s.t('storefront_show_shelves'),
                      hint: s.t('storefront_show_shelves_hint'),
                    ),
                  ),
                ],
              ),
            ),
            // Both toggles read their text out of the machine layout, so
            // without one there is nothing to show and the switches would
            // look broken.
            if ((storage.showSlotNumber || storage.showShelfLabels) &&
                sample == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Text(
                  s.t('storefront_slot_no_layout'),
                  style: const TextStyle(
                      color: Colors.orangeAccent, fontSize: 12),
                ),
              ),
            const Divider(height: 1, color: Colors.white24),
            // ─── Live preview, full width ───
            Expanded(
              child: _Preview(
                products: svc.catalog,
                // Real first shelf of this machine, so the header in the
                // preview carries the same numbering the catalog will.
                shelf: svc.layout.shelves.isEmpty
                    ? null
                    : svc.layout.shelves.first,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One labelled toggle in the settings header: switch, title, explanation.
class _SwitchBlock extends StatelessWidget {
  const _SwitchBlock({
    required this.value,
    required this.onChanged,
    required this.title,
    required this.hint,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Switch(value: value, onChanged: onChanged),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          hint,
          style: const TextStyle(
              color: Colors.white54, fontSize: 12, height: 1.3),
        ),
      ],
    );
  }
}

/// Slice of the catalog at the operator's current settings. Shows the first
/// few products the machine actually carries; falls back to a message when
/// the catalog hasn't loaded, so the column count can still be judged.
class _Preview extends StatelessWidget {
  const _Preview({required this.products, required this.shelf});

  final List<Product> products;

  /// First shelf of the machine layout, or null when no layout is set —
  /// then there is no header to preview.
  final Shelf? shelf;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final storage = context.watch<DeviceStorage>();
    final cols = storage.gridColumns;
    // Three rows' worth; the grid scrolls if they don't all fit.
    final shown = products.take(cols * 3).toList();

    return Container(
      color: AppColors.iosBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Text(
              s.t('storefront_preview'),
              style: const TextStyle(
                color: AppColors.iosGray,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ),
          // The real ShelfHeader, same widget the catalog uses.
          if (storage.showShelfLabels && shelf != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: ShelfHeader(shelfNumber: 1, label: shelf!.label),
            ),
          Expanded(
            child: shown.isEmpty
                ? Center(
                    child: Text(
                      s.t('storefront_preview_empty'),
                      style: const TextStyle(color: AppColors.iosGray),
                    ),
                  )
                : GridView.count(
                    padding: const EdgeInsets.all(16),
                    crossAxisCount: cols,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    // Same ratio the catalog uses, so what the operator sees
                    // here is the proportion they'll get.
                    childAspectRatio: 0.895,
                    children: [
                      for (final p in shown)
                        ProductCard(product: p, interactive: false),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
