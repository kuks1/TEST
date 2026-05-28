import 'package:flutter/material.dart';
import '../../core/api_service.dart';
import '../../core/app_theme.dart';
import '../../core/common.dart';
import '../../core/database.dart';
import '../../models/strategy.dart';

class KrValueDetailScreen extends StatefulWidget {
  final Strategy strategy;
  const KrValueDetailScreen({super.key, required this.strategy});

  @override
  State<KrValueDetailScreen> createState() => _KrValueDetailScreenState();
}

class _KrValueDetailScreenState extends State<KrValueDetailScreen> {
  late Strategy _strategy;
  List<Map<String, dynamic>> _stocks = [];
  Map<String, double> _prices = {};
  Map<String, Map<String, dynamic>> _holdings = {};
  bool _loading = false;
  final _addCtrl = TextEditingController();
  final _capitalEditCtrl = TextEditingController();
  double? _pendingCapital;

  bool get _hasUnsavedChanges => _pendingCapital != null;

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

  // 시장별 헬퍼
  bool get _isOpen => s.market == 'KR' ? MarketClock.isKrOpen : MarketClock.isUsOpen;
  String _nextOpen() => s.market == 'KR' ? MarketClock.nextKrOpen() : MarketClock.nextUsOpen();
  String _fmtMoney(double v) => s.market == 'KR' ? Fmt.krw(v) : Fmt.usd(v);
  String _capStr(double v) => s.market == 'KR' ? v.toInt().toString() : v.toStringAsFixed(2);

  @override
  void initState() {
    super.initState();
    _strategy = widget.strategy;
    _capitalEditCtrl.text = _capStr(s.capital);
    _loadStocks();
  }

