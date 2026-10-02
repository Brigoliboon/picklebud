import 'package:flutter/material.dart';

abstract final class AppColors {
  static const courtGreen = Color(0xFF1E6F46);
  static const courtGreenBright = Color(0xFF35A66E);
  static const surface = Color(0xFF15171B);
  static const surfaceAlt = Color(0xFF1C2027);
  static const border = Color(0xFF292E37);
  static const textPrimary = Color(0xFFF1F3F5);
  static const textSecondary = Color(0xFF939BAA);
  static const accent = Color(0xFFF2B33D);
  static const ok = Color(0xFF4CC38A);
  static const warn = Color(0xFFF2B33D);
  static const danger = Color(0xFFE2564B);
}

abstract final class AppTheme {
  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.courtGreen,
      brightness: Brightness.dark,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.surface,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.surfaceAlt,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      dividerColor: AppColors.border,
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: AppColors.textPrimary),
        bodySmall: TextStyle(color: AppColors.textSecondary),
        titleMedium: TextStyle(color: AppColors.textPrimary),
        titleLarge: TextStyle(color: AppColors.textPrimary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceAlt,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.courtGreenBright),
        ),
        labelStyle: const TextStyle(color: AppColors.textSecondary),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.surfaceAlt,
        contentTextStyle: const TextStyle(color: AppColors.textPrimary),
      ),
    );
  }
}