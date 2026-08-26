import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局轻量状态：书架刷新信号 + 主题设置 + 阅读器设置
enum AppThemeMode { system, dark, light }

class AppState {
  static final ValueNotifier<int> shelfVersion = ValueNotifier(0);
  static final ValueNotifier<AppThemeMode> appThemeMode =
      ValueNotifier(AppThemeMode.dark);
  static final ValueNotifier<String> accentKey = ValueNotifier('gold');

  /// -1=全部, 0=未分类, >0=自建书架 id
  static int lastShelfId = -1;

  static void notifyShelf() => shelfVersion.value++;

  static Future<void> loadPrefs() async {
    final sp = await SharedPreferences.getInstance();
    lastShelfId = sp.getInt('last_shelf_id') ?? -1;
    final mode = sp.getString('app_theme_mode') ?? 'dark';
    appThemeMode.value = AppThemeMode.values.firstWhere(
      (e) => e.name == mode,
      orElse: () => AppThemeMode.dark,
    );
    accentKey.value = sp.getString('app_accent') ?? 'gold';
  }

  static Future<void> saveLastShelf(int id) async {
    lastShelfId = id;
    final sp = await SharedPreferences.getInstance();
    await sp.setInt('last_shelf_id', id);
  }

  static Future<void> saveThemeMode(AppThemeMode mode) async {
    appThemeMode.value = mode;
    final sp = await SharedPreferences.getInstance();
    await sp.setString('app_theme_mode', mode.name);
  }

  static Future<void> saveAccent(String key) async {
    accentKey.value = key;
    final sp = await SharedPreferences.getInstance();
    await sp.setString('app_accent', key);
  }
}

class ReaderSettings {
  static double fontSize = 20;
  static double lineHeight = 1.9;
  static int themeIndex = 3; // 默认暗夜
  static double paragraphGap = 10;
  static bool pagedMode = true; // 默认仿真分页
  static double letterSpacing = 0; // 字距（pt 级微调）
  static double pagePadding = 22; // 左右页边距
  static String fontKey = 'system'; // 字体：system/serif/kai/round/hei/wenkai/noto/custom
  static String customFontFamily = ''; // 自定义字体家族名（系统里已安装的）
  static double screenDim = 0; // 阅读页亮度遮罩 0~0.6
  static String pageAnim = 'curl'; // 翻页动画：slide=滑动, curl=卷页

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    fontSize = sp.getDouble('reader_font_size') ?? 20;
    lineHeight = sp.getDouble('reader_line_height') ?? 1.9;
    themeIndex = sp.getInt('reader_theme') ?? 3;
    paragraphGap = sp.getDouble('reader_para_gap') ?? 10;
    pagedMode = sp.getBool('reader_paged_mode') ?? true;
    letterSpacing = sp.getDouble('reader_letter_spacing') ?? 0;
    pagePadding = sp.getDouble('reader_page_padding') ?? 22;
    fontKey = sp.getString('reader_font_key') ?? 'system';
    customFontFamily = sp.getString('reader_custom_font') ?? '';
    screenDim = sp.getDouble('reader_screen_dim') ?? 0;
    pageAnim = sp.getString('reader_page_anim') ?? 'curl';
  }

  static Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble('reader_font_size', fontSize);
    await sp.setDouble('reader_line_height', lineHeight);
    await sp.setInt('reader_theme', themeIndex);
    await sp.setDouble('reader_para_gap', paragraphGap);
    await sp.setBool('reader_paged_mode', pagedMode);
    await sp.setDouble('reader_letter_spacing', letterSpacing);
    await sp.setDouble('reader_page_padding', pagePadding);
    await sp.setString('reader_font_key', fontKey);
    await sp.setString('reader_custom_font', customFontFamily);
    await sp.setDouble('reader_screen_dim', screenDim);
    await sp.setString('reader_page_anim', pageAnim);
  }

  /// 应用阅读字体/字距到正文样式
  static TextStyle applyTextStyle(TextStyle base) {
    return base.copyWith(
      letterSpacing: letterSpacing,
      fontFamilyFallback: switch (fontKey) {
        'serif' =>
          const ['Songti SC', 'STSong', 'Noto Serif CJK SC', 'serif'],
        'kai' => const ['Kaiti SC', 'STKaiti', 'KaiTi', 'serif'],
        'round' => const ['Yuanti SC', 'STYuanti', 'sans-serif'],
        'hei' => const ['Heiti SC', 'STHeiti', 'Noto Sans CJK SC', 'sans-serif'],
        'wenkai' => const ['WenKai', 'LXGW WenKai', 'Songti SC', 'serif'],
        'noto' => const ['NotoSerifSC', 'Songti SC', 'serif'],
        'custom' =>
          [if (customFontFamily.isNotEmpty) customFontFamily, 'serif'],
        _ => null,
      },
    );
  }
}

/// 阅读器配色
class ReaderTheme {
  final String name;
  final Color bg;
  final Color text;
  const ReaderTheme(this.name, this.bg, this.text);
}

const List<ReaderTheme> kReaderThemes = [
  ReaderTheme('素白', Color(0xFFF7F6F2), Color(0xFF2C2C2C)),
  ReaderTheme('翠绿', Color(0xFFCDE7D0), Color(0xFF1F3327)),
  ReaderTheme('羊皮', Color(0xFFEADFC4), Color(0xFF4A3B26)),
  ReaderTheme('暗夜', Color(0xFF1C2129), Color(0xFFB9C0CA)),
  ReaderTheme('墨黑', Color(0xFF0A0C0F), Color(0xFF8A919C)),
];