  @override
  void dispose() {
    _addCtrl.dispose();
    _capitalEditCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadStocks() async {
    setState(() { _loading = true; });
    final rows = await AppDatabase.getPortfolioStocks(s.strategyId);
    setState(() {
      _stocks = rows.map((r) => Map<String, dynamic>.from(r)).toList();
      _loading = false;
    });
    _loadPrices();
  }

  Future<void> _loadPrices() async {
    if (_stocks.isEmpty) return;
    try {
      final prices = <String, double>{};
      final holdings = <String, Map<String, dynamic>>{};
      final accountData = await ApiService.getAccount();
      final marketKey = s.market == 'KR' ? 'kr' : 'us';
      for (final acc in (accountData[marketKey] as List? ?? [])) {
        for (final h in (acc['holdings'] as List? ?? [])) {
          final ticker = h['ticker'] as String;
          final price = (h['current_price'] as num? ?? 0).toDouble();
          if (price > 0) prices[ticker] = price;
          holdings[ticker] = {
            'avg_price': (h['avg_price'] as num? ?? 0).toDouble(),
            'shares': (h['shares'] as num? ?? 0).toDouble(),
          };
        }
      }
      for (final stock in _stocks) {
        final ticker = stock['ticker'] as String;
        if (!prices.containsKey(ticker)) {
          try {
            final q = await ApiService.getQuote(ticker, s.market);
            final price = (q['price'] as num? ?? q['current_price'] as num? ?? 0).toDouble();
            if (price > 0) prices[ticker] = price;
          } catch (_) {}
        }
      }
      if (mounted) setState(() { _prices = prices; _holdings = holdings; });
    } catch (_) {}
  }

  double get _weightSum =>
      _stocks.fold(0.0, (sum, r) => sum + (r['weight'] as num? ?? 0));

  void _setEqualWeight() {
    if (_stocks.isEmpty) return;
    final w = double.parse(Calc.equalWeight(_stocks.length).toStringAsFixed(2));
    setState(() {
      for (final s in _stocks) { s['weight'] = w; }
    });
  }

  Future<void> _addTicker() async {
    final input = _addCtrl.text.trim();
    if (input.isEmpty) return;

    final tickers = input.split(RegExp(r'[,\s]+')).where((t) => t.isNotEmpty).toList();
    final results = <String>[];

    for (final raw in tickers) {
      // KR은 6자리 패딩, US는 그대로
      final ticker = s.market == 'KR' ? raw.padLeft(6, '0') : raw.toUpperCase();
      try {
        final quote = await ApiService.getQuote(ticker, s.market);
        final name = quote['name'] as String? ?? '';
        if (name.isEmpty) {
          results.add('$ticker: 존재하지 않음');
        } else {
          final exists = _stocks.any((st) => st['ticker'] == ticker);
          if (!exists) {
            _stocks.add({'ticker': ticker, 'name': name, 'weight': 0.0});
            results.add('$ticker ($name) 추가됨');
          } else {
            results.add('$ticker: 이미 등록됨');
          }
        }
      } catch (_) {
        results.add('$ticker: 조회 실패');
      }
    }

    _addCtrl.clear();
    setState(() {});

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(results.join('\n')), duration: const Duration(seconds: 3)),
      );
    }
  }

  Future<void> _delete() async {
    if (!mounted) return;

    // Check which portfolio stocks are currently held
    final List<Map<String, dynamic>> heldStocks = [];
    if (_stocks.isNotEmpty) {
      try {
        final accountData = await ApiService.getAccount();
        final marketKey = s.market == 'KR' ? 'kr' : 'us';
        final holdingsMap = <String, Map<String, dynamic>>{};
        for (final acc in (accountData[marketKey] as List? ?? [])) {
          for (final h in (acc['holdings'] as List? ?? [])) {
            holdingsMap[h['ticker'] as String] = Map<String, dynamic>.from(h);
          }
        }
        for (final stock in _stocks) {
          final ticker = stock['ticker'] as String;
          final h = holdingsMap[ticker];
          if (h != null && (h['shares'] as num? ?? 0) > 0) {
            heldStocks.add({...stock, ...h});
          }
        }
      } catch (_) {}
    }

    if (heldStocks.isNotEmpty) {
      final choice = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF161B22),
          title: Text('${s.strategyId} 삭제'),
          content: Text('보유 종목 ${heldStocks.length}개를 어떻게 처리할까요?'),
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
        for (final stock in heldStocks) {
          await AppDatabase.insertPendingSell({
            'ticker': stock['ticker'] as String,
            'name': stock['name'] as String? ?? stock['ticker'],
            'market': s.market,
            'quantity': (stock['shares'] as num? ?? 0).toDouble(),
            'avg_price': (stock['avg_price'] as num? ?? 0).toDouble(),
            'scheduled_at': scheduled.toIso8601String(),
            'status': 'pending',
            'source_strategy_id': s.strategyId,
            'created_at': DateTime.now().toIso8601String(),
          });
        }
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

  Future<void> _saveCapital() async {
    if (_pendingCapital == null) return;
    final newCapital = _pendingCapital!;
    final updated = s.copyWith(capital: newCapital);
    await AppDatabase.updateStrategy(updated);
    _capitalEditCtrl.text = _capStr(updated.capital);
    setState(() { _strategy = updated; _pendingCapital = null; });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('할당금액이 변경되었습니다. 계획수량이 재계산됩니다.'),
          duration: Duration(seconds: 2)),
    );
  }


  // ── 제외 종목 감지 (DB 포트폴리오 vs 현재 _stocks 비교) ───────
  Future<(List<Map<String, dynamic>>, Map<String, Map<String, dynamic>>)>
      _detectRemovedHoldings() async {
    final prevStocks = await AppDatabase.getPortfolioStocks(s.strategyId);
    final currentTickers =
        _stocks.map((st) => st['ticker'] as String).toSet();
    final removedDbRows = prevStocks
        .where((p) => !currentTickers.contains(p['ticker'] as String))
        .toList();

    final holdingsMap = <String, Map<String, dynamic>>{};
    final removedHeld = <Map<String, dynamic>>[];

    try {
      final accountData = await ApiService.getAccount();
      final marketKey = s.market == 'KR' ? 'kr' : 'us';
      for (final acc in (accountData[marketKey] as List? ?? [])) {
        for (final h in (acc['holdings'] as List? ?? [])) {
          holdingsMap[h['ticker'] as String] =
              Map<String, dynamic>.from(h);
        }
      }
      for (final row in removedDbRows) {
        final ticker = row['ticker'] as String;
        final h = holdingsMap[ticker];
        if (h != null && (h['shares'] as num? ?? 0) > 0) {
          removedHeld.add({...Map<String, dynamic>.from(row), ...h});
        }
      }
    } catch (_) {}

    return (removedHeld, holdingsMap);
  }

  Future<Set<String>?> _showRemovedStocksSheet(
      List<Map<String, dynamic>> removedHeld) {
    return showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) =>
          _RemovedStocksSheet(stocks: removedHeld, fmtMoney: _fmtMoney),
    );
  }

  void _removeStock(int index) {
    setState(() { _stocks.removeAt(index); });
  }

  // ── 비중 조절 주문 ────────────────────────────────────────────
  Future<void> _showAdjustOrders() async {
    final sum = _weightSum;
    if ((sum - 100).abs() > 0.1) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                '비중 합계가 ${sum.toStringAsFixed(1)}%입니다. 100%로 맞춰주세요.'),
            backgroundColor: const Color(0xFFF85149)),
      );
      return;
    }

    setState(() { _loading = true; });

    // 1. 제외 종목 감지 (holdingsMap도 함께 반환)
    final (removedHeld, holdingsMap) = await _detectRemovedHoldings();

    // 2. 제외 종목 처리 선택
    Set<String> sellTickers = {};
    if (removedHeld.isNotEmpty && mounted) {
      setState(() { _loading = false; });
      final result = await _showRemovedStocksSheet(removedHeld);
      if (result == null || !mounted) return;
      sellTickers = result;
      setState(() { _loading = true; });
    }

    // 3. DB 정리: 제외 종목 삭제 후 현재 종목 저장
    final prevStocks = await AppDatabase.getPortfolioStocks(s.strategyId);
    final currentTickers =
        _stocks.map((st) => st['ticker'] as String).toSet();
    for (final prev in prevStocks) {
      if (!currentTickers.contains(prev['ticker'] as String)) {
        await AppDatabase.deletePortfolioStock(
            s.strategyId, prev['ticker'] as String);
      }
    }
    for (final stock in _stocks) {
      await AppDatabase.savePortfolioStock(
        s.strategyId,
        stock['ticker'],
        stock['name'] ?? '',
        (stock['weight'] as num).toDouble(),
      );
    }

    try {
      // 4. 현재 종목 주문 계산 (이미 받아온 holdingsMap 재사용)
      final orders = <_AdjustOrder>[];
      for (final stock in _stocks) {
        final ticker = stock['ticker'] as String;
        final weight = (stock['weight'] as num? ?? 0).toDouble();
        final targetAmt = s.capital * weight / 100;

        double currentPrice = 0;
        double avgPrice = 0;
        int currentQty = 0;
        final holding = holdingsMap[ticker];
        if (holding != null) {
          currentPrice =
              (holding['current_price'] as num? ?? 0).toDouble();
          avgPrice = (holding['avg_price'] as num? ?? 0).toDouble();
          currentQty = (holding['shares'] as num? ?? 0).toInt();
        }
        if (currentPrice <= 0) {
          try {
            final q = await ApiService.getQuote(ticker, s.market);
            currentPrice = (q['price'] as num? ?? q['current_price'] as num? ?? 0).toDouble();
          } catch (_) {}
        }

        final usePrice =
            (avgPrice > 0 && currentQty > 0) ? avgPrice : currentPrice;
        final targetQty =
            usePrice > 0 ? (targetAmt / usePrice).floor() : 0;
        orders.add(_AdjustOrder(
          ticker: ticker,
          name: stock['name'] as String? ?? ticker,
          weight: weight,
          targetAmt: targetAmt,
          // 장 마감 시 current_price=0 반환 → 보유 종목은 avgPrice fallback
          currentPrice: currentPrice > 0 ? currentPrice : (currentQty > 0 ? avgPrice : 0),
          avgPrice: avgPrice > 0 ? avgPrice : currentPrice,
          currentQty: currentQty,
          targetQty: targetQty,
        ));
      }

      // 5. 매도 선택된 제외 종목 → targetQty=0 (전량 매도)
      for (final rh in removedHeld
          .where((rh) => sellTickers.contains(rh['ticker'] as String))) {
        final ticker = rh['ticker'] as String;
        final shares = (rh['shares'] as num? ?? 0).toInt();
        final avgPrice = (rh['avg_price'] as num? ?? 0).toDouble();
        final currentPrice =
            (rh['current_price'] as num? ?? 0).toDouble();
        orders.add(_AdjustOrder(
          ticker: ticker,
          name: rh['name'] as String? ?? ticker,
          weight: 0,
          targetAmt: 0,
          currentPrice: currentPrice > 0 ? currentPrice : avgPrice,
          avgPrice: avgPrice,
          currentQty: shares,
          targetQty: 0,
        ));
      }

      // 6. 매수 불가 종목 검증
      final blockedNames = orders
          .where((o) => o.isBuy && o.targetQty <= 0 && o.currentPrice > 0)
          .map((o) => '${o.ticker} (${o.name})')
          .toList();
      if (blockedNames.isNotEmpty && mounted) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: const Color(0xFF161B22),
            title: const Text('매수 불가 종목'),
            content: Text(
                '할당금액으로 1주도 매수할 수 없는 종목:\n${blockedNames.join('\n')}'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('취소')),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(
                    foregroundColor: AppTheme.accent),
                child: const Text('확인 후 진행'),
              ),
            ],
          ),
        );
        if (proceed != true) {
          setState(() { _loading = false; });
          return;
        }
      }

      if (!mounted) return;
      setState(() { _loading = false; });

      // 7. QT 수정 세션 생성 및 주문 항목 저장
      final now = DateTime.now();
      final sessionId = await AppDatabase.insertQtSession({
        'strategy_id': s.strategyId,
        'session_type': 'modify',
        'total_capital': s.capital,
        'market': s.market,
        'status': 'active',
        'created_at': now.toIso8601String(),
      });
      for (final o in orders) {
        if (o.isOk) continue;
        await AppDatabase.insertQtOrderItem({
          'session_id': sessionId,
          'strategy_id': s.strategyId,
          'ticker': o.ticker,
          'name': o.name,
          'weight': o.weight,
          'allocation_amount': o.targetAmt,
          'planned_qty': o.delta.abs(),
          'planned_price': o.avgPrice,
          'actual_qty': 0,
          'actual_price': 0.0,
          'status': 'Scheduled',
          'side': o.isBuy ? 'BUY' : 'SELL',
          'created_at': now.toIso8601String(),
        });
      }

      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF161B22),
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (_) => _AdjustOrderSheet(
          orders: orders,
          strategy: s,
          sessionId: sessionId,
          fmtMoney: _fmtMoney,
        ),
      );
    } catch (e) {
      setState(() { _loading = false; });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('조회 실패: $e'),
            backgroundColor: const Color(0xFFF85149)));
      }
    }
  }

  Widget _buildCapitalCard() {
    final changed = _pendingCapital != null && (_pendingCapital! - s.capital).abs() > 0.01;
    final isKr = s.market == 'KR';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('할당 금액', style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
          if (s.vrMode != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.accent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: AppTheme.accent.withValues(alpha: 0.4)),
              ),
              child: Text(s.vrMode!,
                  style: TextStyle(color: AppTheme.accent, fontSize: 10)),
            ),
          ],
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: _capitalEditCtrl,
          keyboardType: TextInputType.numberWithOptions(decimal: !isKr),
          style: TextStyle(
            fontSize: 15, fontWeight: FontWeight.w700,
            color: changed ? AppTheme.accent : Colors.white,
          ),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            filled: true, fillColor: const Color(0xFF0D1117),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: changed ? AppTheme.accent : const Color(0xFF30363D)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: changed ? AppTheme.accent : const Color(0xFF30363D)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: AppTheme.accent),
            ),
            suffixText: isKr ? '원' : '\$',
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
              onPressed: () {
                _capitalEditCtrl.text = _capStr(s.capital);
                setState(() { _pendingCapital = null; });
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF8B949E),
                side: const BorderSide(color: Color(0xFF30363D)),
              ),
              child: const Text('취소'),
            )),
            const SizedBox(width: 8),
            Expanded(child: ElevatedButton(
              onPressed: _saveCapital,
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accent),
              child: const Text('저장'),
            )),
          ]),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sum = _weightSum;
    final sumColor = (sum - 100).abs() < 0.1
        ? const Color(0xFF2EA043) : const Color(0xFFF85149);

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
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20, color: Color(0xFFF85149)),
            onPressed: _delete,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _SummaryRow(
                      capital: s.capital,
                      stockCount: _stocks.length,
                      market: s.market,
                      isOpen: _isOpen,
                      fmtMoney: _fmtMoney,
                    ),
                    const SizedBox(height: 12),
                    _buildCapitalCard(),
                    const SizedBox(height: 12),

                    const Text('보유 종목',
                        style: TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
                    const Divider(color: Color(0xFF30363D)),

                    ..._stocks.asMap().entries.map((e) {
                      final ticker = e.value['ticker'] as String? ?? '';
                      final h = _holdings[ticker];
                      return _StockRow(
                        stock: e.value,
                        capital: s.capital,
                        currentPrice: _prices[ticker] ?? 0,
                        avgPrice: (h?['avg_price'] as num? ?? 0).toDouble(),
                        heldShares: (h?['shares'] as num? ?? 0).toDouble(),
                        market: s.market,
                        onWeightChanged: (v) => setState(() { e.value['weight'] = v; }),
                        onDelete: () => _removeStock(e.key),
                      );
                    }),

                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight,
                      child: Text('합계: ${sum.toStringAsFixed(1)}%',
                          style: TextStyle(color: sumColor, fontWeight: FontWeight.w600))),

                    const SizedBox(height: 16),
                    _AddRow(
                      ctrl: _addCtrl,
                      onAdd: _addTicker,
                      hint: s.market == 'KR'
                          ? '종목코드 입력 (쉼표/공백 구분)'
                          : '티커 입력 (예: AAPL, MSFT)',
                    ),
                    const SizedBox(height: 16),

                    Row(children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _setEqualWeight,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.accent,
                            side: const BorderSide(color: Color(0xFF30363D)),
                          ),
                          child: const Text('동일비중'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _loading ? null : _showAdjustOrders,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF2EA043),
                            side: const BorderSide(color: Color(0xFF2EA043)),
                          ),
                          child: const Text('수량 조절'),
                        ),
                      ),
                    ]),
                  ],
                ),
              ),
            ]),
    ),
  );
  }
}

