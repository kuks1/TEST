import 'dart:math';
import 'package:flutter/material.dart';
import '../../core/api_service.dart';
import '../../core/common.dart';
import '../../core/database.dart';
import '../../models/strategy.dart';

// ─── VR 전략 계산 로직 (v_vr_1.py 포트) ────────────────────────────────────

int _defaultG(String mode) {
  switch (mode) {
    case '거치식': return 12;
    case '인출식': return 20;
    default: return 10; // 적립식
  }
}

double _calcG(String mode, int weekNo) {
  switch (mode) {
    case '인출식': return 20;
    case '거치식': return 12;
    default: // 적립식: 10 + 연차
      return (10 + weekNo ~/ 52).toDouble();
  }
}

double _calcPoolLimit(String mode, int weekNo, double? override) {
  if (override != null) return override.clamp(0.0, 1.0);
  switch (mode) {
    case '거치식': return 0.50;
    case '인출식': return 0.75;
    default: // 적립식
      if (weekNo < 52) return 0.0;
      final halfYears = (weekNo - 52) ~/ 26;
      return (0.75 - halfYears * 0.05).clamp(0.0, 1.0);
  }
}

double _calcV2(double v1, double pool, double g, double equity, double cf) {
  if (g <= 0) return v1;
  return v1 + (pool / g) + (equity - v1) / (2.0 * sqrt(g)) + cf;
}

class _GridOrder {
  final String side;
  final int quantity;
  final double price;
  final int level;
  _GridOrder({required this.side, required this.quantity, required this.price, required this.level});
}

// 매수: V_min ÷ (보유수량 + n×qty) 가격에 qty주씩, Pool 한도 초과 직전까지
List<_GridOrder> _buildBuyGrid(double vMin, int currentShares, int qty, double poolAvail) {
  final orders = <_GridOrder>[];
  if (vMin <= 0 || qty <= 0 || poolAvail <= 0) return orders;
  double totalCost = 0;
  for (int step = 1; step <= 500; step++) {
    final newShares = currentShares + step * qty;
    final price = vMin / newShares;
    if (price <= 0) break;
    final cost = price * qty;
    if (totalCost + cost > poolAvail) break;
    orders.add(_GridOrder(side: 'BUY', quantity: qty, price: price, level: step));
    totalCost += cost;
  }
  return orders;
}

// 매도: V_max ÷ (보유수량 - n×qty) 가격에 qty주씩, 보유수량 소진 직전까지
List<_GridOrder> _buildSellGrid(double vMax, int currentShares, int qty) {
  final orders = <_GridOrder>[];
  if (vMax <= 0 || currentShares <= 0 || qty <= 0) return orders;
  for (int step = 1; step <= 500; step++) {
    final remainShares = currentShares - step * qty;
    if (remainShares <= 0) break;
    final price = vMax / remainShares;
    if (price <= 0) break;
    orders.add(_GridOrder(side: 'SELL', quantity: qty, price: price, level: step));
  }
  return orders;
}

// ─── Screen ─────────────────────────────────────────────────────────────────

class VrDetailScreen extends StatefulWidget {
  final Strategy strategy;
  const VrDetailScreen({super.key, required this.strategy});

  @override
  State<VrDetailScreen> createState() => _VrDetailScreenState();
}

class _VrDetailScreenState extends State<VrDetailScreen> {
  late Strategy _strategy;

  // 계좌 데이터
  bool _loadingAccount = false;
  double _currentPrice = 0;
  int _shares = 0;
  double _avgPrice = 0;
  String? _tickerName;

  // 자본 편집
  final _capitalCtrl = TextEditingController();
  double? _pendingCapital;

  // VR 파라미터 편집
  final _bandCtrl = TextEditingController();
  final _poolPctCtrl = TextEditingController();
  final _depositCtrl = TextEditingController();
  final _withdrawalCtrl = TextEditingController();
  final _gCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController();
  bool _pendingParams = false;
  bool _gPromptShown = false;

