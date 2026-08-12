import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/device_storage.dart';
import '../services/strings.dart';
import 'support_screen.dart';

/// Service-mode editor for the customer support contact shown by
/// [SupportScreen].
///
/// Local to this tablet, like the rest of the service-mode settings. That
/// is deliberate: the contact has to be readable when the machine is
/// offline, which is exactly when a customer is most likely standing there
/// with a failed dispense and nothing to show for their money.
class SupportSettingsScreen extends StatefulWidget {
  const SupportSettingsScreen({super.key});

  @override
  State<SupportSettingsScreen> createState() => _SupportSettingsScreenState();
}

class _SupportSettingsScreenState extends State<SupportSettingsScreen> {
  late final TextEditingController _phone;
  late final TextEditingController _whatsapp;
  late final TextEditingController _hours;

  @override
  void initState() {
    super.initState();
    final storage = context.read<DeviceStorage>();
    _phone = TextEditingController(text: storage.supportPhone ?? '');
    _hours = TextEditingController(text: storage.supportHours ?? '');
    // Read the raw stored value, not the getter — that one falls back to
    // the phone, and prefilling the box with it would turn "same number"
    // into a second copy the operator then has to keep in sync by hand.
    _whatsapp = TextEditingController(text: storage.rawSupportWhatsapp ?? '');
  }

  @override
  void dispose() {
    _phone.dispose();
    _whatsapp.dispose();
    _hours.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final storage = context.read<DeviceStorage>();
    final s = context.read<Strings>();
    await storage.setSupportPhone(_phone.text);
    await storage.setSupportWhatsapp(_whatsapp.text);
    await storage.setSupportHours(_hours.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s.t('save_ok'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    // Live, so the "preview" button below reflects what is typed only
    // after a save — which is the honest thing to show, since that is what
    // the customer would get.
    final storage = context.watch<DeviceStorage>();

    return Scaffold(
      backgroundColor: Colors.grey.shade900,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          s.t('support_settings_title'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
          children: [
            Text(
              s.t('support_settings_hint'),
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 22),
            _Field(
              controller: _phone,
              label: s.t('support_field_phone'),
              hint: '+7 700 000 00 00',
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 18),
            _Field(
              controller: _whatsapp,
              label: s.t('support_field_whatsapp'),
              hint: '+7 700 000 00 00',
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 18),
            _Field(
              controller: _hours,
              label: s.t('support_field_hours'),
              hint: s.t('support_hours_example'),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: Text(s.t('btn_save')),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
            ),
            const SizedBox(height: 12),
            // Lets the operator check what the customer will actually see
            // without leaving service mode and hunting for the corner chip.
            OutlinedButton.icon(
              onPressed: storage.hasSupportInfo
                  ? () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SupportScreen(),
                        ),
                      )
                  : null,
              icon: const Icon(Icons.visibility),
              label: Text(s.t('storefront_preview')),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white24),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
    this.keyboardType,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white, fontSize: 17),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: Colors.white70),
        hintStyle: const TextStyle(color: Colors.white24),
        filled: true,
        fillColor: Colors.white10,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