class _SummaryRow extends StatelessWidget {
  final double capital;
  final int stockCount;
  final String market;
  final bool isOpen;
  final String Function(double) fmtMoney;
  const _SummaryRow({
    required this.capital,
    required this.stockCount,
    required this.market,
    required this.isOpen,
    required this.fmtMoney,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: Row(children: [
          _Cell('할당금액', fmtMoney(capital)),
          _Cell('종목수', '$stockCount개'),
          _Cell('장 상태', isOpen ? '운영중' : '마감'),
        ]),
      );
}

class _Cell extends StatelessWidget {
  final String label, value;
  const _Cell(this.label, this.value);
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(children: [
          Text(label, style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      );
}

class _StockRow extends StatefulWidget {
  final Map<String, dynamic> stock;
  final double capital;
  final double currentPrice;
  final double avgPrice;
  final double heldShares;
  final String market;
  final ValueChanged<double> onWeightChanged;
  final VoidCallback onDelete;

  const _StockRow({
    required this.stock, required this.capital,
    required this.currentPrice, required this.avgPrice,
    required this.heldShares, required this.market,
    required this.onWeightChanged, required this.onDelete,
  });

  @override
  State<_StockRow> createState() => _StockRowState();
}

class _StockRowState extends State<_StockRow> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    final w = (widget.stock['weight'] as num? ?? 0).toDouble();
    _ctrl = TextEditingController(text: w.toStringAsFixed(1));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ticker  = widget.stock['ticker'] as String? ?? '';
    final name    = widget.stock['name']   as String? ?? ticker;
    final weight  = (widget.stock['weight'] as num? ?? 0).toDouble();
    final capital = widget.capital;
    final cur     = widget.currentPrice;
    final avg     = widget.avgPrice;
    final held    = widget.heldShares;
    final isKr    = widget.market == 'KR';

    String fmt(double v) => isKr ? Fmt.krw(v) : Fmt.usd(v);

    final targetAmt      = capital * weight / 100;
    final usePrice       = (avg > 0 && held > 0) ? avg : cur;
    final plannedQty     = usePrice > 0 ? (targetAmt / usePrice).floor() : -1;
    final allocValue     = (usePrice > 0 && plannedQty >= 0) ? usePrice * plannedQty : -1.0;
    final evalAmt        = (held > 0 && cur > 0) ? held * cur : -1.0;
    final pnlPct         = (avg > 0 && cur > 0) ? (cur - avg) / avg * 100 : double.nan;
    final pnlColor       = (!pnlPct.isNaN && pnlPct >= 0)
        ? const Color(0xFF2EA043) : const Color(0xFFF85149);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Row 1: 이름(티커) | 비중% 입력 | X
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12,
                    color: Color(0xFFE6EDF3)),
                overflow: TextOverflow.ellipsis),
            Text(ticker,
                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
          ])),
          SizedBox(
            width: 68,
            child: TextField(
              controller: _ctrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                filled: true, fillColor: const Color(0xFF0D1117),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: Color(0xFF30363D))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: Color(0xFF30363D))),
                suffixText: '%',
                suffixStyle: const TextStyle(fontSize: 10, color: Color(0xFF8B949E)),
              ),
              onChanged: (v) {
                final d = double.tryParse(v);
                if (d != null) widget.onWeightChanged(d);
              },
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: widget.onDelete,
            child: const Icon(Icons.close, size: 16, color: Color(0xFF8B949E)),
          ),
        ]),
        const SizedBox(height: 6),
        const Divider(color: Color(0xFF21262D), height: 1),
        const SizedBox(height: 6),
        // Row 2: 매입단가 | 현재단가 | ±%
        Row(children: [
          _IC('매입단가', avg > 0 ? fmt(avg) : '-'),
          _IC('현재단가', cur > 0 ? fmt(cur) : '-'),
          _IC('±%',
              pnlPct.isNaN ? '-' : '${pnlPct >= 0 ? '+' : ''}${pnlPct.toStringAsFixed(2)}%',
              color: pnlPct.isNaN ? null : pnlColor),
        ]),
        const SizedBox(height: 4),
        // Row 3: 계획수량 | 보유수량
        Row(children: [
          _IC('계획수량', plannedQty >= 0 ? '${plannedQty}주' : '-'),
          _IC('보유수량', held > 0 ? '${held.toInt()}주' : '0주'),
          const Expanded(child: SizedBox()),
        ]),
        const SizedBox(height: 4),
        // Row 4: 종목할당금액 | 평가금액 | 할당금액
        Row(children: [
          _IC('종목할당금액', allocValue >= 0 ? fmt(allocValue) : '-'),
          _IC('평가금액',   evalAmt   >= 0 ? fmt(evalAmt)   : '-'),
          _IC('할당금액',   fmt(targetAmt)),
        ]),
      ]),
    );
  }
}

