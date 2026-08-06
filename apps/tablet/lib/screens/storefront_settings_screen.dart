import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/product.dart';
import '../services/device_storage.dart';
import '../services/strings.dart';
import '../services/vending_service.dart';
import '../theme.dart';
import '../widgets/product_card.dart';

/// Service-mode settings that only affect what the customer sees on the
/// catalog, with a live preview beside them. Everything here is local to
/// this tablet — nothing is pushed to the cloud, so two machines of the
/// same owner can be laid out differently if their cabinets are.
///
/// The preview renders the real [ProductCard] (`interactive: false`), not a
/// look-alike: a mock would drift from the catalog the moment either is
/// touched, and then it would be lying to the operator.
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
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ─── Settings ───
            SizedBox(
              width: 380,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    s.t('storefront_columns'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    s.t('storefront_columns_hint'),
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 12, height: 1.3),
                  ),
                  const SizedBox(height: 10),
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
                  const SizedBox(height: 24),
                  const Divider(color: Colors.white24),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: storage.showSlotNumber,
                    onChanged: (v) => storage.setShowSlotNumber(v),
                    title: Text(
                      s.t('storefront_show_slot'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        s.t('storefront_show_slot_hint'),
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12, height: 1.3),
                      ),
                    ),
                  ),
                  if (storage.showSlotNumber && sample == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        s.t('storefront_slot_no_layout'),
                        style: const TextStyle(
                            color: Colors.orangeAccent, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
            const VerticalDivider(width: 1, color: Colors.white24),
            // ─── Live preview ───
            Expanded(child: _Preview(products: svc.catalog)),
          ],
        ),
      ),
    );
  }
}

/// Scaled-down slice of the catalog. Shows the first few products the
/// machine actually carries; falls back to placeholders when the catalog
/// hasn't loaded, so the operator can still judge the column count.
class _Preview extends StatelessWidget {
  const _Preview({required this.products});

  final List<Product> products;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final cols = context.watch<DeviceStorage>().gridColumns;
    // Two full rows is enough to read the layout without scrolling.
    final shown = products.take(cols * 2).toList();

    return Container(
      color: AppColors.iosBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
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
                    // Same ratio the catalog uses, so what the operator
                    // sees here is the proportion they'll get.
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
