import 'package:flutter/material.dart';
import '../core/api_service.dart';
import '../core/app_theme.dart';
import '../core/config.dart';
import '../core/database.dart';
import '../main.dart' show themeNotifier;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _baseUrlCtrl   = TextEditingController();
  final _apiKeyCtrl    = TextEditingController();
  final _krKeyCtrl     = TextEditingController();
  final _krSecretCtrl  = TextEditingController();
  final _krAcctCtrl    = TextEditingController();
  final _usKeyCtrl     = TextEditingController();
  final _usSecretCtrl  = TextEditingController();
  final _usAcctCtrl    = TextEditingController();

  bool _loading  = true;
  bool _saving   = false;
  String? _msg;
  bool _isError  = false;

  bool _showApiKey   = false;
  bool _showKrSecret = false;
  bool _showUsSecret = false;

  // 테마 상태 (로컬 — 저장 전까지 AppTheme에 반영하지 않음)
  late bool _isDark;
  late Color _accent;
  late Color _krColor;
  late Color _usColor;

  @override
  void initState() {
    super.initState();
    _isDark  = AppTheme.isDark;
    _accent  = AppTheme.accent;
    _krColor = AppTheme.krColor;
    _usColor = AppTheme.usColor;
    _load();
  }

  Future<void> _load() async {
    final s = await AppDatabase.getAllSettings();
    _baseUrlCtrl.text  = s['base_url']       ?? Config.baseUrl;
    _apiKeyCtrl.text   = s['api_key']        ?? Config.apiKey;
    _krKeyCtrl.text    = s['kr_app_key']     ?? '';
    _krSecretCtrl.text = s['kr_app_secret']  ?? '';
    _krAcctCtrl.text   = s['kr_account_no']  ?? '';
    _usKeyCtrl.text    = s['us_app_key']     ?? '';
    _usSecretCtrl.text = s['us_app_secret']  ?? '';
    _usAcctCtrl.text   = s['us_account_no']  ?? '';
    setState(() { _loading = false; });
  }

  Future<void> _save() async {
    setState(() { _saving = true; _msg = null; });
    try {
      // 로컬 저장
      await AppDatabase.setSetting('base_url',      _baseUrlCtrl.text.trim());
      await AppDatabase.setSetting('api_key',       _apiKeyCtrl.text.trim());
      await AppDatabase.setSetting('kr_app_key',    _krKeyCtrl.text.trim());
      await AppDatabase.setSetting('kr_app_secret', _krSecretCtrl.text.trim());
      await AppDatabase.setSetting('kr_account_no', _krAcctCtrl.text.trim());
      await AppDatabase.setSetting('us_app_key',    _usKeyCtrl.text.trim());
      await AppDatabase.setSetting('us_app_secret', _usSecretCtrl.text.trim());
      await AppDatabase.setSetting('us_account_no', _usAcctCtrl.text.trim());

      // 메모리 Config 갱신
      Config.baseUrl = _baseUrlCtrl.text.trim();
      Config.apiKey  = _apiKeyCtrl.text.trim();

      // 테마 저장 및 전역 적용
      AppTheme.isDark   = _isDark;
      AppTheme.accent   = _accent;
      AppTheme.krColor  = _krColor;
      AppTheme.usColor  = _usColor;
      await Config.saveTheme();
      themeNotifier.value++;   // MaterialApp 재빌드 트리거

      // Flask 서버 계좌 업데이트
      final accounts = <Map<String, dynamic>>[];
      if (_krKeyCtrl.text.trim().isNotEmpty) {
        accounts.add({
          'market':     'KR',
          'app_key':    _krKeyCtrl.text.trim(),
          'app_secret': _krSecretCtrl.text.trim(),
          'account_no': _krAcctCtrl.text.trim(),
        });
      }
      if (_usKeyCtrl.text.trim().isNotEmpty) {
        accounts.add({
          'market':     'US',
          'app_key':    _usKeyCtrl.text.trim(),
          'app_secret': _usSecretCtrl.text.trim(),
          'account_no': _usAcctCtrl.text.trim(),
        });
      }
      if (accounts.isNotEmpty) {
        await ApiService.updateAccounts(accounts);
      }

      setState(() { _msg = '저장되었습니다'; _isError = false; });
    } catch (e) {
      setState(() { _msg = e.toString(); _isError = true; });
    } finally {
      setState(() { _saving = false; });
    }
  }

  @override
  void dispose() {
    for (final c in [
      _baseUrlCtrl, _apiKeyCtrl,
      _krKeyCtrl, _krSecretCtrl, _krAcctCtrl,
      _usKeyCtrl, _usSecretCtrl, _usAcctCtrl,
    ]) { c.dispose(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('설정'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.only(right: 14),
              child: Center(child: SizedBox(width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))),
            )
          else
            TextButton(
              onPressed: _save,
              child: const Text('저장', style: TextStyle(fontSize: 14)),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_msg != null)
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: (_isError ? const Color(0xFFF85149) : const Color(0xFF2EA043))
                    .withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _isError ? const Color(0xFFF85149) : const Color(0xFF2EA043)),
              ),
              child: SelectableText(_msg!,
                style: TextStyle(
                  fontSize: 12,
                  color: _isError ? const Color(0xFFF85149) : const Color(0xFF2EA043),
                ),
              ),
            ),

          // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          // 앱 테마
          // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          _SectionHeader('앱 테마'),

          // 다크 / 라이트 모드 토글
          _SettingRow(
            label: '화면 모드',
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _ModeBtn(label: '다크', selected: _isDark,
                  onTap: () => setState(() { _isDark = true; })),
              const SizedBox(width: 6),
              _ModeBtn(label: '라이트', selected: !_isDark,
                  onTap: () => setState(() { _isDark = false; })),
            ]),
          ),
          const SizedBox(height: 14),

          // 테마 색 (accent)
          _ColorPickerRow(
            label: '테마 색',
            subtitle: '버튼·선택·강조',
            palette: AppTheme.accentPalette,
            selected: _accent,
            onSelect: (c) => setState(() { _accent = c; }),
          ),
          const SizedBox(height: 14),

          // 한국 시장 색
          _ColorPickerRow(
            label: '한국 시장 색',
            subtitle: '한국 잔고 앞 dot',
            palette: AppTheme.marketPalette,
            selected: _krColor,
            onSelect: (c) => setState(() { _krColor = c; }),
          ),
          const SizedBox(height: 14),

          // 미국 시장 색
          _ColorPickerRow(
            label: '미국 시장 색',
            subtitle: '미국 잔고 앞 dot',
            palette: AppTheme.marketPalette,
            selected: _usColor,
            onSelect: (c) => setState(() { _usColor = c; }),
          ),
          const SizedBox(height: 22),

          // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          // 서버 설정
          // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          _SectionHeader('서버 설정'),
          _Field(label: '서버 주소', ctrl: _baseUrlCtrl, hint: 'https://mybotcontrol.duckdns.org'),
          const SizedBox(height: 10),
          _Field(
            label: 'API 키 (Flask 인증)',
            ctrl: _apiKeyCtrl,
            hint: '••••',
            obscure: !_showApiKey,
            suffix: _EyeBtn(
              visible: _showApiKey,
              onTap: () => setState(() { _showApiKey = !_showApiKey; }),
            ),
          ),

          const SizedBox(height: 22),
          _SectionHeader('KR 계좌'),
          _Field(label: 'App Key', ctrl: _krKeyCtrl, hint: 'PSxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'),
          const SizedBox(height: 10),
          _Field(
            label: 'App Secret',
            ctrl: _krSecretCtrl,
            hint: '••••••••••••••••••••••••',
            obscure: !_showKrSecret,
            suffix: _EyeBtn(
              visible: _showKrSecret,
              onTap: () => setState(() { _showKrSecret = !_showKrSecret; }),
            ),
          ),
          const SizedBox(height: 10),
          _Field(label: '계좌번호', ctrl: _krAcctCtrl, hint: '12345678-01'),

          const SizedBox(height: 22),
          _SectionHeader('US 계좌'),
          _Field(label: 'App Key', ctrl: _usKeyCtrl, hint: 'PSxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'),
          const SizedBox(height: 10),
          _Field(
            label: 'App Secret',
            ctrl: _usSecretCtrl,
            hint: '••••••••••••••••••••••••',
            obscure: !_showUsSecret,
            suffix: _EyeBtn(
              visible: _showUsSecret,
              onTap: () => setState(() { _showUsSecret = !_showUsSecret; }),
            ),
          ),
          const SizedBox(height: 10),
          _Field(label: '계좌번호', ctrl: _usAcctCtrl, hint: '12345678-01'),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ── 색상 선택 행 ─────────────────────────────────────────────────