  bool get _hasUnsavedChanges => _pendingCapital != null || _pendingParams;

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
  bool get _isKr => s.market == 'KR';

  String _defaultPoolPctStr(String mode) {
    switch (mode) {
      case '거치식': return '50';
      case '인출식': return '25';
      default: return '75'; // 적립식
    }
  }

  @override
  void initState() {
    super.initState();
    _strategy = widget.strategy;
    _capitalCtrl.text = _capStr(s.capital);
    _bandCtrl.text = (s.vrEffectiveBand * 100).toStringAsFixed(1);
    _poolPctCtrl.text = s.vrPoolPct != null
        ? (s.vrPoolPct! * 100).toStringAsFixed(0)
        : _defaultPoolPctStr(s.vrMode ?? '적립식');
    _depositCtrl.text = s.vrEffectiveDeposit.toStringAsFixed(2);
    _withdrawalCtrl.text = s.vrEffectiveWithdrawal.toStringAsFixed(2);
    _gCtrl.text = (s.vrG ?? _defaultG(s.vrMode ?? '적립식')).toString();
    _qtyCtrl.text = (s.vrQtyPerStep ?? 1).toString();
    _loadAccount();
  }

  @override
  void dispose() {
    _capitalCtrl.dispose();
    _bandCtrl.dispose();
    _poolPctCtrl.dispose();
    _depositCtrl.dispose();
    _withdrawalCtrl.dispose();
    _gCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  String _capStr(double v) => _isKr ? v.toInt().toString() : v.toStringAsFixed(2);

  Future<void> _loadAccount() async {
    if (s.symbol.isEmpty) return;
    setState(() { _loadingAccount = true; });
    try {
      final data = await ApiService.getAccount();
      final key = _isKr ? 'kr' : 'us';
      final accounts = (data[key] as List? ?? []);
      int shares = 0;
      double currentPrice = 0;
      double avgPrice = 0;
      for (final acc in accounts) {
        for (final h in (acc['holdings'] as List? ?? [])) {
          if (h['ticker'] == s.symbol) {
            shares += (h['shares'] as num? ?? 0).toInt();
            currentPrice = (h['current_price'] as num? ?? 0).toDouble();
            avgPrice = (h['avg_price'] as num? ?? 0).toDouble();
            _tickerName = h['name'] as String?;
          }
        }
      }
      if (currentPrice == 0 && s.symbol.isNotEmpty) {
        try {
          final q = await ApiService.getQuote(s.symbol, s.market);
          currentPrice = (q['price'] as num? ?? q['current_price'] as num? ?? 0).toDouble();
          _tickerName ??= q['name'] as String?;
        } catch (_) {}
      }
      setState(() {
        _currentPrice = currentPrice;
        _shares = shares;
        _avgPrice = avgPrice;
        _loadingAccount = false;
      });
      _checkGValuePrompt();
      _checkAndRecordVValue();
    } catch (_) {
      setState(() { _loadingAccount = false; });
    }
  }

  void _checkGValuePrompt() {
    if (_gPromptShown) return;
    final elapsedDays = DateTime.now().difference(s.createdAt).inDays;
    if (elapsedDays < 365) return;
    _gPromptShown = true;
    final years = elapsedDays ~/ 365;
    final currentG = s.vrG ?? _defaultG(_mode);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF161B22),
          title: const Text('G값 조정 제안'),
          content: Text(
            '전략 생성 후 ${years}년이 경과했습니다.\n'
            '현재 G값: $currentG\n\n'
            'G값을 ${currentG + 1}로 올리시겠습니까?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('유지'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                final updated = s.copyWith(vrG: currentG + 1);
                await AppDatabase.updateStrategy(updated);
                _gCtrl.text = (currentG + 1).toString();
                setState(() { _strategy = updated; });
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('G값이 ${currentG + 1}로 변경됐습니다'),
                      duration: const Duration(seconds: 2)));
              },
              style: TextButton.styleFrom(foregroundColor: const Color(0xFF58A6FF)),
              child: Text('+1 (${currentG + 1}로 변경)'),
            ),
          ],
        ),
      );
    });
  }

  Future<void> _saveCapital() async {
    if (_pendingCapital == null) return;
    final updated = s.copyWith(capital: _pendingCapital!);
    await AppDatabase.updateStrategy(updated);
    _capitalCtrl.text = _capStr(updated.capital);
    setState(() { _strategy = updated; _pendingCapital = null; });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('할당금액 저장됨'), duration: Duration(seconds: 2)));
  }

  Future<void> _saveParams() async {
    final bandVal = double.tryParse(_bandCtrl.text);
    final poolVal = double.tryParse(_poolPctCtrl.text.trim());
    final depositVal = double.tryParse(_depositCtrl.text);
    final withdrawalVal = double.tryParse(_withdrawalCtrl.text);
    final gVal = int.tryParse(_gCtrl.text.trim()) ?? _defaultG(_mode);
    final qtyVal = int.tryParse(_qtyCtrl.text) ?? 1;

    if (bandVal == null || bandVal <= 0 || bandVal >= 100) {
      _showError('밴드값 오류 (1~99 사이 입력)'); return;
    }
    if (gVal <= 0) {
      _showError('G값은 1 이상이어야 합니다'); return;
    }
    if (qtyVal <= 0) {
      _showError('수량은 1 이상이어야 합니다'); return;
    }

    final updated = s.copyWith(
      vrBand: bandVal / 100,
      vrDeposit: depositVal,
      vrWithdrawal: withdrawalVal,
      vrPoolPct: poolVal == null ? null : poolVal / 100,
      vrG: gVal,
      vrQtyPerStep: qtyVal,
    );
    await AppDatabase.updateStrategy(updated);
    setState(() { _strategy = updated; _pendingParams = false; });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('파라미터 저장됨'), duration: Duration(seconds: 2)));
  }

  Future<void> _saveMode(String mode) async {
    final updated = s.copyWith(vrMode: mode);
    await AppDatabase.updateStrategy(updated);
    if (updated.vrPoolPct == null) {
      _poolPctCtrl.text = _defaultPoolPctStr(mode);
    }
    // vrG가 저장된 값이 없으면 새 모드 기본값으로 갱신
    if (updated.vrG == null) {
      _gCtrl.text = _defaultG(mode).toString();
    }
    setState(() { _strategy = updated; });
  }

  Future<void> _delete() async {
    if (!mounted) return;
    final hasHolding = _shares > 0 && s.symbol.isNotEmpty;

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
          'name': _tickerName ?? s.symbol,
          'market': s.market,
          'quantity': _shares.toDouble(),
          'avg_price': _avgPrice,
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

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: const Color(0xFFF85149)));
  }

  // ─── 2주/4주 V값 자동 기록 ───────────────────────────────────
  Future<void> _checkAndRecordVValue() async {
    if (_shares <= 0 || _v1 <= 0) return;

    final now = DateTime.now();
    final lastRecord = await AppDatabase.getLastTradeLogByAction(
        s.strategyId, 'V값기록');

    bool shouldRecord = false;
    String periodLabel = '';

    if (lastRecord == null) {
      final stratAge = now.difference(s.createdAt).inDays;
      if (stratAge >= 28) {
        shouldRecord = true;
        periodLabel = '4주';
      } else if (stratAge >= 14) {
        shouldRecord = true;
        periodLabel = '2주';
      }
    } else {
      final lastDate =
          DateTime.tryParse(lastRecord['date'] as String? ?? '') ??
              DateTime(2000);
      final daysSince = now.difference(lastDate).inDays;
      if (daysSince >= 28) {
        shouldRecord = true;
        periodLabel = '4주';
      } else if (daysSince >= 14) {
        shouldRecord = true;
        periodLabel = '2주';
      }
    }

    if (!shouldRecord) return;

    final v2 = _v2;
    final evalAmount = _equity + _pool;
    final isKr = s.market == 'KR';
    final v2Str =
        isKr ? v2.toInt().toString() : v2.toStringAsFixed(2);
    final evalStr =
        isKr ? Fmt.krw(evalAmount) : Fmt.usd(evalAmount);

    await AppDatabase.insertLog({
      'strategy_id': s.strategyId,
      'date': now.toIso8601String().substring(0, 10),
      'event': '$periodLabel V값: $v2Str  평가금액: $evalStr',
      'action': 'V값기록',
      'quantity': _shares.toDouble(),
      'price': v2,
      'pnl_pct': evalAmount > 0 && s.capital > 0
          ? (evalAmount - s.capital) / s.capital * 100
          : 0.0,
      'created_at': now.toIso8601String(),
    });
  }

  // ─── VR 계산 ─────────────────────────────────────────────────

  double get _equity => _shares * _currentPrice;
  // Pool = 할당금액 - 매입원가 (평단가 기준)
  double get _pool => (s.capital - _shares * _avgPrice).clamp(0.0, s.capital);

  String get _mode => s.vrMode ?? '적립식';
  int get _weekNo => DateTime.now().difference(s.createdAt).inDays ~/ 7;
  double get _v1 => s.tValue ?? 0;
  double get _cumDeposit => s.cumDeposit ?? s.capital;

  // G: vrG override 우선, 없으면 자동 계산
  double get _g => (s.vrG != null && s.vrG! > 0) ? s.vrG!.toDouble() : _calcG(_mode, _weekNo);
  double get _poolLimit {
    double? override = s.vrPoolPct;
    if (override == null) {
      final v = double.tryParse(_poolPctCtrl.text.trim());
      override = v != null ? v / 100 : null;
    }
    return _calcPoolLimit(_mode, _weekNo, override);
  }
  int get _qtyPerStep => s.vrQtyPerStep ?? 1;

  bool get _isFirstCycle => _v1 == 0;

  // 시장가 매수 수량 (첫 사이클): 할당금액 / 현재가
  int get _marketBuyQty => _currentPrice > 0 ? (s.capital / _currentPrice).floor() : 0;

  double get _cashFlow {
    switch (_mode) {
      case '적립식': return s.vrEffectiveDeposit;
      case '인출식': return -s.vrEffectiveWithdrawal.abs();
      default: return 0;
    }
  }

  double get _v2 => _v1 > 0
      ? _calcV2(_v1, _pool, _g, _equity, _cashFlow)
      : _equity + _cashFlow;

  double get _band => s.vrEffectiveBand;
  double get _vMin => _v2 * (1 - _band);
  double get _vMax => _v2 * (1 + _band);

  // ─── Build ───────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
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
          IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _loadAccount),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20, color: Color(0xFFF85149)),
            onPressed: _delete,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _buildInfoCard(),
          const SizedBox(height: 10),
          _buildCapitalCard(),
          const SizedBox(height: 10),
          _buildModeCard(),
          const SizedBox(height: 10),
          _buildParamsCard(),
          const SizedBox(height: 10),
          _buildStatusCard(),
          const SizedBox(height: 10),
          _buildOrdersCard(),
        ],
      ),
      ),
    );
  }

  Widget _buildInfoCard() {
    return _Card(child: Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(s.symbol, style: const TextStyle(
            fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFFE6EDF3))),
        if (_tickerName != null)
          Text(_tickerName!, style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
      ])),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF1F6FEB).withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF1F6FEB).withValues(alpha: 0.4)),
        ),
        child: Text('VR · ${s.market}',
            style: const TextStyle(color: Color(0xFF58A6FF), fontSize: 11)),
      ),
    ]));
  }

  Widget _buildCapitalCard() {
    final changed = _pendingCapital != null && (_pendingCapital! - s.capital).abs() > 0.01;
    return _Card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('할당 금액', style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
      const SizedBox(height: 8),
      TextField(
        controller: _capitalCtrl,
        keyboardType: TextInputType.numberWithOptions(decimal: !_isKr),
        style: TextStyle(
          fontSize: 15, fontWeight: FontWeight.w700,
          color: changed ? const Color(0xFF58A6FF) : Colors.white,
        ),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          filled: true, fillColor: const Color(0xFF0D1117),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: changed ? const Color(0xFF58A6FF) : const Color(0xFF30363D))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: changed ? const Color(0xFF58A6FF) : const Color(0xFF30363D))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: Color(0xFF58A6FF))),
          suffixText: _isKr ? '원' : '\$',
          suffixStyle: const TextStyle(color: Color(0xFF8B949E), fontSize: 12),
        ),
        onChanged: (v) {
          final parsed = double.tryParse(v.replaceAll(',', ''));
          setState(() {
            _pendingCapital = (parsed != null && parsed > 0 && (parsed - s.capital).abs() > 0.01)
                ? parsed : null;
          });
        },
      ),
      if (changed) ...[
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: OutlinedButton(
            onPressed: () { _capitalCtrl.text = _capStr(s.capital); setState(() { _pendingCapital = null; }); },
            style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF8B949E),
                side: const BorderSide(color: Color(0xFF30363D))),
            child: const Text('취소'),
          )),
          const SizedBox(width: 8),
          Expanded(child: ElevatedButton(
            onPressed: _saveCapital,
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1F6FEB)),
            child: const Text('저장'),
          )),
        ]),
      ],
    ]));
  }

  Widget _buildModeCard() {
    return _Card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('운용 방식', style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
      const SizedBox(height: 10),
      Row(children: [
        for (final mode in ['적립식', '거치식', '인출식']) ...[
          Expanded(child: GestureDetector(
            onTap: () => _saveMode(mode),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: _mode == mode
                    ? const Color(0xFF1F6FEB)
                    : const Color(0xFF21262D),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _mode == mode ? const Color(0xFF1F6FEB) : const Color(0xFF30363D),
                ),
              ),
              child: Column(children: [
                Text(mode, style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600,
                  color: _mode == mode ? Colors.white : const Color(0xFF8B949E),
                )),
                Text(
                  mode == '적립식' ? '정기 적립' : mode == '거치식' ? '거치 운용' : '정기 인출',
                  style: TextStyle(fontSize: 10,
                      color: _mode == mode ? Colors.white70 : const Color(0xFF57606A)),
                ),
              ]),
            ),
          )),
          if (mode != '인출식') const SizedBox(width: 6),
        ],
      ]),
    ]));
  }

  Widget _buildParamsCard() {
    return _Card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('VR 파라미터', style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
        const Spacer(),
        if (_pendingParams)
          Row(children: [
            TextButton(
              onPressed: () {
                setState(() {
                  _bandCtrl.text = (s.vrEffectiveBand * 100).toStringAsFixed(1);
                  _poolPctCtrl.text = s.vrPoolPct != null ? (s.vrPoolPct! * 100).toStringAsFixed(0) : _defaultPoolPctStr(_mode);
                  _depositCtrl.text = s.vrEffectiveDeposit.toStringAsFixed(2);
                  _withdrawalCtrl.text = s.vrEffectiveWithdrawal.toStringAsFixed(2);
                  _gCtrl.text = (s.vrG ?? _defaultG(s.vrMode ?? '적립식')).toString();
                  _qtyCtrl.text = (s.vrQtyPerStep ?? 1).toString();
                  _pendingParams = false;
                });
              },
              style: TextButton.styleFrom(foregroundColor: const Color(0xFF8B949E),
                  padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: const Text('취소', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _saveParams,
              style: TextButton.styleFrom(foregroundColor: const Color(0xFF58A6FF),
                  padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: const Text('저장', style: TextStyle(fontSize: 12)),
            ),
          ]),
      ]),
      const SizedBox(height: 10),
      // 행 1: 밴드 + Pool 한도
      Row(children: [
        Expanded(child: _ParamField(
          label: '밴드',
          controller: _bandCtrl,
          suffix: '%',
          onChanged: (_) => setState(() { _pendingParams = true; }),
        )),
        const SizedBox(width: 8),
        Expanded(child: _ParamField(
          label: 'Pool 한도',
          controller: _poolPctCtrl,
          suffix: '%',
          onChanged: (_) => setState(() { _pendingParams = true; }),
        )),
      ]),
      const SizedBox(height: 8),
      // 행 2: G값 + 호가당 수량
      Row(children: [
        Expanded(child: _ParamField(
          label: 'G값',
          controller: _gCtrl,
          suffix: '',
          keyboardType: TextInputType.number,
          onChanged: (_) => setState(() { _pendingParams = true; }),
        )),
        const SizedBox(width: 8),
        Expanded(child: _ParamField(
          label: '호가당 수량',
          controller: _qtyCtrl,
          suffix: '주',
          keyboardType: TextInputType.number,
          onChanged: (_) => setState(() { _pendingParams = true; }),
        )),
      ]),
      if (_mode == '적립식') ...[
        const SizedBox(height: 8),
        _ParamField(
          label: '사이클당 입금액',
          controller: _depositCtrl,
          suffix: _isKr ? '원' : '\$',
          onChanged: (_) => setState(() { _pendingParams = true; }),
        ),
      ],
      if (_mode == '인출식') ...[
        const SizedBox(height: 8),
        _ParamField(
          label: '사이클당 인출액',
          controller: _withdrawalCtrl,
          suffix: _isKr ? '원' : '\$',
          onChanged: (_) => setState(() { _pendingParams = true; }),
        ),
      ],
    ]));
  }

  Widget _buildStatusCard() {
    final fmt = _isKr ? Fmt.krw : Fmt.usd;
    final totalAsset = _equity + _pool;
    String stage;
    final ratio = _cumDeposit > 0 ? totalAsset / _cumDeposit : 0;
    if (ratio >= 4000) { stage = '인출식'; }
    else if (ratio >= 260) { stage = '거치식'; }
    else { stage = '적립식'; }

    return _Card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('이번 사이클 현황', style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
        const Spacer(),
        if (_loadingAccount)
          const SizedBox(width: 12, height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8B949E))),
      ]),
      const SizedBox(height: 10),
      _Row('단계 (자동 판단)', stage),
      _Row('누적 적립', fmt(_cumDeposit)),
      const Divider(color: Color(0xFF30363D), height: 16),
      _Row('G 값', _g.toStringAsFixed(0)),
      _Row('V₁ (이전 V₂)', fmt(_v1)),
      _Row('V₂ (목표 가치)', _v2 > 0 ? fmt(_v2) : '-'),
      _Row('밴드 하단 V_min', _vMin > 0 ? fmt(_vMin) : '-'),
      _Row('밴드 상단 V_max', _vMax > 0 ? fmt(_vMax) : '-'),
      const Divider(color: Color(0xFF30363D), height: 16),
      _Row('현재가', _currentPrice > 0 ? fmt(_currentPrice) : '-'),
      _Row('보유 수량', '${_shares}주'),
      _Row('주식 평가금 (e)', _currentPrice > 0 ? fmt(_equity) : '-'),
      _Row('Pool (할당-매입원가)', fmt(_pool)),
      _Row('Pool 한도', '${(_poolLimit * 100).toStringAsFixed(0)}%  →  ${fmt(_pool * _poolLimit)} 사용 가능'),
    ]));
  }

  // Pool 전용 — 소수점 2자리 전체 표기
  String _fmtPool(double v) => _isKr ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  Widget _buildOrdersCard() {
    final fmt = _isKr ? Fmt.krw : Fmt.usd;

    // ── 첫 사이클: 시장가 매수 ──
    if (_isFirstCycle) {
      return _Card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('주문 계획', style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: const Color(0xFFF0A500).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4)),
            child: const Text('첫 사이클', style: TextStyle(color: Color(0xFFF0A500), fontSize: 11)),
          ),
        ]),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFF0A500).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFFF0A500).withValues(alpha: 0.3)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('시장가 매수 (장 시작 즉시)',
                style: TextStyle(color: Color(0xFFF0A500), fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            if (_currentPrice > 0) ...[
              _Row('현재가', fmt(_currentPrice)),
              _Row('매수 수량', '$_marketBuyQty 주  (할당금액 ÷ 현재가)'),
              _Row('예상 금액', fmt(_marketBuyQty * _currentPrice)),
            ] else
              const Text('계좌 데이터를 불러오면 수량이 표시됩니다',
                  style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
          ]),
        ),
      ]));
    }

    // ── 데이터 없음 ──
    if (_currentPrice <= 0 || _v2 <= 0) {
      return _Card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('주문 계획', style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
        const SizedBox(height: 8),
        const Text('계좌 데이터를 먼저 불러오세요',
            style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
      ]));
    }

    final poolAvail = _pool * _poolLimit;
    final buyOrders = _buildBuyGrid(_vMin, _shares, _qtyPerStep, poolAvail);
    final sellOrders = _buildSellGrid(_vMax, _shares, _qtyPerStep);

    return _Card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('주문 계획', style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
      const SizedBox(height: 4),
      const Text('리밸런싱 기간 중 매일 장 시작 지정가',
          style: TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
      const SizedBox(height: 10),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: _buildBuyTableSection(buyOrders, poolAvail)),
        const SizedBox(width: 8),
        Expanded(child: _buildSellTableSection(sellOrders)),
      ]),
    ]));
  }

  Widget _buildBuyTableSection(List<_GridOrder> buyOrders, double poolAvail) {
    const h = TextStyle(color: Color(0xFF8B949E), fontSize: 9, fontWeight: FontWeight.w600);
    const v = TextStyle(color: Color(0xFFE6EDF3), fontSize: 9);
    const g = TextStyle(color: Color(0xFF2EA043), fontSize: 9, fontWeight: FontWeight.w500);
    const dim = TextStyle(color: Color(0xFF57606A), fontSize: 9);

    Widget cell(String t, TextStyle s) =>
        Padding(padding: const EdgeInsets.only(top: 2), child: Text(t, style: s, overflow: TextOverflow.ellipsis));

    final rows = <TableRow>[];
    double cumulCost = 0;
    for (final o in buyOrders) {
      // mQty = shares before this buy (start from current N)
      final mQty = _shares + (o.level - 1) * o.quantity;
      // Actual order price from grid (vMin / (mQty + qty)); Vmin check uses after-buy qty
      final price = o.price;
      final afterQty = mQty + o.quantity;
      final check = afterQty * price; // should equal _vMin
      // Pool before this buy (using actual order price for cost accumulation)
      final poolRem = poolAvail - cumulCost;
      final pct = poolAvail > 0 ? poolRem / poolAvail * 100 : 0.0;
      rows.add(TableRow(children: [
        cell('${o.quantity}', g),
        cell('$mQty', v),
        cell(_fmtPool(price), v),
        cell(_fmtPool(check), dim),
        cell(_fmtPool(poolRem), v),
        cell('${pct.toStringAsFixed(0)}%', v),
      ]));
      cumulCost += price * o.quantity; // actual cost
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('매수', style: TextStyle(color: Color(0xFF2EA043), fontSize: 11, fontWeight: FontWeight.w700)),
        const SizedBox(width: 4),
        Text('${buyOrders.length}건', style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
      ]),
      Text('Pool: ${_fmtPool(poolAvail)}', style: const TextStyle(color: Color(0xFF8B949E), fontSize: 9)),
      const SizedBox(height: 5),
      if (buyOrders.isEmpty)
        const Text('조건 없음', style: TextStyle(color: Color(0xFF8B949E), fontSize: 10))
      else
        Table(
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          columnWidths: const {
            0: FlexColumnWidth(1.0), // Qty
            1: FlexColumnWidth(1.5), // MQty
            2: FlexColumnWidth(3.0), // Price
            3: FlexColumnWidth(3.5), // Vmin
            4: FlexColumnWidth(3.5), // Pool
            5: FlexColumnWidth(1.5), // %
          },
          children: [
            TableRow(children: [
              Text('Qty', style: h),
              Text('MQty', style: h),
              Text('Price', style: h),
              Text('Vmin', style: h),
              Text('Pool', style: h),
              Text('%', style: h),
            ]),
            ...rows,
          ],
        ),
      ]);
  }

  Widget _buildSellTableSection(List<_GridOrder> sellOrders) {
    const h = TextStyle(color: Color(0xFF8B949E), fontSize: 9, fontWeight: FontWeight.w600);
    const v = TextStyle(color: Color(0xFFE6EDF3), fontSize: 9);
    const r = TextStyle(color: Color(0xFFF85149), fontSize: 9, fontWeight: FontWeight.w500);
    const dim = TextStyle(color: Color(0xFF57606A), fontSize: 9);

    Widget cell(String t, TextStyle s) =>
        Padding(padding: const EdgeInsets.only(top: 2), child: Text(t, style: s, overflow: TextOverflow.ellipsis));

    final rows = <TableRow>[];
    double poolBalance = _pool;
    for (final o in sellOrders) {
      final afterQty = _shares - (o.level - 1) * o.quantity;
      final price = afterQty > 0 ? _vMax / afterQty : 0.0;
      final check = afterQty * price;
      // Pool before this sell (after all previous sells have been executed)
      rows.add(TableRow(children: [
        cell('${o.quantity}', r),
        cell('$afterQty', v),
        cell(_fmtPool(price), v),
        cell(_fmtPool(check), dim),
        cell(_fmtPool(poolBalance), v),
      ]));
      poolBalance += price * o.quantity;
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('매도', style: TextStyle(color: Color(0xFFF85149), fontSize: 11, fontWeight: FontWeight.w700)),
        const SizedBox(width: 4),
        Text('${sellOrders.length}건', style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
      ]),
      const Text('Pool 회수', style: TextStyle(color: Color(0xFF8B949E), fontSize: 9)),
      const SizedBox(height: 5),
      if (sellOrders.isEmpty)
        const Text('조건 없음', style: TextStyle(color: Color(0xFF8B949E), fontSize: 10))
      else
        Table(
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          columnWidths: const {
            0: FlexColumnWidth(1.0), // Qty
            1: FlexColumnWidth(1.5), // AfterQ
            2: FlexColumnWidth(3.0), // Price
            3: FlexColumnWidth(3.5), // Vmax
            4: FlexColumnWidth(3.5), // Pool+
          },
          children: [
            TableRow(children: [
              Text('Qty', style: h),
              Text('AfterQ', style: h),
              Text('Price', style: h),
              Text('Vmax', style: h),
              Text('Pool+', style: h),
            ]),
            ...rows,
          ],
        ),
      ]);
  }
}

// ─── 공용 위젯 ────────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: child,
      );
}

class _Row extends StatelessWidget {
  final String label, value;
  const _Row(this.label, this.value);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          Text(label, style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
          const Spacer(),
          Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFFE6EDF3))),
        ]),
      );
}

class _ParamField extends StatelessWidget {
  final String label, suffix;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final TextInputType? keyboardType;
  const _ParamField({required this.label, required this.controller, required this.suffix, required this.onChanged, this.keyboardType});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          keyboardType: keyboardType ?? const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(fontSize: 13, color: Color(0xFFE6EDF3)),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            filled: true, fillColor: const Color(0xFF0D1117),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Color(0xFF30363D))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Color(0xFF30363D))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Color(0xFF58A6FF))),
            suffixText: suffix,
            suffixStyle: const TextStyle(color: Color(0xFF8B949E), fontSize: 11),
          ),
          onChanged: onChanged,
        ),
      ]);
}
