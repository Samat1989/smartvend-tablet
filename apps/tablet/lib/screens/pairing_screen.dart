import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/device_storage.dart';
import '../services/strings.dart';
import '../services/supabase_api.dart';
import '../theme.dart';
import '../widgets/lang_chip.dart';
import 'service_pin_screen.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _machidCtrl = TextEditingController();
  final _secretCtrl = TextEditingController();
  final _api = SupabaseApi();
  bool _busy = false;

  /// Kyrgyz cabinet? Off — Kaspi QR and tenge, exactly as before. On — the
  /// gateway is asked for an O!Dengi QR and every price switches to som.
  /// The choice lives on this screen because it is a fact about where the
  /// cabinet stands, settled once when the machine is bound to the tablet.
  bool _odengi = false;

  /// Taps on the logo, for the service-menu gesture below.
  final List<DateTime> _serviceTaps = [];

  /// Way into the service menu from an unpaired tablet.
  ///
  /// The storefront has this gesture on the shelf rail, and for a working
  /// machine that is enough. It is not enough here: a tablet that has been
  /// granted device owner but not yet bound to a machine never reaches the
  /// storefront, and lock task will not let anything else take the screen.
  /// Without an entry point on this screen such a tablet is sealed — no
  /// settings, no wireless debugging, no way back in short of a factory
  /// reset. Which is exactly what happened to the first one provisioned in
  /// the field.
  ///
  /// Same 10-taps-in-5-seconds as the storefront, and the same PIN behind
  /// it, so nothing is weakened: a customer cannot reach this screen at all,
  /// and an installer already knows the gesture.
  void _onServiceTap() {
    final now = DateTime.now();
    _serviceTaps
      ..add(now)
      ..removeWhere((t) => now.difference(t) > const Duration(seconds: 5));
    if (_serviceTaps.length >= 10) {
      _serviceTaps.clear();
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ServicePinScreen()),
      );
    }
  }
  String? _error;

  @override
  void dispose() {
    _machidCtrl.dispose();
    _secretCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final machid = _machidCtrl.text.trim();
    final secret = _secretCtrl.text.trim();
    if (machid.isEmpty || secret.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await _api.verifyPairing(machid, secret);
    if (!mounted) return;
    if (err != null) {
      // The API layer returns Strings keys, never prose — see verifyPairing.
      final text = context.read<Strings>().t(err);
      setState(() {
        _busy = false;
        _error = text;
      });
      return;
    }
    // Secret checks out — now take the machine for this tablet. Done before
    // savePairing so a refusal leaves the tablet unpaired instead of half
    // set up on a cabinet that belongs to someone else's tablet.
    final storage = context.read<DeviceStorage>();
    final deviceId = await storage.deviceId();
    // If the owner unbound THIS tablet from the panel, verify_pairing above
    // has already lifted the block — someone typing both credentials is the
    // deliberate opposite decision. Nothing to do here.
    final claim = await _api.claimMachine(
      machid: machid,
      secret: secret,
      deviceId: deviceId,
    );
    if (!mounted) return;
    if (!claim.ok) {
      final text = context.read<Strings>().t(claim.message!);
      setState(() {
        _busy = false;
        _error = text;
      });
      return;
    }
    await storage.savePairing(
      machid: machid,
      secret: secret,
      terNumber: _odengi ? DeviceStorage.terNumberOdengi : '',
    );
    // main.dart watches DeviceStorage and will swap to HomeScreen automatically.
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    // Why the tablet is standing here rather than showing the storefront,
    // when it was not a person who unpaired it. See DeviceStorage.unpairNotice.
    final notice = context.watch<DeviceStorage>().unpairNotice;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: const [appCardShadow],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Align(
                        alignment: Alignment.topRight,
                        child: LangChip(),
                      ),
                      const SizedBox(height: 8),
                      // The brand emblem rather than a stock cash-register
                      // glyph. No gradient disc behind it: the mark is blue
                      // and orange on transparent, and the blue half sank
                      // into the gradient.
                      //
                      // Still the door into service mode — ten taps here
                      // inside five seconds (_onServiceTap). Kept opaque and
                      // padded to 88 px total so the target stays
                      // finger-sized and the column keeps its old rhythm,
                      // even though the mark is wider than it is tall.
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _onServiceTap,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Image.asset(
                            'lib/static/micromart_emblem.png',
                            height: 64,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        s.t('pairing_title').toUpperCase(),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                            color: AppColors.onSurface),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        s.t('pairing_subtitle'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.onSurfaceVariant,
                            height: 1.4),
                      ),
                      if (notice != null) ...[
                        const SizedBox(height: 20),
                        _UnpairNotice(
                          text: s.t(notice),
                          onDismiss: () =>
                              context.read<DeviceStorage>().dismissUnpairNotice(),
                        ),
                      ],
                      const SizedBox(height: 28),
                      TextField(
                        controller: _machidCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: InputDecoration(
                          labelText: s.t('machid_label'),
                          prefixIcon: const Icon(Icons.numbers,
                              color: AppColors.onSurfaceVariant),
                          fillColor: AppColors.surfaceContainerLow,
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _secretCtrl,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: s.t('secret_label'),
                          prefixIcon: const Icon(Icons.key,
                              color: AppColors.onSurfaceVariant),
                          fillColor: AppColors.surfaceContainerLow,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Material(
                        color: AppColors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(12),
                        child: CheckboxListTile(
                          value: _odengi,
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => _odengi = v ?? false),
                          controlAffinity: ListTileControlAffinity.leading,
                          dense: true,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          title: Text(
                            s.t('odengi_label'),
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppColors.onSurface),
                          ),
                          subtitle: Text(
                            s.t('odengi_hint'),
                            style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.onSurfaceVariant),
                          ),
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0x1AB3261E),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline,
                                  color: Color(0xFFB3261E), size: 20),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: const TextStyle(
                                      color: Color(0xFFB3261E),
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Container(
                        decoration: BoxDecoration(
                          gradient: signatureGradient,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x339C3F00),
                              blurRadius: 16,
                              offset: Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(16),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: _busy ? null : _connect,
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 18),
                              child: _busy
                                  ? Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white),
                                        ),
                                        const SizedBox(width: 12),
                                        Text(
                                          s.t('verifying'),
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 14,
                                              letterSpacing: 0.5),
                                        ),
                                      ],
                                    )
                                  : Text(
                                      s.t('connect_btn').toUpperCase(),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 1.2,
                                          color: Colors.white),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}


/// Why the tablet unpaired itself, said once on the pairing screen.
///
/// Amber, not the red of [_PairingScreenState._error]: nothing has failed
/// here. The machine was taken away, on purpose, by someone with a panel —
/// and the installer standing in front of the cabinet needs to be told that
/// before they start hunting for a fault that does not exist.
///
/// Dismissible, because it outlives the moment: the notice is stored, so
/// without a way to put it down it would still be on screen weeks later.
class _UnpairNotice extends StatelessWidget {
  const _UnpairNotice({required this.text, required this.onDismiss});

  final String text;
  final VoidCallback onDismiss;

  static const _amber = Color(0xFF8A5A00);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: const Color(0x1AF59E0B),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.link_off, color: _amber, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: _amber,
                fontSize: 13,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 18, color: _amber),
            visualDensity: VisualDensity.compact,
            tooltip: MaterialLocalizations.of(context).closeButtonLabel,
          ),
        ],
      ),
    );
  }
}
