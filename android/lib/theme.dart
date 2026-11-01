import 'package:flutter/material.dart';

/// Цвета приложения: два режима — светлый и тёмный.
///
/// Всё оформление берёт цвета отсюда, поэтому переключение темы меняет
/// сразу весь интерфейс. Стиль — минимализм: белый или чёрный фон,
/// тонкие линии и крупные цифры.
class AppColors {
  /// true — тёмная тема, false — светлая.
  static bool isDark = false;

  static Color get background =>
      isDark ? const Color(0xFF0B0B0B) : const Color(0xFFFFFFFF);

  /// Фон карточек.
  static Color get surface =>
      isDark ? const Color(0xFF141414) : const Color(0xFFFFFFFF);

  /// Фон вложенных блоков (внутри карточки).
  static Color get nested =>
      isDark ? const Color(0xFF1B1B1B) : const Color(0xFFF7F7F7);

  static Color get border =>
      isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE8E8E8);

  /// Цвет главных линий и кнопок.
  static Color get accent =>
      isDark ? const Color(0xFFF2F2F2) : const Color(0xFF0A0A0A);

  /// Текст на акцентном фоне.
  static Color get onAccent =>
      isDark ? const Color(0xFF0B0B0B) : const Color(0xFFFFFFFF);

  static Color get text =>
      isDark ? const Color(0xFFF2F2F2) : const Color(0xFF0A0A0A);

  static Color get muted => const Color(0xFF8A8A8A);

  /// Предупреждения: оранжевый в светлой теме, тёплый жёлтый в тёмной.
  static Color get warning =>
      isDark ? const Color(0xFFFFC46B) : const Color(0xFF9A5B00);

  static Color get dangerBackground =>
      isDark ? const Color(0x33E5484D) : const Color(0xFFF4E7E7);

  static Color get dangerText =>
      isDark ? const Color(0xFFFF9A9C) : const Color(0xFF8C1D20);
}

/// Готовые текстовые стили, чтобы все экраны выглядели одинаково.
class AppText {
  /// Крупная цифра на главном экране.
  static TextStyle get hero => TextStyle(
        fontSize: 76,
        fontWeight: FontWeight.w300,
        letterSpacing: -3,
        height: 0.95,
        color: AppColors.text,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// Заголовок экрана или карточки.
  static TextStyle get title => TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
        color: AppColors.text,
      );

  /// Мелкая подпись над крупной цифрой.
  static TextStyle get label => TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.4,
        color: AppColors.muted,
      );

  /// Обычный текст.
  static TextStyle get body => TextStyle(fontSize: 14, color: AppColors.text);

  /// Второстепенный текст.
  static TextStyle get note => TextStyle(fontSize: 12, color: AppColors.muted);

  /// Значение параметра в строке.
  static TextStyle get value => TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: AppColors.text,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}

/// Собирает оформление Material для текущего режима.
ThemeData buildAppTheme() {
  final ThemeData base = AppColors.isDark ? ThemeData.dark() : ThemeData.light();

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.accent,
      secondary: AppColors.accent,
      surface: AppColors.surface,
      onSurface: AppColors.text,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        color: AppColors.text,
      ),
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
    ),
    dividerColor: AppColors.border,
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.onAccent,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text,
        side: BorderSide(color: AppColors.border),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AppColors.muted),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      labelStyle: AppText.note,
      hintStyle: AppText.note,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppColors.accent),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.accent,
      contentTextStyle: TextStyle(color: AppColors.onAccent),
    ),
  );
}
