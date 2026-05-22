import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/api_service.dart';
import '../../core/common.dart';
import '../../core/database.dart';
import '../../models/strategy.dart';

class V4DetailScreen extends StatefulWidget {
  final Strategy strategy;
  const V4DetailScreen({super.key, required this.strategy});

  @override
  State<V4DetailScreen> createState() => _V4DetailScreenState();
}

class _V4DetailScreenState extends State<V4DetailScreen> {
  late Strategy _strategy;
  bool _loading = false;
  bool _executing = false;
  Timer? _pollTimer;
  String? _lastExecTime;
  Map<String, dynamic>? _holding;
  double _cash = 0;
  final _tCtrl = TextEditingController();
  final _divCtrl = TextEditingController();
  final _starBaseCtrl = TextEditingController();
  final _starCoeffCtrl = TextEditingController();
  final _v1ProfitCtrl = TextEditingController();
  final _salsaTpCtrl = TextEditingController();
  final _salsaSlCtrl = TextEditingController();
  final _capitalEditCtrl = TextEditingController();
  final _calcCapitalEditCtrl = TextEditingController();
  bool _editingT = false;
  bool _editingConsts = false;
  bool _editingV1Consts = false;
  double? _pendingCapital;
  double? _pendingCalcCapital;
  String _serverMmMode = 'normal';
  int _serverReverseDay = 0;
  bool _serverStateLoaded = false;

  bool get _hasUnsavedChanges =>
      _editingT || _editingConsts || _editingV1Consts ||
      _pendingCapital != null || _pendingCalcCapital != null;

