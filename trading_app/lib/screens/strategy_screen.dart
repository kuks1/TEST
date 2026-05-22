import 'package:flutter/material.dart';
import '../core/api_service.dart';
import '../core/common.dart';
import '../core/database.dart';
import '../models/strategy.dart';
import 'detail/mm_detail_screen.dart';
import 'detail/qt_detail_screen.dart';
import 'settings_screen.dart';

class StrategyScreen extends StatefulWidget {
  const StrategyScreen({super.key});
  @override
  State<StrategyScreen> createState() => _StrategyScreenState();
}

class _StrategyScreenState extends State<StrategyScreen> {
  List<Strategy> _strategies = [];
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await AppDatabase.getStrategies();
    setState(() { _strategies = list; });
  }

  Future<void> _toggle(Strategy s) async {
    await AppDatabase.toggleActive(s);
    _load();
  }

  Future<void> _delete(Strategy s) async {
    final portfolioStocks = await AppDatabase.getPortfolioStocks(s.strategyId);

    if (portfolioStocks.isEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF161B22),
          title: const Text('전략 삭제'),
          content: Text('${s.strategyId} 전략을 삭제할까요?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('취소')),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: const Color(0xFFF85149)),
              child: const Text('삭제'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    } else {
      final choice = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF161B22),
          title: Text('${s.strategyId} 삭제'),
          content: Text('보유 종목 ${portfolioStocks.length}개를 어떻게 처리할까요?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'nostrat'),
              child: const Text('전략없음으로 이동'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'sell'),
              style: TextButton.styleFrom(foregroundColor: const Color(0xFFF85149)),
              child: const Text('시장가 매도 예약'),
            ),
          ],
        ),
      );
      if (choice == null) return;

      if (choice == 'sell') {
        final scheduled = await showModalBottomSheet<DateTime>(
          context: context,
          isScrollControlled: true,
          backgroundColor: const Color(0xFF161B22),
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
          builder: (_) => const _ScheduleSheet(),
        );
        if (scheduled == null) return;
        for (final stock in portfolioStocks) {
          await AppDatabase.insertPendingSell({
            'ticker': stock['ticker'] as String,
            'name': stock['name'] as String? ?? stock['ticker'],
            'market': s.market,
            'quantity': 0.0,
            'avg_price': 0.0,
            'scheduled_at': scheduled.toIso8601String(),
            'status': 'pending',
            'source_strategy_id': s.strategyId,
            'created_at': DateTime.now().toIso8601String(),
          });
        }
      }
    }

    await AppDatabase.clearPortfolioStocks(s.strategyId);
    await AppDatabase.deleteStrategy(s.id!);
    _load();
  }

  Future<void> _syncToServer() async {
    if (_syncing) return;
    setState(() { _syncing = true; });
    try {
      final strategies = await AppDatabase.getStrategies();
      final payload = <Map<String, dynamic>>[];
      for (final s in strategies) {
        final map = s.toMap();
        if (s.type == 'kr_value') {
          final stocks = await AppDatabase.getPortfolioStocks(s.strategyId);
          map['stocks'] = stocks
              .map((r) => {'ticker': r['ticker'], 'weight': r['weight']})
              .toList();
        }
        payload.add(map);
      }
      await ApiService.syncStrategies(payload);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${payload.length}개 전략 서버 동기화 완료'),
              duration: const Duration(seconds: 2)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('동기화 실패: $e'),
              backgroundColor: const Color(0xFFF85149)),
        );
      }
    }
    setState(() { _syncing = false; });
  }

  void _openDetail(Strategy s) {
    Widget screen;
    if (s.type == 'kr_value') {
      screen = KrValueDetailScreen(strategy: s);
    } else {
      screen = V4DetailScreen(strategy: s);
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen))
        .then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('전략'),
        actions: [
          _syncing
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : IconButton(
                  icon: const Icon(Icons.cloud_upload_outlined),
                  tooltip: '서버 동기화',
                  onPressed: _syncToServer,
                ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _openAddSheet(context),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 20),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: _strategies.isEmpty
          ? _buildEmpty()
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _strategies.length,
              itemBuilder: (_, i) => _StrategyCard(
                strategy: _strategies[i],
                onTap: () => _openDetail(_strategies[i]),
                onToggle: () => _toggle(_strategies[i]),
                onDelete: () => _delete(_strategies[i]),
                onEdit: () => _openEditSheet(context, _strategies[i]),
              ),
            ),
    );
  }

  Widget _buildEmpty() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.add_chart, color: Color(0xFF8B949E), size: 48),
          const SizedBox(height: 12),
          const Text('등록된 전략이 없습니다',
              style: TextStyle(color: Color(0xFF8B949E))),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('전략 추가'),
            onPressed: () => _openAddSheet(context),
          ),
        ]),
      );

  void _openAddSheet(BuildContext ctx) {
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _StrategyForm(onSave: (s) async {
        await AppDatabase.insertStrategy(s);
        _load();
      }),
    );
  }

  void _openEditSheet(BuildContext ctx, Strategy s) {
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _StrategyForm(
        initial: s,
        onSave: (updated) async {
          await AppDatabase.updateStrategy(updated);
          _load();
        },
      ),
    );
  }
}

