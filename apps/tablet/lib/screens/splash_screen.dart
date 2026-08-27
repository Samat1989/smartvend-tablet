import 'package:flutter/material.dart';

import '../theme.dart';

/// Brand moment between the OS splash and the app: mark, wordmark, progress.
///
/// The native splash can only carry the mark. Android 12+ hands its image to
/// `windowSplashScreenAnimatedIcon`, which scales whatever it gets into a
/// square icon slot and guarantees nothing outside a 768 px circle — the old
/// full-page composition arrived on the tablets visibly squashed. So the
/// native side shows the mark alone, and everything else is drawn here, as
/// widgets: sharp at any density, and changed by editing code rather than
/// re-cutting a PNG.
///
/// Visually continuous with the native splash — same white, same mark, same
/// size — so the handover reads as one screen rather than two.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key, required this.progress});

  /// 0..1, driven by the caller. Note this tracks the splash's own hold, not
  /// real loading: DeviceStorage.init() finishes before runApp() and there is
  /// nothing left to wait on. It is a paced reveal, not a lie about work —
  /// if a genuine async startup step ever appears, feed its completion here.
  final double progress;

  /// Emblem height in logical pixels. At the tablets' 1.5x density this lands
  /// within a few pixels of what the OS splash renders, so the mark does not
  /// jump when one screen replaces the other.
  static const double emblemHeight = 96;

  @override
  Widget build(BuildContext context) {
    // Material, not a plain ColoredBox: MaterialApp.home does not introduce
    // one by itself (Scaffold normally does), and a Text with no Material
    // ancestor falls back to Flutter's unstyled-text style — black glyphs
    // with a yellow underline, which on the tablet read as a stray progress
    // bar sitting under the wordmark.
    return Material(
      color: Colors.white,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Image(
              image: AssetImage('lib/static/micromart_emblem.png'),
              height: emblemHeight,
              fit: BoxFit.contain,
            ),
            const SizedBox(height: 18),
            const Text(
              'MicroVend',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w600,
                fontSize: 34,
                letterSpacing: -0.5,
                // Sampled from the wordmark in design/micromart_logo.png so
                // the text sits at the same weight of grey as the old art.
                color: Color(0xFF383838),
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: 200,
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 5,
                backgroundColor: const Color(0xFFE4E4E4),
                valueColor:
                    const AlwaysStoppedAnimation<Color>(AppColors.primary),
                borderRadius: const BorderRadius.all(Radius.circular(3)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