class _ColorPickerRow extends StatelessWidget {
  final String label;
  final String subtitle;
  final List<NamedColor> palette;
  final Color selected;
  final ValueChanged<Color> onSelect;

  const _ColorPickerRow({
    required this.label,
    required this.subtitle,
    required this.palette,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(width: 12, height: 12,
            decoration: BoxDecoration(color: selected, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(width: 6),
        Text(subtitle, style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
      ]),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: palette.map((nc) {
        final isSel = nc.color.value == selected.value;
        return GestureDetector(
          onTap: () => onSelect(nc.color),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: nc.color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSel ? Colors.white : Colors.transparent,
                  width: 2.5,
                ),
                boxShadow: isSel ? [BoxShadow(
                  color: nc.color.withValues(alpha: 0.6),
                  blurRadius: 6, spreadRadius: 1,
                )] : null,
              ),
              child: isSel
                  ? const Icon(Icons.check, size: 16, color: Colors.white)
                  : null,
            ),
            const SizedBox(height: 3),
            Text(nc.name, style: TextStyle(
              fontSize: 8,
              color: isSel ? Colors.white : const Color(0xFF8B949E),
            )),
          ]),
        );
      }).toList()),
    ]);
  }
}


// ── 다크/라이트 버튼 ──────────────────────────────────────────────
class _ModeBtn extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ModeBtn({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: selected ? AppTheme.accent : const Color(0xFF21262D),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: selected ? AppTheme.accent : const Color(0xFF30363D)),
      ),
      child: Text(label, style: TextStyle(
        fontSize: 12, fontWeight: FontWeight.w600,
        color: selected ? Colors.white : const Color(0xFF8B949E),
      )),
    ),
  );
}

