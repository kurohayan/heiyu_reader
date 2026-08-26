import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'state/app_state.dart';

/// ---------- 主题色选项 ----------
class AccentOption {
  final String keyName;
  final String label;
  final Color dark; // 深色模式的主色
  final Color light; // 浅色模式的主色（略深保证对比度）

  const AccentOption(this.keyName, this.label, this.dark, this.light);
}

const List<AccentOption> kAccentOptions = [
  AccentOption('gold', '羽金', Color(0xFFD9A94B), Color(0xFFB7862A)),
  AccentOption('teal', '青墨', Color(0xFF3FB8A6), Color(0xFF1F8A7A)),
  AccentOption('violet', '绛紫', Color(0xFF9B7EDE), Color(0xFF7B5FC0)),
  AccentOption('rose', '绯羽', Color(0xFFE2718A), Color(0xFFC14E68)),
];

AccentOption get _accent {
  return kAccentOptions.firstWhere(
    (o) => o.keyName == AppState.accentKey.value,
    orElse: () => kAccentOptions.first,
  );
}

bool get _isLight {
  switch (AppState.appThemeMode.value) {
    case AppThemeMode.light:
      return true;
    case AppThemeMode.dark:
      return false;
    case AppThemeMode.system:
      return ui.PlatformDispatcher.instance.platformBrightness ==
          Brightness.light;
  }
}

/// ---------- 动态颜色令牌（页面统一引用） ----------
Color get kAccent => _isLight ? _accent.light : _accent.dark;
Color get kOnAccent =>
    _isLight ? const Color(0xFFFFFFFF) : const Color(0xFF241A06);
Color get kBg =>
    _isLight ? const Color(0xFFF7F6F2) : const Color(0xFF0D1015);
Color get kSurface =>
    _isLight ? const Color(0xFFFFFFFF) : const Color(0xFF131820);
Color get kCard =>
    _isLight ? const Color(0xFFEDEAE3) : const Color(0xFF1A212C);
Color get kSubText =>
    _isLight ? const Color(0xFF6B7280) : const Color(0xFF8B93A1);
Color get kDivider =>
    _isLight ? const Color(0xFFE4E1D8) : const Color(0xFF232B38);

/// ---------- 主题构建 ----------
ThemeData buildAppTheme() => _buildTheme(dark: true);
ThemeData buildLightTheme() => _buildTheme(dark: false);

ThemeData _buildTheme({required bool dark}) {
  final accent = dark ? _accent.dark : _accent.light;
  final onAccent = dark ? const Color(0xFF241A06) : const Color(0xFFFFFFFF);
  final bg =
      dark ? const Color(0xFF0D1015) : const Color(0xFFF7F6F2);
  final surface =
      dark ? const Color(0xFF131820) : const Color(0xFFFFFFFF);
  final card =
      dark ? const Color(0xFF1A212C) : const Color(0xFFEDEAE3);
  final subText =
      dark ? const Color(0xFF8B93A1) : const Color(0xFF6B7280);
  final divider =
      dark ? const Color(0xFF232B38) : const Color(0xFFE4E1D8);
  final onSurface =
      dark ? const Color(0xFFE6E9EE) : const Color(0xFF23272E);
  final cardText =
      dark ? const Color(0xFFDDE2E9) : const Color(0xFF23272E);

  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: dark ? Brightness.dark : Brightness.light,
  ).copyWith(
    primary: accent,
    onPrimary: onAccent,
    surface: bg,
    onSurface: onSurface,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: dark ? Brightness.dark : Brightness.light,
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      foregroundColor: onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: onSurface,
        fontSize: 19,
        fontWeight: FontWeight.w600,
        letterSpacing: 1,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      indicatorColor: accent.withValues(alpha: dark ? 0.16 : 0.12),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 11, color: subText.withValues(alpha: 0.9)),
      ),
    ),
    cardTheme: CardThemeData(
      color: card,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: subText,
      textColor: cardText,
    ),
    dividerTheme: DividerThemeData(color: divider, thickness: 0.6),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: card,
      contentTextStyle: TextStyle(color: cardText),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: accent),
  );
}