class _IC extends StatelessWidget {
  final String label, value;
  final Color? color;
  const _IC(this.label, this.value, {this.color});
  @override
  Widget build(BuildContext context) => Expanded(child: Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(color: Color(0xFF6E7681), fontSize: 9)),
      Text(value,  style: TextStyle(
          color: color ?? const Color(0xFFE6EDF3),
          fontSize: 11, fontWeight: FontWeight.w600)),
    ],
  ));
}

// ══════════════════════════════════════════════════════════════════
// 비중 조절 주문 모델
// ══════════════════════════════════════════════════════════════════

class _AdjustOrder {
  final String ticker, name;
  final double weight, targetAmt, currentPrice, avgPrice;
  final int currentQty, targetQty;

  const _AdjustOrder({
    required this.ticker,
    required this.name,
    required this.weight,
    required this.targetAmt,
    required this.currentPrice,
    required this.avgPrice,
    required this.currentQty,
    required this.targetQty,
  });

  int get delta => targetQty - currentQty;
  bool get isBuy => delta > 0;
  bool get isSell => delta < 0;
  bool get isOk => delta == 0;
}

// ══════════════════════════════════════════════════════════════════
// 비중 조절 주문 바텀시트
// ══════════════════════════════════════════════════════════════════

class _AdjustOrderSheet extends StatefulWidget {
  final List<_AdjustOrder> orders;
  final Strategy strategy;
  final int sessionId;
  final String Function(double) fmtMoney;

