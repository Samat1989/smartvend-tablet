import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/device_storage.dart';
import '../services/strings.dart';
import '../services/vending_service.dart';

/// Service-mode settings that only affect what the customer sees on the
/// catalog. Everything here is local to this tablet — nothing is pushed to
/// the cloud, so two machines of the same owner can be numbered
/// differently if their cabinets are.
class StorefrontSettingsScreen extends StatelessWidget {
  const StorefrontSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final storage = context.watch<DeviceStorage>();
    final layout = context.watch<VendingService>().layout;

    // Sample straight from this machine's layout, so the operator sees the
    // actual numbering (1…55, 001…056, Р2·К3 — whatever the template gave)
    // rather than a made-up example.
    String? sample;
    for (final sh in layout.shelves) {
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
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: Colors.white10,
              child: SwitchListTile(
                value: storage.showSlotNumber,
                onChanged: (v) => storage.setShowSlotNumber(v),
                title: Text(
                  s.t('storefront_show_slot'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    s.t('storefront_show_slot_hint'),
                    style: const TextStyle(
                        color: Colors.white70, height: 1.35),
                  ),
                ),
              ),
            ),
            if (storage.showSlotNumber)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  sample == null
                      ? s.t('storefront_slot_no_layout')
                      : '${s.t('storefront_slot_sample')} $sample',
                  style: TextStyle(
                    color: sample == null
                        ? Colors.orangeAccent
                        : Colors.white54,
                    fontSize: 13,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
