import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/api_service.dart';
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
  bool _loading = false;
  bool _executing = false;
  Timer? _pollTimer;
  String? _lastExecTime;
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
    _pollTimer?.cancel();
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
      final accountData = await ApiService.getAccount();
      final marketKey = s.market == 'KR' ? 'kr' : 'us';
      for (final acc in (accountData[marketKey] as List? ?? [])) {
        for (final h in (acc['holdings'] as List? ?? [])) {
          final price = (h['current_price'] as num? ?? 0).toDouble();
          if (price > 0) prices[h['ticker'] as String] = price;
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
      if (mounted) setState(() { _prices = prices; });
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
    final oldCapital = s.capital;
    final newCapital = _pendingCapital!;
    final stratType = s.type;
    final stratId = s.strategyId;
    final updated = s.copyWith(capital: newCapital);
    await AppDatabase.updateStrategy(updated);
    _capitalEditCtrl.text = _capStr(updated.capital);
    setState(() { _strategy = updated; _pendingCapital = null; });
    if (!mounted) return;

    if (stratType == 'kr_value') {
      final doRebalance = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF161B22),
          title: const Text('QT 재계산'),
          content: const Text('할당금액이 변경되었습니다. 즉시 재밸런싱을 실행할까요?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('나중에')),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: const Color(0xFF1F6FEB)),
              child: const Text('지금 실행'),
            ),
          ],
        ),
      );
      if (doRebalance == true && mounted) {
        setState(() { _executing = true; _lastExecTime = Fmt.datetime(DateTime.now()); });
        try {
          await ApiService.rebalance(stratId);
          _startPolling();
        } catch (e) {
          setState(() { _executing = false; });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('실행 실패: ${e.toString().replaceFirst('Exception: ', '')}'), backgroundColor: const Color(0xFFF85149)),
            );
          }
        }
      }
    } else {
      // VR
      final diff = newCapital - oldCapital;
      final msg = diff > 0 ? '풀 비중이 증가됩니다 (+${_fmtMoney(diff)})' : '풀 비중이 감소됩니다 (${_fmtMoney(diff)})';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
    }
  }

  Future<void> _saveAndExecute() async {
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

    // 1. 제외 종목 감지
    setState(() { _loading = true; });
    final (removedHeld, _) = await _detectRemovedHoldings();
    setState(() { _loading = false; });

    // 2. 제외 종목 처리 선택 (매도 or 보유이동)
    Set<String> sellTickers = {};
    if (removedHeld.isNotEmpty && mounted) {
      final result = await _showRemovedStocksSheet(removedHeld);
      if (result == null || !mounted) return;
      sellTickers = result;
    }

    // 3. DB 정리: 제외 종목 삭제 후 현재 종목 저장
    final prevStocks =
        await AppDatabase.getPortfolioStocks(s.strategyId);
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

    if (!mounted) return;

    // 4. 매도 선택된 제외 종목 → weight=0 으로 추가 (전량 매도 유도)
    final sellRemovedStocks = removedHeld
        .where((rh) => sellTickers.contains(rh['ticker'] as String))
        .map((rh) => <String, dynamic>{
              'ticker': rh['ticker'],
              'name': rh['name'] ?? rh['ticker'],
              'weight': 0.0,
            })
        .toList();

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RebalanceDialog(
        stocks: [..._stocks, ...sellRemovedStocks],
        capital: s.capital,
        market: s.market,
        prices: _prices,
        isOpen: _isOpen,
        strategyId: s.strategyId,
      ),
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('실행가능한 일시에 주문을 생성합니다'),
        duration: Duration(seconds: 2),
      ),
    );
    Navigator.of(context).pop();
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

  void _startPolling() {
    _pollTimer?.cancel();
    int count = 0;
    _pollTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      count++;
      if (count >= 6) {
        _pollTimer?.cancel();
        setState(() { _executing = false; });
      }
    });
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
          currentPrice: currentPrice,
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
                    foregroundColor: const Color(0xFF58A6FF)),
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
                color: const Color(0xFF1F6FEB).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: const Color(0xFF1F6FEB).withValues(alpha: 0.4)),
              ),
              child: Text(s.vrMode!,
                  style: const TextStyle(color: Color(0xFF58A6FF), fontSize: 10)),
            ),
          ],
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: _capitalEditCtrl,
          keyboardType: TextInputType.numberWithOptions(decimal: !isKr),
          style: TextStyle(
            fontSize: 15, fontWeight: FontWeight.w700,
            color: changed ? const Color(0xFF58A6FF) : Colors.white,
          ),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            filled: true, fillColor: const Color(0xFF0D1117),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: changed ? const Color(0xFF58A6FF) : const Color(0xFF30363D)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: changed ? const Color(0xFF58A6FF) : const Color(0xFF30363D)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: Color(0xFF58A6FF)),
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
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1F6FEB)),
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

                    Row(children: [
                      const Expanded(child: Text('종목',
                          style: TextStyle(color: Color(0xFF8B949E), fontSize: 11))),
                      const SizedBox(width: 60,
                          child: Text('비중%', textAlign: TextAlign.center,
                              style: TextStyle(color: Color(0xFF8B949E), fontSize: 11))),
                      const SizedBox(width: 36),
                    ]),
                    const Divider(color: Color(0xFF30363D)),

                    ..._stocks.asMap().entries.map((e) => _StockRow(
                      stock: e.value,
                      capital: s.capital,
                      currentPrice: _prices[e.value['ticker']] ?? 0,
                      market: s.market,
                      onWeightChanged: (v) => setState(() { e.value['weight'] = v; }),
                      onDelete: () => _removeStock(e.key),
                    )),

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
                            foregroundColor: const Color(0xFF58A6FF),
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
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          onPressed: _executing ? null : _saveAndExecute,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFB91C1C),
                          ),
                          child: Text(_executing
                              ? '반영중...'
                              : _isOpen
                                  ? '현재가 기준매수'
                                  : '저장 (${_nextOpen()})'),
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