  Future<bool?> _confirmDiscard() => showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: const Color(0xFF161B22),
      title: const Text('변경사항 취소'),
      content: const Text('저장하지 않은 변경사항이 있습니다.\n나가면 변경사항이 사라집니다.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('계속 수정'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          style: TextButton.styleFrom(foregroundColor: const Color(0xFFF85149)),
          child: const Text('나가기'),
        ),
      ],
    ),
  );

  Strategy get s => _strategy;
  bool get _isV4 => s.type == 'v4';
  bool get _isOpen => s.market == 'KR' ? MarketClock.isKrOpen : MarketClock.isUsOpen;
  String _nextOpen() => s.market == 'KR' ? MarketClock.nextKrOpen() : MarketClock.nextUsOpen();
  String _capStr(double v) => s.market == 'KR' ? v.toInt().toString() : v.toStringAsFixed(2);

  @override
  void initState() {
    super.initState();
    _strategy = widget.strategy;
    _tCtrl.text = s.tValue?.toStringAsFixed(10) ?? '0';
    _divCtrl.text = (s.divisions ?? (_isV4 ? 20 : 10)).toString();
    _starBaseCtrl.text = (s.starBase ?? 20).toString();
    _starCoeffCtrl.text = (s.starCoeff ?? 2.0).toStringAsFixed(1);
    _v1ProfitCtrl.text = (s.v1Value ?? 5.0).toStringAsFixed(1);
    _salsaTpCtrl.text = (s.v1SalsaTpPct ?? 5.0).toStringAsFixed(1);
    _salsaSlCtrl.text = (s.v1SalsaSlPct ?? 10.0).toStringAsFixed(1);
    _capitalEditCtrl.text = _capStr(s.capital);
    _calcCapitalEditCtrl.text = _capStr(s.calcCapital ?? s.capital);
    _loadAccount();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _tCtrl.dispose();
    _divCtrl.dispose();
    _starBaseCtrl.dispose();
    _starCoeffCtrl.dispose();
    _v1ProfitCtrl.dispose();
    _salsaTpCtrl.dispose();
    _salsaSlCtrl.dispose();
    _capitalEditCtrl.dispose();
    _calcCapitalEditCtrl.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (!mounted) return;
    final holdingShares = (_holding?['shares'] as num? ?? 0).toInt();
    final avgPrice = (_holding?['avg_price'] as num? ?? 0).toDouble();
    final hasHolding = holdingShares > 0 && s.symbol.isNotEmpty;

    if (hasHolding) {
      final choice = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF161B22),
          title: Text('${s.strategyId} 삭제'),
          content: Text('보유 중인 ${s.symbol} 종목을 어떻게 처리할까요?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
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
      if (choice == null || !mounted) return;
      if (choice == 'sell') {
        final scheduled = await _showScheduleSheet();
        if (scheduled == null || !mounted) return;
        await AppDatabase.insertPendingSell({
          'ticker': s.symbol,
          'name': s.symbol,
          'market': s.market,
          'quantity': holdingShares.toDouble(),
          'avg_price': avgPrice,
          'scheduled_at': scheduled.toIso8601String(),
          'status': 'pending',
          'source_strategy_id': s.strategyId,
          'created_at': DateTime.now().toIso8601String(),
        });
      }
    } else {
      final confirm = await showDialog<bool>(
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
      if (confirm != true || !mounted) return;
    }

    await AppDatabase.clearPortfolioStocks(s.strategyId);
    await AppDatabase.deleteStrategy(s.id!);
    if (mounted) Navigator.pop(context);
  }

  Future<DateTime?> _showScheduleSheet() {
    return showModalBottomSheet<DateTime>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => const ScheduleSheet(),
    );
  }

  Future<void> _loadAccount() async {
    setState(() { _loading = true; });
    try {
      final data = await ApiService.getAccount();
      final marketKey = s.market == 'KR' ? 'kr' : 'us';
      final accounts = (data[marketKey] as List? ?? []);
      Map<String, dynamic>? holding;
      for (final acc in accounts) {
        final holdings = (acc['holdings'] as List? ?? []).cast<Map>();
        for (final h in holdings) {
          if (h['ticker'] == s.symbol) {
            holding = Map<String, dynamic>.from(h);
          }
        }
      }
      // 서버 patch4가 cash_available을 holding에 포함시키면 우선 사용
      final cashAvailable = (holding?['cash_available'] as num? ?? 0).toDouble();
      final shares = (holding?['shares'] as num? ?? 0).toDouble();
      final avgPrice = (holding?['avg_price'] as num? ?? 0).toDouble();
      final costBasis = shares * avgPrice;
      final strategyCash = cashAvailable > 0
          ? cashAvailable
          : (s.capital - costBasis).clamp(0.0, double.infinity);
      setState(() { _holding = holding; _cash = strategyCash; });
      _checkCycleStatus(shares, shares * avgPrice + strategyCash);

      // V4: 서버에서 mm_mode, mm_reverse_day 동기화
      if (_isV4) {
        try {
          final serverData = await ApiService.getStrategies();
          final serverStrats = serverData['strategies'] as List? ?? [];
          final serverStrat = serverStrats.firstWhere(
            (st) => st['strategy_id'] == s.strategyId,
            orElse: () => <String, dynamic>{},
          ) as Map<String, dynamic>;
          setState(() {
            _serverMmMode = (serverStrat['mm_mode'] as String?) ?? 'normal';
            _serverReverseDay = ((serverStrat['mm_reverse_day'] as num?) ?? 0).toInt();
            _serverStateLoaded = true;
          });
        } catch (_) {}
      }
    } catch (_) {}
    setState(() { _loading = false; });
  }

  // ─── MM 사이클 종료 자동 감지 ────────────────────────────────
  Future<void> _checkCycleStatus(double shares, double evalNow) async {
    final settingKey = 'mm_cycle_${s.strategyId}';
    final cycleJson = await AppDatabase.getSetting(settingKey);
    final hasCycle = cycleJson != null && cycleJson.isNotEmpty;
    final isKr = s.market == 'KR';
    final now = DateTime.now();
    final today = now.toIso8601String().substring(0, 10);

    if (shares > 0) {
      if (!hasCycle) {
        // 사이클 시작: 현재 평가금액 저장
        await AppDatabase.setSetting(
            settingKey,
            jsonEncode({
              'startDate': today,
              'lastEvalBefore': evalNow,
            }));
      } else {
        // 사이클 진행 중: 최근 평가금액 갱신
        final data =
            jsonDecode(cycleJson) as Map<String, dynamic>;
        data['lastEvalBefore'] = evalNow;
        await AppDatabase.setSetting(settingKey, jsonEncode(data));
      }
    } else if (shares == 0 && hasCycle) {
      // 사이클 종료
      final data = jsonDecode(cycleJson) as Map<String, dynamic>;
      final evalBefore =
          (data['lastEvalBefore'] as num? ?? 0).toDouble();
      final evalAfter = _cash; // 모두 매도 후 현금
      final profit = evalAfter - evalBefore;
      final pnlPct =
          evalBefore > 0 ? (profit / evalBefore * 100) : 0.0;

      final lastEnd = await AppDatabase.getLastTradeLogByAction(
          s.strategyId, '사이클종료');
      if (lastEnd == null ||
          (lastEnd['date'] as String? ?? '') != today) {
        final fmt = isKr ? Fmt.krw : Fmt.usd;
        await AppDatabase.insertLog({
          'strategy_id': s.strategyId,
          'date': today,
          'event':
              '사이클종료 | 종료전 ${fmt(evalBefore)} → 종료후 ${fmt(evalAfter)} | '
              '수익 ${profit >= 0 ? '+' : ''}${fmt(profit.abs())}',
          'action': '사이클종료',
          'quantity': 0.0,
          'price': evalAfter,
          'pnl_pct': pnlPct,
          'created_at': now.toIso8601String(),
        });
      }
      await AppDatabase.setSetting(settingKey, '');
    }
  }

  Future<void> _saveT() async {
    final val = double.tryParse(_tCtrl.text);
    if (val == null) return;
    final updated = s.copyWith(tValue: val);
    await AppDatabase.updateStrategy(updated);
    setState(() { _strategy = updated; _editingT = false; });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('T값 저장됨'), duration: Duration(seconds: 1)),
      );
    }
  }

  Future<void> _saveConsts() async {
    final div = int.tryParse(_divCtrl.text);
    final base = int.tryParse(_starBaseCtrl.text);
    final coeff = double.tryParse(_starCoeffCtrl.text);
    if (div == null || base == null || coeff == null) return;
    if (div < 0 || div > 100 || base < 0 || base > 100 || coeff < 0 || coeff > 100) return;
    final updated = s.copyWith(divisions: div, starBase: base, starCoeff: coeff);
    await AppDatabase.updateStrategy(updated);
    setState(() { _strategy = updated; _editingConsts = false; });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('전략 상수 저장됨'), duration: Duration(seconds: 1)),
      );
    }
  }

  Future<void> _saveV1Consts() async {
    final div = int.tryParse(_divCtrl.text);
    final profit = double.tryParse(_v1ProfitCtrl.text);
    final salsaTp = double.tryParse(_salsaTpCtrl.text);
    final salsaSl = double.tryParse(_salsaSlCtrl.text);
    if (div == null || profit == null) return;
    final updated = s.copyWith(
      divisions: div,
      v1Value: profit,
      v1SalsaTpPct: salsaTp,
      v1SalsaSlPct: salsaSl,
    );
    await AppDatabase.updateStrategy(updated);
    setState(() { _strategy = updated; _editingV1Consts = false; });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('V1 설정 저장됨'), duration: Duration(seconds: 1)),
      );
    }
  }

  Future<void> _saveCapital() async {
    if (_pendingCapital == null) return;
    final updated = s.copyWith(capital: _pendingCapital!);
    await AppDatabase.updateStrategy(updated);
    _capitalEditCtrl.text = _capStr(updated.capital);
    setState(() { _strategy = updated; _pendingCapital = null; });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('다음 사이클부터 반영됩니다'), duration: Duration(seconds: 2)),
    );
  }

  Future<void> _saveCalcCapital(double? value) async {
    final updated = s.copyWith(calcCapital: value);
    await AppDatabase.updateStrategy(updated);
    _calcCapitalEditCtrl.text = _capStr(value ?? updated.capital);
    setState(() { _strategy = updated; _pendingCalcCapital = null; });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(value == null ? '계산전용원금 해제됨 (할당금액 사용)' : '계산전용원금 저장됨'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _execute() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('주문 실행'),
        content: Text(
          '${_isOpen ? '지금 바로' : _nextOpen()} 시장가로 주문을 실행합니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFF85149)),
            child: const Text('실행'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() { _executing = true; _lastExecTime = Fmt.datetime(DateTime.now()); });
    try {
      await ApiService.rebalance(s.strategyId);
      _startPolling();
    } catch (e) {
      setState(() { _executing = false; });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('실행 실패: ${e.toString().replaceFirst('Exception: ', '')}'),
              backgroundColor: const Color(0xFFF85149)),
        );
      }
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    int count = 0;
    _pollTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      count++;
      if (count >= 6) {
        _pollTimer?.cancel();
        if (mounted) setState(() { _executing = false; });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = MarketClock.elapsedDays(s.createdAt);
    final shares = (_holding?['shares'] as num? ?? 0).toDouble();
    final price = (_holding?['current_price'] as num? ?? 0).toDouble();
    final avg = (_holding?['avg_price'] as num? ?? 0).toDouble();
    final holdingValue = shares * price;
    final pnlPct = Calc.pnlPct(avg, price);
    final tDisplay = s.tValue?.toStringAsFixed(2) ?? '-';
    final tFull = s.tValue?.toStringAsFixed(10) ?? '-';
    final divisions = s.divisions ?? 20;
    final starBase = s.starBase ?? 20;
    final starCoeff = s.starCoeff ?? 2.0;
    final moneyFmt = s.market == 'KR'
        ? (double v) => Fmt.krw(v)
        : (double v) => Fmt.usd(v);

    // InfoGrid items: V4와 V1 공통 + 전략별 전용
    final gridItems = [
      _InfoItem('경과일', '$elapsed일'),
      _InfoItem('할당금액', moneyFmt(s.capital)),
      _InfoItem('종목', s.symbol),
      _InfoItem('보유',
          shares > 0 ? '${Fmt.shares(shares)} / ${moneyFmt(holdingValue)}' : '-'),
      _InfoItem('전략 현금', moneyFmt(_cash)),
      _InfoItem('사이클', '${s.cycleNo ?? 1}번'),
      _InfoItem('수익률', Fmt.pct(pnlPct),
          valueColor: pnlPct >= 0 ? const Color(0xFF2EA043) : const Color(0xFFF85149)),
      if (_isV4) ...[
        _InfoItem('T값', tDisplay),
        _InfoItem('분할 수', '$divisions분할'),
        _InfoItem('별지점 식', '$starBase - ${starCoeff.toStringAsFixed(1)}T'),
      ],
      if (!_isV4) ...[
        _InfoItem('분할 수', '$divisions분할'),
        _InfoItem('익절 %', '${s.v1Value?.toStringAsFixed(1) ?? '5.0'}%'),
      ],
    ];

    return PopScope(
      canPop: !_hasUnsavedChanges,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final leave = await _confirmDiscard();
        if (!mounted) return;
        if (leave == true) Navigator.of(context).pop();
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(s.strategyId),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadAccount),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20, color: Color(0xFFF85149)),
            onPressed: _delete,
          ),
        ],
      ),
      body: Column(children: [
        // 실행중 배너
        if (_executing)
          Container(
            width: double.infinity,
            color: const Color(0xFF1F6FEB),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            child: Row(children: [
              const SizedBox(width: 12, height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
              const SizedBox(width: 8),
              Text('반영중 · $_lastExecTime',
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
              const Spacer(),
              TextButton(
                onPressed: () { _pollTimer?.cancel(); setState(() { _executing = false; }); },
                child: const Text('완료', style: TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ]),
          ),

        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // 타입 배지
                    Row(children: [
                      _TypeBadge(s.typeLabel),
                      const SizedBox(width: 8),
                      _TypeBadge(s.market),
                      const Spacer(),
                      _StatusDot(active: s.active),
                    ]),
                    const SizedBox(height: 16),

                    // 핵심 정보 그리드
                    _InfoGrid(items: gridItems),
                    const SizedBox(height: 8),

                    // 할당 금액 조정
                    _buildCapitalCard(moneyFmt),
                    const SizedBox(height: 8),

                    // 매매 계획
                    _buildTradingPlan(moneyFmt),
                    const SizedBox(height: 8),

                    // V4 전용: T값 전체 표시
                    if (_isV4) ...[
                      _Card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('T값 (전체)',
                            style: TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
                        const SizedBox(height: 4),
                        Text(tFull,
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                      ])),
                      const SizedBox(height: 12),

                      // T값 수정
                      _Card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          const Text('T값 수정',
                              style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
                          TextButton(
                            onPressed: () {
                              if (!_editingT) _tCtrl.text = s.tValue?.toStringAsFixed(10) ?? '0';
                              setState(() { _editingT = !_editingT; });
                            },
                            child: Text(_editingT ? '취소' : '수정',
                                style: const TextStyle(fontSize: 12)),
                          ),
                        ]),
                        if (_editingT) ...[
                          TextField(
                            controller: _tCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: _inputDeco('T값 입력 (소수점 10자리)'),
                            onChanged: (_) => setState(() {}),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(width: double.infinity,
                            child: ElevatedButton(onPressed: _saveT, child: const Text('저장'))),
                        ],
                      ])),
                      const SizedBox(height: 12),

                      // 전략 상수 수정
                      _Card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          const Text('전략 상수 수정',
                              style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
                          TextButton(
                            onPressed: () => setState(() { _editingConsts = !_editingConsts; }),
                            child: Text(_editingConsts ? '취소' : '수정',
                                style: const TextStyle(fontSize: 12)),
                          ),
                        ]),
                        if (_editingConsts) ...[
                          const SizedBox(height: 8),
                          Row(children: [
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const Text('분할 수 (0~100)',
                                  style: TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
                              const SizedBox(height: 4),
                              TextField(controller: _divCtrl,
                                  keyboardType: TextInputType.number,
                                  decoration: _inputDeco('기본 20')),
                            ])),
                            const SizedBox(width: 12),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const Text('별지점 상수 (0~100)',
                                  style: TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
                              const SizedBox(height: 4),
                              TextField(controller: _starBaseCtrl,
                                  keyboardType: TextInputType.number,
                                  onChanged: (_) => setState(() {}),
                                  decoration: _inputDeco('기본 20')),
                            ])),
                            const SizedBox(width: 12),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const Text('별지점 계수 (0~100, 소수점 1자리)',
                                  style: TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
                              const SizedBox(height: 4),
                              TextField(controller: _starCoeffCtrl,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  onChanged: (_) => setState(() {}),
                                  decoration: _inputDeco('기본 2.0')),
                            ])),
                          ]),
                          const SizedBox(height: 6),
                          Text(
                            '별지점 식: ${_starBaseCtrl.text.isEmpty ? '20' : _starBaseCtrl.text} - ${_starCoeffCtrl.text.isEmpty ? '2.0' : _starCoeffCtrl.text}T',
                            style: const TextStyle(color: Color(0xFF58A6FF), fontSize: 11),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(width: double.infinity,
                            child: ElevatedButton(onPressed: _saveConsts, child: const Text('저장'))),
                        ],
                      ])),
                      const SizedBox(height: 12),
                    ],

                    // V1 전용: 설정 수정
                    if (!_isV4) ...[
                      _Card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          const Text('V1 설정 수정',
                              style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
                          TextButton(
                            onPressed: () => setState(() { _editingV1Consts = !_editingV1Consts; }),
                            child: Text(_editingV1Consts ? '취소' : '수정',
                                style: const TextStyle(fontSize: 12)),
                          ),
                        ]),
                        if (_editingV1Consts) ...[
                          const SizedBox(height: 8),
                          Row(children: [
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const Text('분할 수',
                                  style: TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
                              const SizedBox(height: 4),
                              TextField(controller: _divCtrl,
                                  keyboardType: TextInputType.number,
                                  decoration: _inputDeco('기본 10')),
                            ])),
                            const SizedBox(width: 12),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const Text('익절 %',
                                  style: TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
                              const SizedBox(height: 4),
                              TextField(controller: _v1ProfitCtrl,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  decoration: _inputDeco('기본 5.0')),
                            ])),
                          ]),
                          const SizedBox(height: 8),
                          const Text('살자법 상수',
                              style: TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
                          const SizedBox(height: 6),
                          Row(children: [
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const Text('장중 익절 % (살자법)',
                                  style: TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
                              const SizedBox(height: 4),
                              TextField(controller: _salsaTpCtrl,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  decoration: _inputDeco('기본 5.0')),
                            ])),
                            const SizedBox(width: 12),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const Text('장중 손절 % (살자법)',
                                  style: TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
                              const SizedBox(height: 4),
                              TextField(controller: _salsaSlCtrl,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  decoration: _inputDeco('기본 10.0')),
                            ])),
                          ]),
                          const SizedBox(height: 8),
                          SizedBox(width: double.infinity,
                            child: ElevatedButton(onPressed: _saveV1Consts, child: const Text('저장'))),
                        ],
                      ])),
                      const SizedBox(height: 12),
                    ],

                    // 주문 실행 버튼
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _executing ? null : _execute,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFB91C1C),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: Text(
                          _executing
                              ? '반영중...'
                              : _isOpen
                                  ? '주문 실행 (시장가)'
                                  : '주문 실행 (${_nextOpen()})',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ]),
      ),
    );
  }
  Widget _buildCapitalCard(String Function(double) moneyFmt) {
    final capChanged = _pendingCapital != null && (_pendingCapital! - s.capital).abs() > 0.01;
    final calcBase = s.calcCapital ?? s.capital;
    final calcChanged = _pendingCalcCapital != null && (_pendingCalcCapital! - calcBase).abs() > 0.01;
    final calcIsSet = s.calcCapital != null;
    final isKr = s.market == 'KR';
    final suffix = isKr ? '원' : '\$';

    InputDecoration inputDeco(bool changed) => InputDecoration(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      filled: true,
      fillColor: const Color(0xFF0D1117),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: changed ? const Color(0xFF58A6FF) : const Color(0xFF30363D)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: changed ? const Color(0xFF58A6FF) : const Color(0xFF30363D)),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
        borderSide: BorderSide(color: Color(0xFF58A6FF)),
      ),
      suffixText: suffix,
      suffixStyle: const TextStyle(color: Color(0xFF8B949E), fontSize: 12),
    );

    Row btnRow(VoidCallback onCancel, VoidCallback onSave) => Row(children: [
      Expanded(child: OutlinedButton(
        onPressed: onCancel,
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF8B949E),
          side: const BorderSide(color: Color(0xFF30363D)),
          padding: const EdgeInsets.symmetric(vertical: 4),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: const Text('취소', style: TextStyle(fontSize: 11)),
      )),
      const SizedBox(width: 4),
      Expanded(child: ElevatedButton(
        onPressed: onSave,
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 4),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: const Text('저장', style: TextStyle(fontSize: 11)),
      )),
    ]);

    return _Card(child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 할당 금액 ──
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('할당 금액', style: TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
          const SizedBox(height: 6),
          TextField(
            controller: _capitalEditCtrl,
            keyboardType: TextInputType.numberWithOptions(decimal: !isKr),
            style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600,
              color: capChanged ? const Color(0xFF58A6FF) : Colors.white,
            ),
            decoration: inputDeco(capChanged),
            onChanged: (v) {
              final parsed = double.tryParse(v.replaceAll(',', ''));
              setState(() {
                _pendingCapital = (parsed != null && parsed > 0 && (parsed - s.capital).abs() > 0.01)
                    ? parsed : null;
              });
            },
          ),
          if (capChanged) ...[
            const SizedBox(height: 6),
            btnRow(
              () {
                _capitalEditCtrl.text = _capStr(s.capital);
                setState(() { _pendingCapital = null; });
              },
              _saveCapital,
            ),
          ],
        ])),

        // ── 구분선 ──
        Container(
          width: 1,
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          color: const Color(0xFF30363D),
        ),

        // ── 계산전용원금 ──
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('계산전용원금', style: TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
            if (calcIsSet && !calcChanged)
              GestureDetector(
                onTap: () => _saveCalcCapital(null),
                child: const Icon(Icons.close, size: 14, color: Color(0xFF6E7681)),
              ),
          ]),
          const SizedBox(height: 6),
          TextField(
            controller: _calcCapitalEditCtrl,
            keyboardType: TextInputType.numberWithOptions(decimal: !isKr),
            style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600,
              color: calcChanged
                  ? const Color(0xFF58A6FF)
                  : calcIsSet ? Colors.white : const Color(0xFF6E7681),
            ),
            decoration: inputDeco(calcChanged).copyWith(
              hintText: calcIsSet ? null : '미설정',
              hintStyle: const TextStyle(color: Color(0xFF6E7681), fontSize: 12),
            ),
            onChanged: (v) {
              final parsed = double.tryParse(v.replaceAll(',', ''));
              setState(() {
                _pendingCalcCapital = (parsed != null && parsed > 0 && (parsed - calcBase).abs() > 0.01)
                    ? parsed : null;
              });
            },
          ),
          if (!calcIsSet && !calcChanged)
            const Padding(
              padding: EdgeInsets.only(top: 3),
              child: Text('미설정 시 할당금액 사용',
                  style: TextStyle(color: Color(0xFF6E7681), fontSize: 9)),
            ),
          if (calcChanged) ...[
            const SizedBox(height: 6),
            btnRow(
              () {
                _calcCapitalEditCtrl.text = _capStr(calcBase);
                setState(() { _pendingCalcCapital = null; });
              },
              () => _saveCalcCapital(_pendingCalcCapital),
            ),
          ],
        ])),
      ],
    ));
  }

  Widget _buildTradingPlan(String Function(double) moneyFmt) {
    final price = (_holding?['current_price'] as num? ?? 0).toDouble();
    final avg = (_holding?['avg_price'] as num? ?? 0).toDouble();
    final holdingShares = (_holding?['shares'] as num? ?? 0).toDouble();
    final divisions = s.divisions ?? (_isV4 ? 20 : 10);
    final calcBase = s.calcCapital ?? s.capital;
    final divAmount = calcBase / divisions;  // V1 폴백용

    Widget content;

    if (_isV4) {
      // 편집 중이면 입력 중인 값으로 실시간 미리보기
      final tVal = _editingT
          ? (double.tryParse(_tCtrl.text) ?? s.tValue ?? 0.0)
          : (s.tValue ?? 0.0);
      final starBase = (_editingConsts
          ? (double.tryParse(_starBaseCtrl.text) ?? (s.starBase ?? 20).toDouble())
          : (s.starBase ?? 20).toDouble());
      final starCoeff = _editingConsts
          ? (double.tryParse(_starCoeffCtrl.text) ?? s.starCoeff ?? 2.0)
          : (s.starCoeff ?? 2.0);
      final starPct = (starBase - starCoeff * tVal) / 100.0;
      // avg는 API가 반환한 값이므로 커미션 환원 (v4_soxl.py 방식)
      final avgCost = avg > 0 ? avg / (1 - 0.0025) : 0.0;
      final starPriceCost = avgCost > 0 ? avgCost * (1 + starPct) : 0.0;
      final buyPoint = starPriceCost > 0 ? starPriceCost - 0.01 : 0.0;

      // 서버 mm_mode 우선; 미로드 시 T값으로 근사
      final isReverse = _serverStateLoaded
          ? _serverMmMode == 'reverse'
          : tVal >= divisions - 1;
      final isRearHalf = !isReverse && tVal >= divisions * 0.5;
      final modeLabel = isReverse ? '리버스 모드' : (isRearHalf ? '후반전' : '전반전');

      // 포션 = 잔여현금 / (divisions - T) — v4_soxl.py 방식
      final divisor = math.max(divisions - tVal, 1.0);
      final portionAmount = _cash > 0 ? _cash / divisor : divAmount;
      final halfPortion = portionAmount * 0.5;

      final usePrice = buyPoint > 0 ? buyPoint : price;
      final buyShares1 = usePrice > 0 ? math.max((halfPortion / usePrice).floor(), 1) : 0;
      final buyShares2 = avgCost > 0 ? math.max((halfPortion / avgCost).floor(), 1) : 0;
      final rearBuyShares = usePrice > 0 ? math.max((portionAmount / usePrice).floor(), 1) : 0;

      // 폭락대비 가격 범위 (최대 30% 하락까지)
      final crashRangeMin = buyPoint > 0 ? buyPoint * 0.70 : 0.0;
      final isUs = s.market == 'US';

      content = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 전략 상태
        _PRow('T 값', tVal.toStringAsFixed(4)),
        _PRow('단계', modeLabel,
            color: isReverse ? const Color(0xFFF85149) : isRearHalf ? const Color(0xFFE3B341) : const Color(0xFF58A6FF)),
        _PRow('별지점 식', '${starBase.toInt()} - ${starCoeff.toStringAsFixed(1)}T = ${(starPct * 100).toStringAsFixed(2)}%'),
        if (starPriceCost > 0) ...[
          _PRow('별지점 가격', moneyFmt(starPriceCost), color: const Color(0xFF58A6FF)),
          _PRow('매수점 (별지점-0.01)', moneyFmt(buyPoint)),
        ],

        // ── 리버스 모드 ──────────────────────────
        if (isReverse) ...[
          const Divider(color: Color(0xFF30363D), height: 16),
          _SectionLabel('🔀 리버스 모드', color: const Color(0xFFF85149)),
          const SizedBox(height: 4),
          const Text(
            '5MA 기반 매도·매수 | 종가 ≥ 평단×80% 시 일반모드 복귀',
            style: TextStyle(color: Color(0xFF8B949E), fontSize: 11),
          ),
          const SizedBox(height: 4),
          if (_serverStateLoaded && _serverReverseDay > 0)
            _PRow('현재 리버스 일차', '${_serverReverseDay}일차',
                color: const Color(0xFFE3B341)),
          if (holdingShares > 0) ...[
            if (!_serverStateLoaded || _serverReverseDay <= 1)
              _PRow('1일차 매도 (MOC 시장가)',
                  '${math.max((holdingShares * 0.10).floor(), 1)} 주 (보유×10%)'),
            if (!_serverStateLoaded || _serverReverseDay >= 2) ...[
              _PRow('2일차~ 매도 (LOC @5MA)',
                  '${math.max((holdingShares * 0.10).floor(), 1)} 주'),
              if (_cash > 0)
                _PRow('2일차~ 매수 (LOC @5MA-0.01)', '잔금 ${moneyFmt(_cash / 4)} 으로 매수'),
            ],
          ],
          _PRow('복귀 조건', '종가 ≥ ${moneyFmt(avgCost * 0.80)} (평단×80%)'),
        ],

        // ── 일반 모드 매수 계획 ──────────────────
        if (!isReverse) ...[
          const Divider(color: Color(0xFF30363D), height: 16),
          _PRow('1회 포션 (잔금${_cash > 0 ? '' : '/분할수'})', moneyFmt(portionAmount)),
          if (price > 0) ...[
            if (!isRearHalf) ...[
              _PRow('전반전 별지점 LOC (0.5포션)', '$buyShares1 주 × ${moneyFmt(buyPoint)}'),
              _PRow('전반전 평단가 LOC (0.5포션)', '$buyShares2 주 × ${avgCost > 0 ? moneyFmt(avgCost) : '-'}'),
            ] else
              _PRow('후반전 별지점 LOC (1포션)', '$rearBuyShares 주 × ${moneyFmt(buyPoint)}'),
          ],

          // ── 폭락방지 매수 (US 전략만) ───────────
          if (isUs && buyPoint > 0) ...[
            const Divider(color: Color(0xFF30363D), height: 12),
            _SectionLabel('⚡ 폭락방지 LOC', color: const Color(0xFFE3B341)),
            const SizedBox(height: 4),
            const Text(
              '별지점 매수 시 자동 추가 — 종가 폭락 시 추가 체결로 포션 보전',
              style: TextStyle(color: Color(0xFF8B949E), fontSize: 11),
            ),
            const SizedBox(height: 4),
            _PRow('기준 매수점', moneyFmt(buyPoint)),
            _PRow('최저 가격 (-30%)', moneyFmt(crashRangeMin)),
            _PRow('최대 추가 주문', '20건 (1주씩)'),
            _PRow('주문 방식', 'LOC (서버 실행 시 자동 계산)'),
          ],
        ],

        // ── 매도 계획 ────────────────────────────
        if (!isReverse && holdingShares > 0 && avgCost > 0 && starPriceCost > 0) ...[
          const Divider(color: Color(0xFF30363D), height: 16),
          _SectionLabel('매도 계획', color: const Color(0xFF8B949E)),
          const SizedBox(height: 4),
          _PRow('쿼터매도 LOC @별지점',
              '${math.max((holdingShares * 0.25).floor(), 1)} 주 × ${moneyFmt(starPriceCost)}'),
          _PRow('최종매도 지정가 @평단×1.20',
              '${math.max(holdingShares.toInt() - math.max((holdingShares * 0.25).floor(), 1), 0)} 주 × ${moneyFmt(avgCost * 1.20)}'),
        ],

        const Divider(color: Color(0xFF30363D), height: 16),
        _PRow('주문 방식', isUs ? 'LOC ord_dvsn=34 (Limit on Close)' : 'LOC 조건부 시장가'),
      ]);
    } else {
      // V1
      final profitPct = s.v1Value ?? 5.0;
      final salsaTpPct = s.v1SalsaTpPct ?? 5.0;
      final salsaSlPct = s.v1SalsaSlPct ?? 10.0;

      if (holdingShares > 0 && avg > 0) {
        final targetPrice = avg * (1 + profitPct / 100);
        final salsaTpPrice = avg * (1 + salsaTpPct / 100);
        final salsaSlPrice = avg * (1 - salsaSlPct / 100);
        final currentPct = price > 0 ? (price - avg) / avg * 100 : 0.0;
        final atTarget = price > 0 && price >= targetPrice;
        final remaining = profitPct - currentPct;
        // 후속 분할매수: 0.5포션 ×평단가 + 0.5포션 ×(평단가-0.01)
        final half = divAmount * 0.5;
        final bq1 = math.max((half / avg).floor(), 1);
        final capPrice = avg - 0.01;
        final bq2 = capPrice > 0 ? math.max((half / capPrice).floor(), 1) : 0;

        content = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // 현재 보유 현황
          _PRow('보유 수량', '${holdingShares.toInt()} 주'),
          _PRow('평균 매수가', moneyFmt(avg)),
          if (price > 0) ...[
            _PRow('현재가', moneyFmt(price)),
            _PRow('평가 수익률', '${currentPct.toStringAsFixed(2)}%',
                color: currentPct >= 0 ? const Color(0xFF2EA043) : const Color(0xFFF85149)),
          ],
          const Divider(color: Color(0xFF30363D), height: 16),
          // 익절 계획
          _PRow('익절 목표 수익률', '+${profitPct.toStringAsFixed(1)}%'),
          _PRow('익절 목표가', moneyFmt(targetPrice),
              color: const Color(0xFFF85149)),
          if (atTarget) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFF85149).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFF85149).withValues(alpha: 0.4)),
              ),
              child: Row(children: [
                const Icon(Icons.sell_outlined, size: 14, color: Color(0xFFF85149)),
                const SizedBox(width: 6),
                Text('익절 조건 충족 — ${holdingShares.toInt()}주 시장가 매도',
                    style: const TextStyle(color: Color(0xFFF85149), fontSize: 12, fontWeight: FontWeight.w600)),
              ]),
            ),
          ] else ...[
            _PRow('남은 상승폭', '+${remaining.toStringAsFixed(2)}%'),
          ],
          const Divider(color: Color(0xFF30363D), height: 16),
          // 후속 분할매수 계획
          _PRow('후속 분할매수', '계산원금 ÷ $divisions분할 × 0.5'),
          _PRow('① 평단가 LOC', '$bq1 주 × ${moneyFmt(avg)}',
              color: const Color(0xFF58A6FF)),
          if (bq2 > 0)
            _PRow('② 평단-0.01 LOC', '$bq2 주 × ${moneyFmt(capPrice)}',
                color: const Color(0xFF58A6FF)),
          const Divider(color: Color(0xFF30363D), height: 16),
          // 살자법 상수
          const Text('살자법 장중 대응',
              style: TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
          const SizedBox(height: 4),
          _PRow('장중 익절 (+${salsaTpPct.toStringAsFixed(1)}%)', moneyFmt(salsaTpPrice),
              color: const Color(0xFF2EA043)),
          _PRow('장중 손절 (-${salsaSlPct.toStringAsFixed(1)}%)', moneyFmt(salsaSlPrice),
              color: const Color(0xFFF85149)),
        ]);
      } else {
        // 미보유 → 신규 매수 계획
        final buyShares = price > 0 ? math.max((divAmount / price).floor(), 1) : 0;
        content = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _PRow('계산원금 ÷ $divisions분할', moneyFmt(divAmount)),
          if (price > 0) ...[
            _PRow('현재가', moneyFmt(price)),
            _PRow('예상 매수 수량', '$buyShares 주'),
            _PRow('예상 매수 금액', moneyFmt(buyShares * price)),
          ] else
            const Text('현재가 조회 필요',
                style: TextStyle(color: Color(0xFF6E7681), fontSize: 12)),
          const Divider(color: Color(0xFF30363D), height: 16),
          _PRow('익절 목표', '+${profitPct.toStringAsFixed(1)}%'),
          _PRow('주문 방식', 'LOC (Limit on Close)'),
        ]);
      }
    }

    return _Card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('매매 계획', style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
      const SizedBox(height: 10),
      content,
    ]));
  }
}