// ── 전략 카드 ──────────────────────────────────────────────────
class _StrategyCard extends StatelessWidget {
  final Strategy strategy;
  final VoidCallback onTap, onToggle, onDelete, onEdit;

  const _StrategyCard({
    required this.strategy, required this.onTap,
    required this.onToggle, required this.onDelete, required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final s = strategy;
    final isActive = s.active;
    final currency = s.market == 'KR' ? '원' : '\$';

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(width: 3,
                color: isActive ? const Color(0xFF1F6FEB) : const Color(0xFF6E7681)),
            Expanded(
              child: Container(
                color: const Color(0xFF161B22),
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // 헤더
            Row(children: [
              Expanded(child: Row(children: [
                Text(s.strategyId,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(width: 8),
                _Badge(s.typeLabel, active: isActive),
                const SizedBox(width: 4),
                _Badge(s.market, active: true,
                    color: const Color(0xFF388BFD22), textColor: const Color(0xFF58A6FF)),
              ])),
              // 편집
              IconButton(
                icon: const Icon(Icons.edit, size: 16, color: Color(0xFF8B949E)),
                onPressed: onEdit,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 8),
              // 활성 토글
              GestureDetector(onTap: onToggle, child: _Toggle(active: isActive)),
            ]),
            const SizedBox(height: 8),

            // 정보
            Row(children: [
              _InfoCell('종목', s.symbol.isEmpty ? '-' : s.symbol),
              _InfoCell('할당금액',
                  '${s.market == 'KR' ? Fmt.num(s.capital) : s.capital.toStringAsFixed(0)} $currency'),
              if (s.type == 'v4' || s.type == 'v1')
                _InfoCell('T값', s.tValue?.toStringAsFixed(2) ?? '-'),
              _InfoCell('경과일', '${MarketClock.elapsedDays(s.createdAt)}일'),
            ]),

            // 상세 힌트
            const SizedBox(height: 6),
            const Row(children: [
              Spacer(),
              Text('상세 보기 ›',
                  style: TextStyle(color: Color(0xFF6E7681), fontSize: 10)),
            ]),

            // 삭제
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onDelete,
                style: TextButton.styleFrom(padding: EdgeInsets.zero,
                    minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: const Text('삭제',
                    style: TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
              ),
            ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ── 전략 추가/수정 폼 ───────────────────────────────────────────
class _StrategyForm extends StatefulWidget {
  final Strategy? initial;
  final Future<void> Function(Strategy) onSave;
  const _StrategyForm({this.initial, required this.onSave});

  @override
  State<_StrategyForm> createState() => _StrategyFormState();
}

class _StrategyFormState extends State<_StrategyForm> {
  final _idCtrl = TextEditingController();
  final _symbolCtrl = TextEditingController();
  final _capitalCtrl = TextEditingController();
  final _pctCtrl = TextEditingController();
  final _tCtrl = TextEditingController();
  final _v1Ctrl = TextEditingController();
  String _type = 'v4';
  String _market = 'KR';
  bool _saving = false;
  bool _usePct = false; // % 모드

  @override
  void initState() {
    super.initState();
    final s = widget.initial;
    if (s != null) {
      _idCtrl.text = s.strategyId;
      _symbolCtrl.text = s.symbol;
      _capitalCtrl.text = s.capital.toInt().toString();
      _type = s.type;
      _market = s.market;
      if (s.tValue != null) _tCtrl.text = s.tValue!.toStringAsFixed(2);
      if (s.v1Value != null) _v1Ctrl.text = s.v1Value!.toInt().toString();
    }
  }

  @override
  void dispose() {
    for (final c in [_idCtrl, _symbolCtrl, _capitalCtrl, _pctCtrl, _tCtrl, _v1Ctrl]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_idCtrl.text.isEmpty) return;
    setState(() { _saving = true; });

    String symbol = _symbolCtrl.text.trim().toUpperCase();
    if (_market == 'KR' && RegExp(r'^\d+$').hasMatch(symbol)) {
      symbol = symbol.padLeft(6, '0');
    }

    final s = Strategy(
      id: widget.initial?.id,
      strategyId: _idCtrl.text.trim(),
      type: _type,
      symbol: symbol,
      market: _market,
      capital: double.tryParse(_capitalCtrl.text) ?? 0,
      active: widget.initial?.active ?? true,
      tValue: double.tryParse(_tCtrl.text),
      v1Value: double.tryParse(_v1Ctrl.text),
      createdAt: widget.initial?.createdAt ?? DateTime.now(),
    );

    await widget.onSave(s);
    if (mounted) Navigator.pop(context);
    setState(() { _saving = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.initial != null ? '전략 수정' : '전략 추가',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),

        // 타입
        _Label('전략 타입'),
        DropdownButtonFormField<String>(
          value: _type, dropdownColor: const Color(0xFF161B22),
          decoration: _deco(),
          items: const [
            DropdownMenuItem(value: 'v4', child: Text('MM V4 (무한매수 20분할)')),
            DropdownMenuItem(value: 'v1', child: Text('MM V1 (무한매수 기본)')),
            DropdownMenuItem(value: 'vr', child: Text('VR (가치리밸런싱)')),
            DropdownMenuItem(value: 'kr_value', child: Text('QT KR (소형가치주)')),
          ],
          onChanged: (v) => setState(() { _type = v!; }),
        ),
        const SizedBox(height: 12),

        // 전략 ID
        _Label('전략 ID'),
        TextField(controller: _idCtrl, decoration: _deco(hint: '예: v4_soxl')),
        const SizedBox(height: 12),

        // 종목
        if (_type != 'kr_value') ...[
          _Label('종목 코드'),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _symbolCtrl,
                decoration: _deco(hint: 'KR: 005930  US: SOXL'),
                textCapitalization: TextCapitalization.characters,
                onChanged: (v) => setState(() {
                  _market = RegExp(r'^\d+$').hasMatch(v.trim()) ? 'KR' : 'US';
                }),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1117),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF30363D)),
              ),
              child: Text(_market,
                  style: const TextStyle(color: Color(0xFF58A6FF), fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 12),
        ],

        // 할당금액 (금액 or %)
        Row(children: [
          _Label('할당금액'),
          const Spacer(),
          GestureDetector(
            onTap: () => setState(() { _usePct = !_usePct; }),
            child: Text(_usePct ? '금액으로' : '%로 입력',
                style: const TextStyle(color: Color(0xFF58A6FF), fontSize: 11)),
          ),
        ]),
        if (_usePct)
          Row(children: [
            Expanded(child: TextField(
              controller: _pctCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: _deco(hint: '잔고의 %', suffix: '%'),
            )),
            const SizedBox(width: 8),
            const Text('→ 자동 계산', style: TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
          ])
        else
          TextField(
            controller: _capitalCtrl,
            keyboardType: TextInputType.number,
            decoration: _deco(hint: '예: 5000000'),
          ),
        const SizedBox(height: 12),

        // T값
        if (_type == 'v4' || _type == 'v1') ...[
          _Label('T값'),
          TextField(
            controller: _tCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: _deco(hint: '0'),
          ),
          const SizedBox(height: 12),
        ],

        // V1 (VR)
        if (_type == 'vr') ...[
          _Label('V1 값'),
          TextField(
            controller: _v1Ctrl,
            keyboardType: TextInputType.number,
            decoration: _deco(hint: '예: 5000'),
          ),
          const SizedBox(height: 12),
        ],

        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소', style: TextStyle(color: Color(0xFF8B949E))),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(widget.initial != null ? '저장' : '등록'),
          ),
        ]),
      ]),
    );
  }