class _StockRow extends StatelessWidget {
  final Map<String, dynamic> stock;
  final double capital;
  final double currentPrice;
  final String market;
  final ValueChanged<double> onWeightChanged;
  final VoidCallback onDelete;

  const _StockRow({
    required this.stock, required this.capital,
    required this.currentPrice, required this.market,
    required this.onWeightChanged, required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final weight = (stock['weight'] as num? ?? 0).toDouble();
    final ctrl = TextEditingController(text: weight.toStringAsFixed(1));
    final targetAmt = capital * weight / 100;
    final affordableQty = currentPrice > 0 ? (targetAmt / currentPrice).floor() : -1;
    final priceStr = currentPrice > 0
        ? (market == 'KR' ? Fmt.krw(currentPrice) : Fmt.usd(currentPrice))
        : '-';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(stock['ticker'] ?? '',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
          Text(stock['name'] ?? '',
              style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10),
              overflow: TextOverflow.ellipsis),
          Row(children: [
            Text(priceStr,
                style: const TextStyle(color: Color(0xFF6E7681), fontSize: 10)),
            if (affordableQty >= 0) ...[
              const SizedBox(width: 4),
              const Text('·', style: TextStyle(color: Color(0xFF484F58), fontSize: 10)),
              const SizedBox(width: 4),
              Text('매수 가능 ${affordableQty}주',
                  style: const TextStyle(color: Color(0xFF2EA043), fontSize: 10,
                      fontWeight: FontWeight.w500)),
            ],
          ]),
        ])),
        SizedBox(
          width: 60,
          child: TextField(
            controller: ctrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              filled: true, fillColor: const Color(0xFF0D1117),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: const BorderSide(color: Color(0xFF30363D)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: const BorderSide(color: Color(0xFF30363D)),
              ),
              suffixText: '%',
              suffixStyle: const TextStyle(fontSize: 10, color: Color(0xFF8B949E)),
            ),
            onChanged: (v) => onWeightChanged(double.tryParse(v) ?? 0),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: onDelete,
          child: const Icon(Icons.close, size: 16, color: Color(0xFF8B949E)),
        ),
      ]),
    );
  }
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
                backgroundColor: const Color(0xFF1F6FEB),
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
// 매수 주문 로딩 다이얼로그
// ══════════════════════════════════════════════════════════════════
class _RebalanceDialog extends StatefulWidget {
  final List<Map<String, dynamic>> stocks;
  final double capital;
  final String market;
  final Map<String, double> prices;
  final bool isOpen;
  final String strategyId;

