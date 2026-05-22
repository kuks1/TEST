import 'package:flutter/material.dart';

/// 앱 전역 테마 설정 (singleton static)
/// - accent: 버튼·선택상태·강조 색
/// - krColor: 한국 시장 표시 색
/// - usColor: 미국 시장 표시 색
/// - isDark: 다크/라이트 모드
class AppTheme {
  static bool isDark     = true;
  static Color accent    = const Color(0xFF58A6FF);
  static Color krColor   = const Color(0xFF2EA043);
  static Color usColor   = const Color(0xFF58A6FF);

  // 색상 팔레트 (설정 화면에서 선택)
  static const List<NamedColor> accentPalette = [
    NamedColor('플루터 블루',   Color(0xFF58A6FF)),
    NamedColor('인디고',       Color(0xFF6366F1)),
    NamedColor('바이올렛',     Color(0xFFA855F7)),
    NamedColor('핑크',         Color(0xFFEC4899)),
    NamedColor('오렌지',       Color(0xFFF97316)),
    NamedColor('골드',         Color(0xFFD4AF37)),
    NamedColor('에메랄드',     Color(0xFF10B981)),
    NamedColor('시안',         Color(0xFF06B6D4)),
  ];

  static const List<NamedColor> marketPalette = [
    NamedColor('초록',   Color(0xFF2EA043)),
    NamedColor('블루',   Color(0xFF58A6FF)),
    NamedColor('에메랄드', Color(0xFF10B981)),
    NamedColor('민트',   Color(0xFF06B6D4)),
    NamedColor('오렌지', Color(0xFFF97316)),
    NamedColor('골드',   Color(0xFFD4AF37)),
    NamedColor('핑크',   Color(0xFFEC4899)),
    NamedColor('바이올렛', Color(0xFFA855F7)),
  ];

  static ThemeData buildTheme() {
    final bg      = isDark ? const Color(0xFF0D1117) : const Color(0xFFF6F8FA);
    final surface = isDark ? const Color(0xFF161B22) : const Color(0xFFFFFFFF);
    final border  = isDark ? const Color(0xFF30363D) : const Color(0xFFD0D7DE);
    final onSurf  = isDark ? const Color(0xFFE6EDF3) : const Color(0xFF1F2328);
    final subtext = isDark ? const Color(0xFF8B949E) : const Color(0xFF57606A);

    return ThemeData(
      fontFamily: 'NanumGothic',
      brightness: isDark ? Brightness.dark : Brightness.light,
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme(
        brightness: isDark ? Brightness.dark : Brightness.light,
        primary: accent,
        secondary: krColor,
        tertiary: usColor,
        error: const Color(0xFFF85149),
        surface: surface,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onTertiary: Colors.white,
        onError: Colors.white,
        onSurface: onSurf,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: onSurf,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(color: subtext),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF238636),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: accent,
        unselectedItemColor: subtext,
        selectedLabelStyle: const TextStyle(fontSize: 11),
        unselectedLabelStyle: const TextStyle(fontSize: 11),
      ),
      dividerColor: border,
      textTheme: TextTheme(
        bodyMedium: TextStyle(color: onSurf),
        bodySmall: TextStyle(color: subtext),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF0D1117) : const Color(0xFFF6F8FA),
        hintStyle: TextStyle(color: subtext, fontSize: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: accent),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }

  // 색상 → 16진수 문자열 (DB 저장용)
  static String colorToHex(Color c) =>
      '#${c.value.toRadixString(16).padLeft(8, '0').toUpperCase()}';

  // 16진수 문자열 → 색상
  static Color hexToColor(String hex) {
    try {
      final h = hex.replaceFirst('#', '');
      return Color(int.parse(h.length == 6 ? 'FF$h' : h, radix: 16));
    } catch (_) {
      return const Color(0xFF58A6FF);
    }
  }
}

class NamedColor {
  final String name;
  final Color color;
  const NamedColor(this.name, this.color);
}
