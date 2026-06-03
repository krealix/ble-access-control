import 'package:flutter/material.dart';

// Палитра STOWN (как в десктопном приложении ble_app.py).
const kBg = Color(0xFF0B1426);
const kSurface = Color(0xFF142136);
const kSurfaceHi = Color(0xFF1B2A44);
const kPrimary = Color(0xFF2D8CFF);
const kPrimaryHover = Color(0xFF1565DD);
const kDanger = Color(0xFFE74C5C);
const kSuccess = Color(0xFF22C55E);
const kWarning = Color(0xFFFFB74D);
const kOnSurface = Color(0xFFE7ECF4);
const kMuted = Color(0xFF8FA0BA);
const kDivider = Color(0xFF243450);

ThemeData buildDarkTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: kBg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: kPrimary,
      brightness: Brightness.dark,
    ).copyWith(
      primary: kPrimary,
      surface: kSurface,
      onSurface: kOnSurface,
      error: kDanger,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: kSurface,
      foregroundColor: kOnSurface,
      elevation: 0,
      centerTitle: false,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: kOnSurface,
      displayColor: kOnSurface,
    ),
    iconTheme: const IconThemeData(color: kOnSurface),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: kBg,
      labelStyle: TextStyle(color: kMuted),
      hintStyle: TextStyle(color: kMuted),
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: kDivider),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: kPrimary, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kPrimary,
        foregroundColor: Colors.white,
        disabledBackgroundColor: kSurfaceHi,
        disabledForegroundColor: kMuted,
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}
