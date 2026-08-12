import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/device_storage.dart';
import '../services/strings.dart';
import '../theme.dart';
import '../widgets/close_circle_button.dart';

/// Digits for a `wa.me` link, derived from however the operator typed the
/// number. wa.me wants an international number with no punctuation and no
/// leading `+`.
///
/// The one substitution we make is the Kazakh/Russian trunk prefix: locals
/// write their own number as `8 700 …`, which is how it is dialled inside
/// the country but is not a country code. Left alone it produces a dead
/// wa.me link, so a leading `8` in front of a 10-digit national number
/// becomes `7`. Anything else is passed through untouched — guessing
/// further would break numbers we do not recognise.
String? whatsappDigits(String? raw) {
  if (raw == null) return null;
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) return null;
  if (digits.length == 11 && digits.startsWith('8')) {
    return '7${digits.substring(1)}';
  }
  return digits;
}

/// Customer-facing support page: who to call when a slot ate the money.
///
/// Reached from the corner badge on every customer screen. Deliberately
/// leads with the machine number rather than the phone — the operator on
/// the other end of the line cannot do anything without knowing which
/// cabinet is being complained about, and the number is otherwise only
/// visible as a 10-px grey caption the customer will not think to read.
///
/// The phone is not a `tel:` link on purpose. These tablets run in kiosk
/// mode with no dialler, so a tappable number would do nothing and read as
/// broken; the customer calls from their own phone. The WhatsApp QR exists
/// for the same reason — their phone can scan it, this one cannot dial.
class SupportScreen extends StatelessWidget {
  const SupportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final storage = context.watch<DeviceStorage>();
    final machid = storage.machid;
    final phone = storage.supportPhone;
    final hours = storage.supportHours;
    final wa = whatsappDigits(storage.supportWhatsapp);

    return Scaffold(
      backgroundColor: AppColors.iosBackground,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        s.t('support_title'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppColors.iosBlack,
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        s.t('support_intro'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppColors.iosGray,
                          fontSize: 15,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 22),
                      // Machine number first — see the class comment.
                      if (machid != null)
                        _InfoCard(
                          label: s.t('support_machine'),
                          value: '№$machid',
                          hint: s.t('support_machine_hint'),
                          accent: AppColors.iosOrange,
                        ),
                      if (machid != null && phone != null)
                        const SizedBox(height: 12),
                      if (phone != null)
                        _InfoCard(
                          label: s.t('support_phone_label'),
                          value: phone,
                          accent: AppColors.iosBlue,
                        ),
                      if (hours != null) ...[
                        const SizedBox(height: 12),
                        _InfoCard(
                          label: s.t('support_hours_label'),
                          value: hours,
                          valueSize: 20,
                          accent: AppColors.iosGray,
                        ),
                      ],
                      if (wa != null) ...[
                        const SizedBox(height: 18),
                        _WhatsappBlock(digits: wa, hint: s.t('support_whatsapp_hint')),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: CloseCircleButton(
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One labelled value on a white card. [value] is set large enough to be
/// read — and read aloud down a phone line — from arm's length.
class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.label,
    required this.value,
    required this.accent,
    this.hint,
    this.valueSize = 30,
  });

  final String label;
  final String value;
  final String? hint;
  final Color accent;
  final double valueSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: iosCardShadow,
      ),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: accent,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          // Shrinks rather than wrapping mid-number: a phone broken across
          // two lines is hard to read back correctly.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                color: AppColors.iosBlack,
                fontSize: valueSize,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(
              hint!,
              style: const TextStyle(
                color: AppColors.iosGray,
                fontSize: 12,
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _WhatsappBlock extends StatelessWidget {
  const _WhatsappBlock({required this.digits, required this.hint});

  final String digits;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: iosCardShadow,
      ),
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
      child: Column(
        children: [
          QrImageView(
            data: 'https://wa.me/$digits',
            size: 170,
            backgroundColor: Colors.white,
            eyeStyle: const QrEyeStyle(
              eyeShape: QrEyeShape.square,
              color: AppColors.iosBlack,
            ),
            dataModuleStyle: const QrDataModuleStyle(
              dataModuleShape: QrDataModuleShape.square,
              color: AppColors.iosBlack,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.iosGray,
              fontSize: 13,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}
