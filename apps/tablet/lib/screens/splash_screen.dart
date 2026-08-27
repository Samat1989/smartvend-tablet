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

  /// Emblem height, chosen so this screen draws the mark at the same size the
  /// OS splash does. Measured at 137 physical px on the fleet's 240 dpi
  /// tablets, hence 137 / 1.5.
  ///
  /// Density-independent despite being a measured number: Flutter's logical
  /// pixels are dp, and Android sizes the splash icon slot in dp too, so both
  /// scale by the same devicePixelRatio and stay matched on any screen. What
  /// would break the match is a ROM that overrides the splash icon dimension
  /// or an Android release that changes it — not a different density.
  static const double emblemHeight = 91;

  /// Gap between the mark and the wordmark below it.
  static const double _gap = 22;

  @override
  Widget build(BuildContext context) {
    // Material, not a plain ColoredBox: MaterialApp.home does not introduce
    // one by itself (Scaffold normally does), and a Text with no Material
    // ancestor falls back to Flutter's unstyled-text style — black glyphs
    // with a yellow underline, which on the tablet read as a stray progress
    // bar sitting under the wordmark.
    // The mark is pinned to the exact centre of the screen — where the OS
    // splash puts it — and the wordmark and bar hang below it, rather than
    // the three being centred as one column. Centring the column would push
    // the mark ~75 px above where the OS had it, and the handover then reads
    // as two separate screens instead of text and a bar appearing under a
    // mark that never moved. The OS splash cannot be switched off (Android
    // 12 made it mandatory), so the next best thing is making it invisible.
    return Material(
      color: Colors.white,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final centreY = constraints.maxHeight / 2;
          return Stack(
            children: [
              Positioned(
                top: centreY - emblemHeight / 2,
                left: 0,
                right: 0,
                child: const Image(
                  image: AssetImage('lib/static/micromart_emblem.png'),
                  height: emblemHeight,
                  fit: BoxFit.contain,
                ),
              ),
              Positioned(
                top: centreY + emblemHeight / 2 + _gap,
                left: 0,
                right: 0,
                child: Column(
                  children: [
                    const Text(
                      'MicroVend',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w600,
                        fontSize: 34,
                        letterSpacing: -0.5,
                        // Sampled from the wordmark in
                        // design/micromart_logo.png so the text sits at the
                        // same weight of grey as the old art.
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
                        valueColor: const AlwaysStoppedAnimation<Color>(
                            AppColors.primary),
                        borderRadius:
                            const BorderRadius.all(Radius.circular(3)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