  const _RebalanceDialog({
    required this.stocks,
    required this.capital,
    required this.market,
    required this.prices,
    required this.isOpen,
    required this.strategyId,
  });

  @override
  State<_RebalanceDialog> createState() => _RebalanceDialogState();
}

class _RebalanceDialogState extends State<_RebalanceDialog> {
  List<_AdjustOrder> _orders = [];
  final Map<String, String> _status = {};
  bool _done = false;
  bool _computing = true;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final now = DateTime.now();
    final createdAt = now.toIso8601String();

    // 1. 현재 보유 수량 조회
    final holdingsMap = <String, Map<String, dynamic>>{};
    try {
      final accountData = await ApiService.getAccount();
      final marketKey = widget.market == 'KR' ? 'kr' : 'us';
      for (final acc in (accountData[marketKey] as List? ?? [])) {
        for (final h in (acc['holdings'] as List? ?? [])) {
          holdingsMap[h['ticker'] as String] = Map<String, dynamic>.from(h);
        }
      }
    } catch (_) {}

    // 2. 매수/매도 주문 계산 (비중 기준 목표수량 vs 현재수량)
    final allOrders = <_AdjustOrder>[];
    for (final stock in widget.stocks) {
      final ticker = stock['ticker'] as String;
      final name = stock['name'] as String? ?? ticker;
      final weight = (stock['weight'] as num? ?? 0).toDouble();
      final alloc = widget.capital * weight / 100;

      final holding = holdingsMap[ticker];
      final currentQty = holding != null ? (holding['shares'] as num? ?? 0).toInt() : 0;
      final avgPrice = holding != null ? (holding['avg_price'] as num? ?? 0).toDouble() : 0.0;
      final currentPrice = widget.prices[ticker] ??
          (holding != null ? (holding['current_price'] as num? ?? 0).toDouble() : 0.0);

      // 기존 보유: 평단가 기준, 신규: 현재가 기준
      final usePrice = (avgPrice > 0 && currentQty > 0) ? avgPrice : currentPrice;
      final targetQty = usePrice > 0 ? (alloc / usePrice).floor() : 0;

      allOrders.add(_AdjustOrder(
        ticker: ticker,
        name: name,
        weight: weight,
        targetAmt: alloc,
        currentPrice: currentPrice,
        avgPrice: avgPrice > 0 ? avgPrice : currentPrice,
        currentQty: currentQty,
        targetQty: targetQty,
      ));
    }

    final actionOrders = allOrders.where((o) => !o.isOk).toList();
    if (mounted) {
      setState(() {
        _orders = actionOrders;
        _computing = false;
        for (final o in actionOrders) { _status[o.ticker] = 'pending'; }
      });
    }

    // 3. 이전 기간 수익률 계산 (현재 포트폴리오 시가 vs 이전 세션 자본)
    double? pnlPct;
    try {
      double currentPortfolioValue = 0;
      for (final stock in widget.stocks) {
        final ticker = stock['ticker'] as String;
        final holding = holdingsMap[ticker];
        if (holding != null) {
          final shares = (holding['shares'] as num? ?? 0).toDouble();
          final price = widget.prices[ticker] ??
              (holding['current_price'] as num? ?? 0).toDouble();
          currentPortfolioValue += shares * price;
        }
      }
      final prevSession =
          await AppDatabase.getLatestQtSession(widget.strategyId);
      if (prevSession != null && currentPortfolioValue > 0) {
        final prevCapital =
            (prevSession['total_capital'] as num? ?? 0).toDouble();
        if (prevCapital > 0) {
          pnlPct =
              (currentPortfolioValue - prevCapital) / prevCapital * 100;
        }
      }
    } catch (_) {}

    // 4. 세션 생성
    final sessionId = await AppDatabase.insertQtSession({
      'strategy_id': widget.strategyId,
      'session_type': 'rebalance',
      'total_capital': widget.capital,
      'market': widget.market,
      'status': 'active',
      'created_at': createdAt,
      'pnl_pct': pnlPct,
    });