  InputDecoration _deco({String? hint, String? suffix}) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF8B949E)),
        suffixText: suffix,
        suffixStyle: const TextStyle(color: Color(0xFF8B949E)),
        filled: true, fillColor: const Color(0xFF0D1117),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0xFF30363D))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0xFF30363D))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0xFF1F6FEB))),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        isDense: true,
      );
}

class _Badge extends StatelessWidget {
  final String label;
  final bool active;
  final Color? color, textColor;
  const _Badge(this.label, {required this.active, this.color, this.textColor});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color ?? (active ? const Color(0xFF1F6FEB22) : const Color(0xFF21262D)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label, style: TextStyle(
          fontSize: 10,
          color: textColor ?? (active ? const Color(0xFF58A6FF) : const Color(0xFF6E7681)),
        )),
      );
}

class _Toggle extends StatelessWidget {
  final bool active;
  const _Toggle({required this.active});

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 40, height: 22,
        decoration: BoxDecoration(
          color: active ? const Color(0xFF238636) : const Color(0xFF6E7681),
          borderRadius: BorderRadius.circular(11),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 200),
          alignment: active ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 18, height: 18,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
          ),
        ),
      );
}

class _InfoCell extends StatelessWidget {
  final String label, value;
  const _InfoCell(this.label, this.value);
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
          Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis),
        ]),
      );
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
      );
}

