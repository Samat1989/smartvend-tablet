import 'package:flutter/material.dart';

/// "Kinetic Gourmet" palette — ported 1-to-1 from
/// `c:\micromarket\customer_web\src\index.css` so the vending kiosk and
/// the customer-web product feel like the same brand.
class AppColors {
  static const primary = Color(0xFF9C3F00);
  static const primaryDim = Color(0xFF893600);
  static const primaryContainer = Color(0xFFFF7A2F);
  static const onPrimary = Color(0xFFFFF0EA);
  static const onPrimaryFixedVariant = Color(0xFF4F1C00);

  static const secondary = Color(0xFF904800);
  static const secondaryContainer = Color(0xFFFFC69F);

  static const tertiary = Color(0xFF7A5400);
  static const tertiaryContainer = Color(0xFFFBB423);

  /// Slightly tinted off-white. Same value for background and surface — the
  /// design separates layers with shadow + container colors, not background
  /// changes.
  static const background = Color(0xFFFAF5FB);
  static const surface = Color(0xFFFAF5FB);
  static const surfaceVariant = Color(0xFFE0DBE3);
  static const onSurface = Color(0xFF2F2E32);
  static const onSurfaceVariant = Color(0xFF5D5B5F);

  /// Pure white — used for product cards, modal sheets, anything that
  /// wants to "lift" off the background.
  static const surfaceContainerLowest = Color(0xFFFFFFFF);
  static const surfaceContainerLow = Color(0xFFF4EFF5);
  static const surfaceContainer = Color(0xFFEBE7ED);
  static const surfaceContainerHigh = Color(0xFFE5E1E8);
  static const surfaceContainerHighest = Color(0xFFE0DBE3);

  static const outline = Color(0xFF78767B);
  static const outlineVariant = Color(0xFFAFACB1);

  /// Kaspi-red — used only on the primary "Pay" CTA so the brand is
  /// instantly recognisable to KZ customers.
  static const kaspi = Color(0xFFF14635);
}

/// The card shadow used everywhere in customer_web — soft, large, low
/// opacity. Looks premium without competing with Material elevation.
const appCardShadow = BoxShadow(
  color: Color(0x0F2F2E32), // 6 % of #2F2E32
  blurRadius: 24,
  offset: Offset(0, 8),
);

/// Brand gradient driven by the two primary tokens — used on the
/// floating cart bar, success modal, etc.
const signatureGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [AppColors.primary, AppColors.primaryContainer],
);

/// Build an app-wide [ThemeData] from the palette above.
ThemeData buildAppTheme() {
  final scheme = ColorScheme(
    brightness: Brightness.light,
    primary: AppColors.primary,
    onPrimary: AppColors.onPrimary,
    primaryContainer: AppColors.primaryContainer,
    onPrimaryContainer: AppColors.onPrimaryFixedVariant,
    secondary: AppColors.secondary,
    onSecondary: AppColors.onPrimary,
    secondaryContainer: AppColors.secondaryContainer,
    onSecondaryContainer: AppColors.onSurface,
    tertiary: AppColors.tertiary,
    onTertiary: AppColors.onPrimary,
    tertiaryContainer: AppColors.tertiaryContainer,
    onTertiaryContainer: AppColors.onSurface,
    error: Color(0xFFB3261E),
    onError: Colors.white,
    surface: AppColors.surface,
    onSurface: AppColors.onSurface,
    surfaceContainerLowest: AppColors.surfaceContainerLowest,
    surfaceContainerLow: AppColors.surfaceContainerLow,
    surfaceContainer: AppColors.surfaceContainer,
    surfaceContainerHigh: AppColors.surfaceContainerHigh,
    surfaceContainerHighest: AppColors.surfaceContainerHighest,
    onSurfaceVariant: AppColors.onSurfaceVariant,
    outline: AppColors.outline,
    outlineVariant: AppColors.outlineVariant,
  );

  // Tight letter-spacing mimics the Lexend "headline" feel of customer_web
  // (`letter-spacing: -0.04em` in their CSS) without bundling a custom
  // font asset. Inter / Roboto rendered slightly tighter looks close
  // enough on Android, and saves us a runtime font download.
  TextStyle headline(double size, FontWeight w) => TextStyle(
        fontSize: size,
        fontWeight: w,
        letterSpacing: size > 24 ? -1.5 : -0.5,
        color: AppColors.onSurface,
      );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    cardColor: AppColors.surfaceContainerLowest,
    textTheme: TextTheme(
      displayLarge: headline(48, FontWeight.w900),
      displayMedium: headline(36, FontWeight.w900),
      displaySmall: headline(32, FontWeight.w900),
      headlineLarge: headline(28, FontWeight.w800),
      headlineMedium: headline(24, FontWeight.w800),
      headlineSmall: headline(20, FontWeight.bold),
      titleLarge: headline(18, FontWeight.bold),
      titleMedium: headline(16, FontWeight.w600),
      titleSmall: headline(14, FontWeight.w600),
      bodyLarge: const TextStyle(fontSize: 16, color: AppColors.onSurface),
      bodyMedium: const TextStyle(fontSize: 14, color: AppColors.onSurface),
      bodySmall:
          const TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
      labelLarge:
          const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 0.5),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceContainerLowest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.primary, width: 2),
      ),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      isDense: true,
    ),
    cardTheme: CardThemeData(
      color: AppColors.surfaceContainerLowest,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      margin: EdgeInsets.zero,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.surfaceContainerLowest,
      foregroundColor: AppColors.onSurface,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: AppColors.onSurface,
        fontSize: 18,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.5,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(
            fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 0.5),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14)),
        side: const BorderSide(color: AppColors.outlineVariant),
        textStyle: const TextStyle(
            fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.3),
      ),
    ),
  );
}