  const _AdjustOrderSheet({
    required this.orders,
    required this.strategy,
    required this.sessionId,
    required this.fmtMoney,
  });

  @override
  State<_AdjustOrderSheet> createState() => _AdjustOrderSheetState();
}

class _AdjustOrderSheetState extends State<_AdjustOrderSheet> {
  final Set<String> _executing = {};
  bool _executingAll = false;

  Future<void> _placeOne(_AdjustOrder o) async {
    if (o.isOk || o.currentPrice <= 0) return;
    setState(() { _executing.add(o.ticker); });
    try {
      await ApiService.placeOrder(
        market: widget.strategy.market,
        ticker: o.ticker,
        side: o.isBuy ? 'BUY' : 'SELL',
        quantity: o.delta.abs(),
        price: 0,
        ordDvsn: '01',
      );
      // qt_order_items의 해당 항목을 Scheduled 상태로 유지 (5분 폴링이 체결 확인)
      // 이미 insertQtOrderItem으로 생성됨 — 별도 업데이트 불필요
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${o.ticker} ${o.isBuy ? '매수' : '매도'} ${o.delta.abs()}주 주문 완료'),
              duration: const Duration(seconds: 2)));
      }
    } catch (e) {
      // 실패 시 해당 항목 Failed 처리
      final items = await AppDatabase.getQtOrderItems(widget.sessionId);
      final match = items.where((i) =>
          i['ticker'] == o.ticker && i['side'] == (o.isBuy ? 'BUY' : 'SELL')).toList();
      if (match.isNotEmpty) {
        await AppDatabase.updateQtOrderItem(match.first['id'] as int, {
          'status': 'Failed',
          'updated_at': DateTime.now().toIso8601String(),
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${o.ticker} 실패: $e'),
              backgroundColor: const Color(0xFFF85149)));
      }
    } finally {
      if (mounted) setState(() { _executing.remove(o.ticker); });
    }
  }

  Future<void> _placeAll() async {
    final actionable = widget.orders.where((o) => !o.isOk && o.currentPrice > 0).toList();
    if (actionable.isEmpty) return;
    setState(() { _executingAll = true; });
    for (final o in actionable) {
      await _placeOne(o);
    }
    if (mounted) setState(() { _executingAll = false; });
  }

  @override
  Widget build(BuildContext context) {
    final actionable = widget.orders.where((o) => !o.isOk).length;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (_, ctrl) => Column(children: [
        // 핸들
        const SizedBox(height: 8),
        Container(width: 36, height: 4,
            decoration: BoxDecoration(
                color: const Color(0xFF484F58),
                borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 12),
        // 헤더
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            const Text('수량 조절 주문',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600,
                    color: Color(0xFFE6EDF3))),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFF21262D),
                  borderRadius: BorderRadius.circular(4)),
              child: Text('${widget.orders.length}종목',
                  style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
            ),
          ]),
        ),
        const SizedBox(height: 4),
        // 컬럼 헤더
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(children: const [
            Expanded(flex: 3, child: Text('종목', style: TextStyle(color: Color(0xFF8B949E), fontSize: 10))),
            Expanded(flex: 2, child: Text('현재→목표', textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF8B949E), fontSize: 10))),
            Expanded(flex: 2, child: Text('주문', textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF8B949E), fontSize: 10))),
            SizedBox(width: 64),
          ]),
        ),
        const Divider(color: Color(0xFF30363D), height: 1),
        // 종목 목록
        Expanded(
          child: ListView.separated(
            controller: ctrl,
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: widget.orders.length,
            separatorBuilder: (_, __) =>
                const Divider(color: Color(0xFF21262D), height: 1),
            itemBuilder: (_, i) {
              final o = widget.orders[i];
              final isExec = _executing.contains(o.ticker);
              final actionColor = o.isBuy
                  ? const Color(0xFF2EA043)
                  : o.isSell
                      ? const Color(0xFFF85149)
                      : const Color(0xFF484F58);
              final actionLabel = o.isBuy
                  ? '매수 +${o.delta}'
                  : o.isSell
                      ? '매도 ${o.delta}'
                      : '유지';

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(children: [
                  // 종목명
                  Expanded(flex: 3, child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(o.ticker,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 12,
                            color: Color(0xFFE6EDF3))),
                    Text('${o.weight.toStringAsFixed(1)}%  ${widget.fmtMoney(o.targetAmt)}',
                        style: const TextStyle(
                            color: Color(0xFF8B949E), fontSize: 10)),
                  ])),
                  // 현재→목표
                  Expanded(flex: 2, child: Text(
                    '${o.currentQty}→${o.targetQty}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11, color: Color(0xFFE6EDF3)),
                  )),
                  // 주문 배지
                  Expanded(flex: 2, child: Center(child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: actionColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(actionLabel,
                        style: TextStyle(
                            color: actionColor, fontSize: 10,
                            fontWeight: FontWeight.w700)),
                  ))),
                  // 실행 버튼
                  SizedBox(width: 64, child: o.isOk || o.currentPrice <= 0
                      ? const SizedBox()
                      : TextButton(
                          onPressed: isExec || _executingAll ? null : () => _placeOne(o),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            foregroundColor: actionColor,
                          ),
                          child: isExec
                              ? const SizedBox(width: 12, height: 12,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('실행', style: TextStyle(fontSize: 11)),
                        )),
                ]),
              );
            },
          ),
        ),
        // 전체 실행 버튼
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: (_executingAll || actionable == 0) ? null : _placeAll,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: _executingAll
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text('전체 실행 ($actionable건)',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// 전략 제외 종목 처리 바텀시트
// ══════════════════════════════════════════════════════════════════

class _RemovedStocksSheet extends StatefulWidget {
  final List<Map<String, dynamic>> stocks;
  final String Function(double) fmtMoney;
  const _RemovedStocksSheet(
      {required this.stocks, required this.fmtMoney});
  @override
  State<_RemovedStocksSheet> createState() => _RemovedStocksSheetState();
}

class _RemovedStocksSheetState extends State<_RemovedStocksSheet> {
  late Set<String> _sellSet;

  @override
  void initState() {
    super.initState();
    // 기본값: 모두 매도
    _sellSet = widget.stocks.map((s) => s['ticker'] as String).toSet();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (_, ctrl) => Column(children: [
        Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          width: 36,
          height: 4,
          decoration: BoxDecoration(
              color: const Color(0xFF30363D),
              borderRadius: BorderRadius.circular(2)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded,
                color: Color(0xFFF0A800), size: 18),
            const SizedBox(width: 8),
            const Text('전략 제외 종목 처리',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: Color(0xFFE6EDF3))),
            const Spacer(),
            Text('${widget.stocks.length}종목',
                style: const TextStyle(
                    color: Color(0xFF6E7681), fontSize: 11)),
          ]),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Text(
            '전략 목록에서 제외된 보유 종목입니다.\n각 종목의 처리 방법을 선택하세요.',
            style: TextStyle(color: Color(0xFF8B949E), fontSize: 11),
          ),
        ),
        const Divider(color: Color(0xFF30363D), height: 1),
        Expanded(
          child: ListView.builder(
            controller: ctrl,
            padding: const EdgeInsets.all(12),
            itemCount: widget.stocks.length,
            itemBuilder: (_, i) {
              final stock = widget.stocks[i];
              final ticker = stock['ticker'] as String;
              final name = stock['name'] as String? ?? ticker;
              final shares =
                  (stock['shares'] as num? ?? 0).toDouble();
              final avgPrice =
                  (stock['avg_price'] as num? ?? 0).toDouble();
              final isSell = _sellSet.contains(ticker);

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D1117),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF30363D)),
                ),
                child: Row(children: [
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(ticker,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                              color: Color(0xFFE6EDF3))),
                      Text(name,
                          style: const TextStyle(
                              color: Color(0xFF8B949E), fontSize: 10),
                          overflow: TextOverflow.ellipsis),
                      Text(
                          '${shares.toInt()}주 · ${widget.fmtMoney(avgPrice)}',
                          style: const TextStyle(
                              color: Color(0xFF6E7681), fontSize: 10)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Row(children: [
                    GestureDetector(
                      onTap: () =>
                          setState(() { _sellSet.add(ticker); }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: isSell
                              ? const Color(0xFFF85149)
                                  .withValues(alpha: 0.2)
                              : const Color(0xFF21262D),
                          borderRadius: const BorderRadius.horizontal(
                              left: Radius.circular(6)),
                          border: Border.all(
                            color: isSell
                                ? const Color(0xFFF85149)
                                : const Color(0xFF30363D),
                          ),
                        ),
                        child: Text('매도',
                            style: TextStyle(
                              color: isSell
                                  ? const Color(0xFFF85149)
                                  : const Color(0xFF8B949E),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            )),
                      ),
                    ),
                    GestureDetector(
                      onTap: () =>
                          setState(() { _sellSet.remove(ticker); }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: !isSell
                              ? const Color(0xFF2EA043)
                                  .withValues(alpha: 0.15)
                              : const Color(0xFF21262D),
                          borderRadius: const BorderRadius.horizontal(
                              right: Radius.circular(6)),
                          border: Border.all(
                            color: !isSell
                                ? const Color(0xFF2EA043)
                                : const Color(0xFF30363D),
                          ),
                        ),
                        child: Text('보유이동',
                            style: TextStyle(
                              color: !isSell
                                  ? const Color(0xFF2EA043)
                                  : const Color(0xFF8B949E),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            )),
                      ),
                    ),
                  ]),
                ]),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context, _sellSet),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text('확인',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14)),
            ),
          ),
        ),
      ]),
    );
  }
}

class _AddRow extends StatelessWidget {
  final TextEditingController ctrl;
  final VoidCallback onAdd;
  final String hint;
  const _AddRow({required this.ctrl, required this.onAdd, required this.hint});

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
          child: TextField(
            controller: ctrl,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(color: Color(0xFF6E7681), fontSize: 12),
              filled: true, fillColor: const Color(0xFF161B22),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: Color(0xFF30363D))),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: Color(0xFF30363D))),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: onAdd,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF21262D),
            foregroundColor: Colors.white,
          ),
          child: const Text('추가'),
        ),
      ]);
}