// ── 매도 예약 일시 설정 시트 ────────────────────────────────────
class _ScheduleSheet extends StatefulWidget {
  const _ScheduleSheet();
  @override
  State<_ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends State<_ScheduleSheet> {
  late DateTime _scheduled;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _scheduled = DateTime(now.year, now.month, now.day + 1, 9, 0);
  }

  String get _displayStr {
    final d = _scheduled;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          width: 36, height: 4,
          decoration: BoxDecoration(
              color: const Color(0xFF30363D), borderRadius: BorderRadius.circular(2))),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text('매도 예약 일시 설정',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        ),
        const Divider(color: Color(0xFF30363D), height: 1),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1117),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF30363D)),
              ),
              child: Row(children: [
                const Icon(Icons.schedule, size: 16, color: Color(0xFF58A6FF)),
                const SizedBox(width: 10),
                Text(_displayStr,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600,
                        color: Color(0xFF58A6FF))),
              ]),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today, size: 14),
                label: const Text('날짜 선택'),
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _scheduled,
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                    builder: (ctx, child) => Theme(data: ThemeData.dark(), child: child!),
                  );
                  if (d != null && mounted) {
                    setState(() {
                      _scheduled = DateTime(
                          d.year, d.month, d.day, _scheduled.hour, _scheduled.minute);
                    });
                  }
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF8B949E),
                  side: const BorderSide(color: Color(0xFF30363D)),
                ),
              )),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton.icon(
                icon: const Icon(Icons.access_time, size: 14),
                label: const Text('시간 선택'),
                onPressed: () async {
                  final t = await showTimePicker(
                    context: context,
                    initialTime:
                        TimeOfDay(hour: _scheduled.hour, minute: _scheduled.minute),
                    builder: (ctx, child) => Theme(data: ThemeData.dark(), child: child!),
                  );
                  if (t != null && mounted) {
                    setState(() {
                      _scheduled = DateTime(_scheduled.year, _scheduled.month,
                          _scheduled.day, t.hour, t.minute);
                    });
                  }
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF8B949E),
                  side: const BorderSide(color: Color(0xFF30363D)),
                ),
              )),
            ]),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(children: [
            Expanded(child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF30363D)),
                foregroundColor: const Color(0xFF8B949E),
              ),
              child: const Text('취소'),
            )),
            const SizedBox(width: 12),
            Expanded(child: ElevatedButton(
              onPressed: () => Navigator.pop(context, _scheduled),
              child: const Text('확인'),
            )),
          ]),
        ),
      ]),
    );
  }
}
