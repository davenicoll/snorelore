import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppColors {
  static const Color background = Color(0xFF0B1026);
  static const Color surface = Color(0xFF161C3A);
  static const Color surfaceAlt = Color(0xFF1F2649);
  static const Color primary = Color(0xFF8B7AFF);
  static const Color accent = Color(0xFFE4FF30);
  static const Color pink = Color(0xFFFF0087);
  static const Color teal = Color(0xFF48B3AF);
  static const Color orange = Color(0xFFFF9D23);
  static const Color red = Color(0xFFF93827);
  static const Color amber = Color(0xFFFFC857);
  static const Color cyan = Color(0xFF5BE7FF);
  static const Color textMuted = Color(0xFF8B92C9);
}

ThemeData buildTheme() {
  final base = ThemeData(brightness: Brightness.dark);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: const ColorScheme.dark(
      surface: AppColors.surface,
      primary: AppColors.primary,
      secondary: AppColors.accent,
      onPrimary: Colors.black,
      onSurface: Colors.white,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: Colors.white,
        letterSpacing: 0.2,
      ),
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: AppColors.background,
      ),
    ),
    cardTheme: const CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(18)),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: AppColors.primary,
      textColor: Colors.white,
      tileColor: AppColors.surface,
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return AppColors.primary;
        return AppColors.surfaceAlt;
      }),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
    ),
    textTheme: base.textTheme.apply(
      bodyColor: Colors.white,
      displayColor: Colors.white,
    ),
    iconTheme: const IconThemeData(color: AppColors.primary),
    dividerTheme: const DividerThemeData(
      color: AppColors.surfaceAlt,
      thickness: 1,
    ),
  );
}