    if (!widget.isOpen) {
      // 장 마감: 서버 예약 + Scheduled 저장
      try {
        await ApiService.rebalance(widget.strategyId);
        for (final o in actionOrders) {
          if (mounted) setState(() { _status[o.ticker] = 'scheduled'; });
        }
      } catch (_) {
        for (final o in actionOrders) {
          if (mounted) setState(() { _status[o.ticker] = 'error'; });
        }
      }
      for (final o in actionOrders) {
        await AppDatabase.insertQtOrderItem({
          'session_id': sessionId,
          'strategy_id': widget.strategyId,
          'ticker': o.ticker,
          'name': o.name,
          'weight': o.weight,
          'allocation_amount': o.targetAmt,
          'planned_qty': o.delta.abs(),
          'planned_price': o.isBuy ? o.currentPrice : o.avgPrice,
          'actual_qty': 0,
          'actual_price': 0.0,
          'status': 'Scheduled',
          'side': o.isBuy ? 'BUY' : 'SELL',
          'created_at': createdAt,
        });
      }
    } else {
      // 장 중: 즉시 주문 (매도 선행, 매수 후행)
      final sells = actionOrders.where((o) => o.isSell).toList();
      final buys = actionOrders.where((o) => o.isBuy).toList();
      for (final o in [...sells, ...buys]) {
        await AppDatabase.insertQtOrderItem({
          'session_id': sessionId,
          'strategy_id': widget.strategyId,
          'ticker': o.ticker,
          'name': o.name,
          'weight': o.weight,
          'allocation_amount': o.targetAmt,
          'planned_qty': o.delta.abs(),
          'planned_price': o.isBuy ? o.currentPrice : o.avgPrice,
          'actual_qty': 0,
          'actual_price': 0.0,
          'status': 'Scheduled',
          'side': o.isBuy ? 'BUY' : 'SELL',
          'created_at': createdAt,
        });
        try {
          await ApiService.placeOrder(
            market: widget.market,
            ticker: o.ticker,
            side: o.isBuy ? 'BUY' : 'SELL',
            quantity: o.delta.abs(),
            price: 0,
            ordDvsn: '01',
          );
          if (mounted) setState(() { _status[o.ticker] = 'done'; });
        } catch (_) {
          if (mounted) setState(() { _status[o.ticker] = 'error'; });
        }
      }
    }

    if (mounted) setState(() { _done = true; });
    await Future.delayed(const Duration(milliseconds: 800));
    if (mounted && Navigator.canPop(context)) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF161B22),
      title: Text(
        _computing
            ? '보유현황 조회 중...'
            : _done
                ? (widget.isOpen ? '주문 완료' : '서버 등록 완료')
                : (widget.isOpen ? '주문 생성 중...' : '서버 등록 중...'),
        style: const TextStyle(fontSize: 15),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_done) const LinearProgressIndicator(
            backgroundColor: Color(0xFF21262D),
            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF58A6FF)),
          ),
          const SizedBox(height: 12),
          if (_computing)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('보유 수량 확인 중...',
                  style: TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
            )
          else if (_orders.isEmpty)
            const Text('변경 필요한 종목이 없습니다',
                style: TextStyle(color: Color(0xFF8B949E), fontSize: 11))
          else
            ..._orders.map((o) {
              final st = _status[o.ticker] ?? 'pending';
              final isBuy = o.isBuy;
              final color = isBuy ? const Color(0xFF2EA043) : const Color(0xFFF85149);
              final IconData icon;
              final Color iconColor;
              if (st == 'done' || st == 'scheduled') {
                icon = Icons.check_circle;
                iconColor = const Color(0xFF2EA043);
              } else if (st == 'error') {
                icon = Icons.error_outline;
                iconColor = const Color(0xFFF85149);
              } else {
                icon = Icons.hourglass_top;
                iconColor = const Color(0xFF8B949E);
              }
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  st == 'pending'
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Color(0xFF8B949E)))
                      : Icon(icon, size: 16, color: iconColor),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(isBuy ? '매수' : '매도',
                        style: TextStyle(
                            color: color, fontSize: 8, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 6),
                  Text(o.ticker,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 4),
                  Expanded(child: Text(
                    '${o.currentQty}→${o.targetQty}주',
                    style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10),
                  )),
                  Text(
                    '${isBuy ? '+' : ''}${o.delta}주',
                    style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ]),
              );
            }),
        ],
      ),
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
                backgroundColor: const Color(0xFF1F6FEB),
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