class _PRow extends StatelessWidget {
  final String label, value;
  final Color? color;
  const _PRow(this.label, this.value, {this.color});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          Text(label, style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
          const Spacer(),
          Text(value, style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w500,
            color: color ?? const Color(0xFFE6EDF3),
          )),
        ]),
      );
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final Color? color;
  const _SectionLabel(this.label, {this.color});
  @override
  Widget build(BuildContext context) => Text(
        label,
        style: TextStyle(
          color: color ?? const Color(0xFF8B949E),
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      );
}

InputDecoration _inputDeco(String hint) => InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF8B949E)),
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

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: child,
      );
}

class _InfoGrid extends StatelessWidget {
  final List<_InfoItem> items;
  const _InfoGrid({required this.items});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: Wrap(
          spacing: 0, runSpacing: 10,
          children: items.map((item) => SizedBox(
            width: MediaQuery.of(context).size.width / 2 - 28,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.label, style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
              const SizedBox(height: 2),
              Text(item.value, style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w500,
                color: item.valueColor ?? const Color(0xFFE6EDF3),
              )),
            ]),
          )).toList(),
        ),
      );
}

class _InfoItem {
  final String label, value;
  final Color? valueColor;
  const _InfoItem(this.label, this.value, {this.valueColor});
}

class _TypeBadge extends StatelessWidget {
  final String label;
  const _TypeBadge(this.label);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFF1F6FEB22),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label, style: const TextStyle(color: Color(0xFF58A6FF), fontSize: 11)),
      );
}

class _StatusDot extends StatelessWidget {
  final bool active;
  const _StatusDot({required this.active});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8,
          decoration: BoxDecoration(
            color: active ? const Color(0xFF2EA043) : const Color(0xFF6E7681),
            shape: BoxShape.circle,
          )),
        const SizedBox(width: 4),
        Text(active ? '활성' : '비활성',
            style: TextStyle(
              color: active ? const Color(0xFF2EA043) : const Color(0xFF6E7681),
              fontSize: 11,
            )),
      ]);
}