// ── 설정 행 ──────────────────────────────────────────────────────
class _SettingRow extends StatelessWidget {
  final String label;
  final Widget child;
  const _SettingRow({required this.label, required this.child});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      const Spacer(),
      child,
    ],
  );
}

// ── widgets ──────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(text, style: const TextStyle(
        color: Color(0xFF8B949E), fontSize: 11, fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
      )),
      const SizedBox(height: 6),
      const Divider(color: Color(0xFF30363D), height: 1),
    ]),
  );
}

class _Field extends StatelessWidget {
  final String label;
  final TextEditingController ctrl;
  final String hint;
  final bool obscure;
  final Widget? suffix;
  const _Field({
    required this.label, required this.ctrl, required this.hint,
    this.obscure = false, this.suffix,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(
        color: Color(0xFF8B949E), fontSize: 10, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      TextField(
        controller: ctrl,
        obscureText: obscure,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: Color(0xFF6E7681), fontSize: 11),
          filled: true,
          fillColor: const Color(0xFF0D1117),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0xFF30363D)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0xFF30363D)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0xFF58A6FF)),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          suffixIcon: suffix,
        ),
      ),
    ],
  );
}

class _EyeBtn extends StatelessWidget {
  final bool visible;
  final VoidCallback onTap;
  const _EyeBtn({required this.visible, required this.onTap});

  @override
  Widget build(BuildContext context) => IconButton(
    icon: Icon(
      visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
      size: 18, color: const Color(0xFF8B949E),
    ),
    onPressed: onTap,
  );
}
