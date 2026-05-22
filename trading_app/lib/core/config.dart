import 'package:flutter/material.dart';
import 'app_theme.dart';
import 'database.dart';

class Config {
  static String baseUrl = 'https://mybotcontrol.duckdns.org';
  static String apiKey = '6495';

  static Future<void> load() async {
    final s = await AppDatabase.getAllSettings();

    final url = s['base_url'];
    final key = s['api_key'];
    if (url != null && url.isNotEmpty) baseUrl = url;
    if (key != null && key.isNotEmpty) apiKey = key;

    // 테마 설정
    final dark = s['theme_is_dark'];
    AppTheme.isDark = dark == null ? true : dark == '1';

    final accent = s['theme_accent'];
    if (accent != null && accent.isNotEmpty) {
      AppTheme.accent = AppTheme.hexToColor(accent);
    }
    final kr = s['theme_kr_color'];
    if (kr != null && kr.isNotEmpty) {
      AppTheme.krColor = AppTheme.hexToColor(kr);
    }
    final us = s['theme_us_color'];
    if (us != null && us.isNotEmpty) {
      AppTheme.usColor = AppTheme.hexToColor(us);
    }
  }

  static Future<void> saveTheme() async {
    await AppDatabase.setSetting('theme_is_dark', AppTheme.isDark ? '1' : '0');
    await AppDatabase.setSetting('theme_accent',   AppTheme.colorToHex(AppTheme.accent));
    await AppDatabase.setSetting('theme_kr_color', AppTheme.colorToHex(AppTheme.krColor));
    await AppDatabase.setSetting('theme_us_color', AppTheme.colorToHex(AppTheme.usColor));
  }
}
