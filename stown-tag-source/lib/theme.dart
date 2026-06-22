import 'package:flutter/material.dart';

/// STOWN-inspired dark theme: deep navy background with blue accents.
class AppColors {
  static const background = Color(0xFF0B1426);
  static const surface = Color(0xFF142136);
  static const surfaceElevated = Color(0xFF1B2A44);
  static const surfaceDim = Color(0xFF0E1A2E);
  static const primary = Color(0xFF2D8CFF);
  static const primaryLight = Color(0xFF4FA3FF);
  static const primaryGradientEnd = Color(0xFF1565DD);
  static const danger = Color(0xFFE74C5C);
  static const success = Color(0xFF22C55E);
  static const onSurface = Color(0xFFE7ECF4);
  static const onSurfaceMuted = Color(0xFF8FA0BA);
  static const divider = Color(0xFF243450);
  static const txHex = Color(0xFF4FC3F7);
  static const rxHex = Color(0xFF66BB6A);
}

ThemeData buildAppTheme() {
  const base = ColorScheme.dark(
    primary: AppColors.primary,
    onPrimary: Colors.white,
    secondary: AppColors.primaryLight,
    onSecondary: Colors.white,
    surface: AppColors.surface,
    onSurface: AppColors.onSurface,
    error: AppColors.danger,
    onError: Colors.white,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: base,
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.background,
    fontFamily: 'Roboto',
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.onSurface,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: AppColors.onSurface,
        fontSize: 22,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      labelStyle: const TextStyle(color: AppColors.onSurfaceMuted, fontSize: 12),
      floatingLabelStyle: const TextStyle(color: AppColors.primaryLight),
      hintStyle: const TextStyle(color: AppColors.onSurfaceMuted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
      ),
      prefixIconColor: AppColors.primary,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(56),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    iconTheme: const IconThemeData(color: AppColors.primary),
    dividerColor: AppColors.divider,
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: AppColors.surfaceDim,
      selectedItemColor: AppColors.primary,
      unselectedItemColor: AppColors.onSurfaceMuted,
      type: BottomNavigationBarType.fixed,
      elevation: 0,
      showUnselectedLabels: true,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.surfaceElevated,
      contentTextStyle: TextStyle(color: AppColors.onSurface),
    ),
  );
}

/// Common gradient used in primary buttons / accents (left→right blue).
const primaryGradient = LinearGradient(
  begin: Alignment.centerLeft,
  end: Alignment.centerRight,
  colors: [AppColors.primary, AppColors.primaryGradientEnd],
);
