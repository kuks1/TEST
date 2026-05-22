import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import '../core/api_service.dart';
import '../core/app_theme.dart';
import '../core/common.dart';
import '../core/database.dart';
import '../models/strategy.dart';
import 'fills_screen.dart';

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});
  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

// ══════════════════════════════════════════════════════════════════
// Data model: StratPlan holds buy list AND sell list together.
// These are always computed as a pair — one can never disappear
// without the other being explicitly cleared too.
// ══════════════════════════════════════════════════════════════════

class _PlanItem {
  final String day, label, side, status;
  final int qty;
  final double price;
  const _PlanItem({
    required this.day,
    required this.label,
    required this.qty,
    required this.price,
    required this.side,
    this.status = 'Scheduled',
  });
}

class _StratPlan {
  final List<_PlanItem> buy;
  final List<_PlanItem> sell;
  const _StratPlan({required this.buy, required this.sell});
  bool get isEmpty => buy.isEmpty && sell.isEmpty;
}

// ══════════════════════════════════════════════════════════════════
// Screen state
// ══════════════════════════════════════════════════════════════════

// QT 세션 데이터 모델
class _QtPlanData {
  final Map<String, dynamic> session;
  final List<Map<String, dynamic>> items;
  const _QtPlanData({required this.session, required this.items});
}

class _OrdersScreenState extends State<OrdersScreen> {
  bool _loading = false;
  String? _error;

  List<_Filled> _krFilled = [];
  List<_Filled> _usFilled = [];

  List<Strategy> _strategies = [];
  Map<String, dynamic>? _accountData;
  Map<String, List<Map<String, dynamic>>> _stratLogs = {};
  // QT 전략: strategy_id → 최신 세션 + 항목
  Map<String, _QtPlanData> _qtPlans = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        AppDatabase.getStrategies(),
        ApiService.getAccount(),
      ]);
      final strategies = results[0] as List<Strategy>;
      final accountData = results[1] as Map<String, dynamic>;

      final logsMap = <String, List<Map<String, dynamic>>>{};
      final qtPlans = <String, _QtPlanData>{};

      for (final s in strategies.where((s) => s.active)) {
        if (s.type == 'kr_value') {
          final session = await AppDatabase.getLatestQtSession(s.strategyId);
          if (session != null) {
            final items = await AppDatabase.getQtOrderItems(session['id'] as int);
            qtPlans[s.strategyId] = _QtPlanData(session: session, items: items);
          }
        } else {
          logsMap[s.strategyId] = await AppDatabase.getTradeLog(s.strategyId);
        }
      }

      if (!mounted) return;
      setState(() {
        _strategies = strategies;
        _accountData = accountData;
        _stratLogs = logsMap;
        _qtPlans = qtPlans;
      });

      await _loadFilled(); // background — for status only
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _loadFilled() async {
    try {
      final now = DateTime.now();
      final sd = _fmtDate(now.subtract(const Duration(days: 30)));
      final ed = _fmtDate(now);
      final results = await Future.wait([
        ApiService.getOrders('KR', startDate: sd, endDate: ed),
        ApiService.getOrders('US', startDate: sd, endDate: ed),
      ]);
      if (!mounted) return;
      setState(() {
        _krFilled = _parseFilled(results[0]);
        _usFilled = _parseFilled(results[1]);
      });
    } catch (_) {
      // silently fail — status defaults to Scheduled
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  List<_Filled> _parseFilled(dynamic raw) =>
      (raw['orders'] as List? ?? [])
          .where((o) => (o as Map<String, dynamic>)['status'] == '체결')
          .map((o) => _Filled.fromMap(o as Map<String, dynamic>))
          .toList();

  String _fmtDate(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  // ── Account lookup ──────────────────────────────────────────────

  Map<String, dynamic>? _findHolding(String ticker, String market) {
    if (_accountData == null) return null;
    final key = market == 'KR' ? 'kr' : 'us';
    for (final acc in (_accountData![key] as List? ?? [])) {
      for (final h in (acc['holdings'] as List? ?? [])) {
        if (h['ticker'] == ticker) return Map<String, dynamic>.from(h);
      }
    }
    return null;
  }

  // ── Plan status ─────────────────────────────────────────────────
  // KR  세션: 09:00 ~ 15:30 KST
  // US  세션: 22:30 KST ~ 익일 05:00 KST (자정 넘김)
  //
  // Scheduled : 세션 시작 전 OR 세션 중 아직 미체결
  // Success   : 세션 내 해당 종목·방향 체결 확인
  // Failed    : 세션 종료 후 미체결

  String _planStatus(Strategy s, _PlanItem item) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    if (s.market == 'KR') {
      final open  = today.add(const Duration(hours: 9));
      final close = today.add(const Duration(hours: 15, minutes: 30));

      if (now.isBefore(open)) return 'Scheduled';

      final matched = _krFilled.any((o) =>
          o.ticker.toUpperCase() == s.symbol.toUpperCase() &&
          o.side == item.side &&
          o.orderedAt.isAfter(open) &&
          o.orderedAt.isBefore(close.add(const Duration(hours: 1))));

      if (matched) return 'Success';
      return now.isAfter(close) ? 'Failed' : 'Scheduled';
    } else {
      // US 야간 세션: 당일 22:30 ~ 익일 05:00 KST
      // · 현재 00:00~04:59 → 어제 22:30에 시작한 세션 중
      // · 현재 05:00~22:29 → 오늘 세션 아직 시작 전 → Scheduled
      // · 현재 22:30~23:59 → 오늘 세션 시작됨
      final DateTime sessionStart, sessionClose;

      if (now.hour < 5) {
        final yesterday = today.subtract(const Duration(days: 1));
        sessionStart = yesterday.add(const Duration(hours: 22, minutes: 30));
        sessionClose = today.add(const Duration(hours: 5));
      } else if (now.hour >= 22 && now.minute >= 30 || now.hour > 22) {
        sessionStart = today.add(const Duration(hours: 22, minutes: 30));
        sessionClose = today.add(const Duration(days: 1, hours: 5));
      } else {
        return 'Scheduled'; // 05:00~22:30 사이 — 세션 없음
      }

      if (now.isBefore(sessionStart)) return 'Scheduled';

      final matched = _usFilled.any((o) =>
          o.ticker.toUpperCase() == s.symbol.toUpperCase() &&
          o.side == item.side &&
          o.orderedAt.isAfter(sessionStart) &&
          o.orderedAt.isBefore(sessionClose));

      if (matched) return 'Success';
      return now.isAfter(sessionClose) ? 'Failed' : 'Scheduled';
    }
  }

  List<_PlanItem> _withStatus(Strategy s, List<_PlanItem> items) =>
      items.map((item) => _PlanItem(
        day: item.day, label: item.label,
        qty: item.qty, price: item.price, side: item.side,
        status: _planStatus(s, item),
      )).toList();

  // ═══════════════════════════════════════════════════════════════
  // Plan computation: each strategy type has separate buy + sell
  // methods. _computePlan assembles them into _StratPlan.
  // ═══════════════════════════════════════════════════════════════

  // ── QT (kr_value) log-based plan ────────────────────────────────

  List<_PlanItem> _qtBuy(Strategy s) {
    final logs = _stratLogs[s.strategyId] ?? [];
    if (logs.isEmpty) return [];
    final sorted = logs.toList()
      ..sort((a, b) => (b['date'] as String? ?? '').compareTo(a['date'] as String? ?? ''));
    final latestDate = (sorted.first['date'] as String? ?? '').substring(0, 10);
    final items = <_PlanItem>[];
    for (final log in sorted) {
      final date = (log['date'] as String? ?? '');
      if (!date.startsWith(latestDate)) break;
      final action = (log['action'] as String? ?? '');
      final event = (log['event'] as String? ?? '');
      final qty = (log['quantity'] as num? ?? 0).toInt();
      final price = (log['price'] as num? ?? 0).toDouble();
      if (action == '리밸런싱') {
        items.add(_PlanItem(
          day: latestDate, label: event,
          qty: 0, price: 0, side: 'BUY', status: 'Scheduled',
        ));
      } else if (action == '매수') {
        items.add(_PlanItem(
          day: latestDate, label: event,
          qty: qty, price: price, side: 'BUY', status: 'Success',
        ));
      }
    }
    return items;
  }

  List<_PlanItem> _qtSell(Strategy s) {
    final logs = _stratLogs[s.strategyId] ?? [];
    if (logs.isEmpty) return [];
    final sorted = logs.toList()
      ..sort((a, b) => (b['date'] as String? ?? '').compareTo(a['date'] as String? ?? ''));
    final latestDate = (sorted.first['date'] as String? ?? '').substring(0, 10);
    final items = <_PlanItem>[];
    for (final log in sorted) {
      final date = (log['date'] as String? ?? '');
      if (!date.startsWith(latestDate)) break;
      final action = (log['action'] as String? ?? '');
      final event = (log['event'] as String? ?? '');
      final qty = (log['quantity'] as num? ?? 0).toInt();
      final price = (log['price'] as num? ?? 0).toDouble();
      if (action == '매도') {
        items.add(_PlanItem(
          day: latestDate, label: event,
          qty: qty, price: price, side: 'SELL', status: 'Success',
        ));
      }
    }
    return items;
  }

  _StratPlan _computePlan(Strategy s) {
    if (s.type == 'kr_value') {
      return _StratPlan(buy: _qtBuy(s), sell: _qtSell(s));
    }
    final holding = _findHolding(s.symbol, s.market);
    final price = (holding?['current_price'] as num? ?? 0).toDouble();
    final avg = (holding?['avg_price'] as num? ?? 0).toDouble();
    final shares = (holding?['shares'] as num? ?? 0).toInt();

    final today = DateTime.now().toIso8601String().substring(0, 10);
    bool buyDone = false, sellDone = false;
    for (final log in _stratLogs[s.strategyId] ?? []) {
      final date = (log['date'] as String? ?? '');
      if (date.startsWith(today)) {
        final action = (log['action'] as String? ?? '');
        if (action.contains('매수') || action == '리밸런싱') buyDone = true;
        if (action.contains('매도')) sellDone = true;
      }
    }

    List<_PlanItem> buy = [], sell = [];
    switch (s.type) {
      case 'v4':
        buy = _v4Buy(s, price, avg, shares, buyDone);
        sell = _v4Sell(s, price, avg, shares, sellDone);
      case 'v1':
        buy = _v1Buy(s, price, avg, shares, buyDone);
        sell = _v1Sell(s, price, avg, shares, sellDone);
      case 'vr':
        buy = _vrBuy(s, price, avg, shares, buyDone);
        sell = _vrSell(s, price, avg, shares, sellDone);
    }

    return _StratPlan(
      buy: _withStatus(s, buy),
      sell: _withStatus(s, sell),
    );
  }

  // ── VR helpers ──────────────────────────────────────────────────

  double _vrG(String mode, int weekNo) {
    if (mode == '인출식') return 20;
    if (mode == '거치식') return 12;
    return (10 + weekNo ~/ 52).toDouble();
  }

  double _vrPoolLimit(String mode, int weekNo, double? override) {
    // Use saved override; if absent, fall back to mode defaults (same as detail screen)
    final effective = override ?? _vrDefaultPoolPct(mode);
    return effective.clamp(0.0, 1.0);
  }

  double _vrDefaultPoolPct(String mode) {
    switch (mode) {
      case '거치식': return 0.50;
      case '인출식': return 0.25;
      default: return 0.75; // 적립식
    }
  }

  double _vrV2(double v1, double pool, double g, double equity, double cf) {
    if (g <= 0) return v1;
    return v1 + (pool / g) + (equity - v1) / (2.0 * math.sqrt(g)) + cf;
  }

  // ── VR buy plan ─────────────────────────────────────────────────

  List<_PlanItem> _vrBuy(Strategy s, double price, double avg, int shares, bool done) {
    final v1 = s.tValue ?? 0.0;
    // First cycle: buy everything at market price
    if (v1 == 0) {
      final qty = price > 0 ? (s.capital / price).floor() : 0;
      return [_PlanItem(day: '첫 사이클', label: '시장가 매수 (전체)',
          qty: qty, price: price, side: 'BUY')];
    }

    final mode = s.vrMode ?? '적립식';
    final weekNo = DateTime.now().difference(s.createdAt).inDays ~/ 7;
    final g = s.vrG != null && s.vrG! > 0 ? s.vrG!.toDouble() : _vrG(mode, weekNo);
    final pool = (s.capital - shares * avg).clamp(0.0, s.capital);
    final equity = shares * price;
    final cf = mode == '적립식' ? s.vrEffectiveDeposit
        : mode == '인출식' ? -s.vrEffectiveWithdrawal.abs() : 0.0;
    final v2 = _vrV2(v1, pool, g, equity, cf);
    final vMin = v2 * (1 - s.vrEffectiveBand);
    final poolLimit = _vrPoolLimit(mode, weekNo, s.vrPoolPct);
    final poolAvail = pool * poolLimit;
    final qty = s.vrQtyPerStep ?? 1;

    final items = <_PlanItem>[];
    if (pool > 0 && poolAvail > 0) {
      double totalCost = 0;
      for (int step = 1; step <= 500; step++) {
        final newShares = shares + step * qty;
        final buyPrice = vMin / newShares;
        if (buyPrice <= 0) break;
        final cost = buyPrice * qty;
        if (totalCost + cost > poolAvail) break;
        items.add(_PlanItem(day: 'Lv.$step', label: '지정가 매수',
            qty: qty, price: buyPrice, side: 'BUY'));
        totalCost += cost;
        if (items.length >= 100) break;
      }
    }
    return items;
  }

  // ── VR sell plan ────────────────────────────────────────────────

  List<_PlanItem> _vrSell(Strategy s, double price, double avg, int shares, bool done) {
    final v1 = s.tValue ?? 0.0;
    if (v1 == 0) return []; // first cycle: nothing to sell yet

    final mode = s.vrMode ?? '적립식';
    final weekNo = DateTime.now().difference(s.createdAt).inDays ~/ 7;
    final g = s.vrG != null && s.vrG! > 0 ? s.vrG!.toDouble() : _vrG(mode, weekNo);
    final pool = (s.capital - shares * avg).clamp(0.0, s.capital);
    final equity = shares * price;
    final cf = mode == '적립식' ? s.vrEffectiveDeposit
        : mode == '인출식' ? -s.vrEffectiveWithdrawal.abs() : 0.0;
    final v2 = _vrV2(v1, pool, g, equity, cf);
    final vMax = v2 * (1 + s.vrEffectiveBand);
    final qty = s.vrQtyPerStep ?? 1;

    final items = <_PlanItem>[];
    for (int step = 1; step <= 500; step++) {
      final remaining = shares - step * qty;
      if (remaining <= 0) break;
      final sellPrice = vMax / remaining;
      items.add(_PlanItem(day: 'Lv.$step', label: '지정가 매도',
          qty: qty, price: sellPrice, side: 'SELL'));
      if (items.length >= 100) break;
    }
    return items;
  }

  // ── V4 buy plan ─────────────────────────────────────────────────

  List<_PlanItem> _v4Buy(Strategy s, double price, double avg, int shares, bool done) {
    final tVal = s.tValue ?? 0.0;
    final starBase = (s.starBase ?? 20).toDouble();
    final starCoeff = s.starCoeff ?? 2.0;
    final divisions = math.max(s.divisions ?? 20, 1);
    final divAmount = (s.calcCapital ?? s.capital) / divisions;
    final isReverse = tVal >= starBase - 1;
    final isRearHalf = !isReverse && tVal >= starBase * 0.5;
    final starPct = (starBase - starCoeff * tVal) / 100.0;
    final starPrice = avg > 0 ? avg * (1 + starPct) : 0.0;
    final buyPoint = starPrice > 0 ? starPrice - 0.01 : 0.0;

    // Reverse mode: quarter buy
    if (isReverse) {
      if (price <= 0) {
        return [_PlanItem(day: '리버스', label: '쿼터매수 @5MA-0.01',
            qty: 0, price: 0, side: 'BUY')];
      }
      final bq = math.max((divAmount * 0.25 / price).floor(), 1);
      return [_PlanItem(day: '리버스', label: '쿼터매수 @5MA-0.01',
          qty: bq, price: price, side: 'BUY')];
    }

    // Very first buy (no position yet)
    if (tVal == 0 && shares == 0) {
      if (price <= 0) {
        return [_PlanItem(day: '첫 매수', label: '시장 LOC @전일종가×1.10',
            qty: 0, price: 0, side: 'BUY')];
      }
      final capPrice = price * 1.10;
      final fq = math.max((divAmount / capPrice).floor(), 1);
      return [_PlanItem(day: '첫 매수', label: '시장 LOC @전일종가×1.10',
          qty: fq, price: capPrice, side: 'BUY')];
    }

    final usePrice = buyPoint > 0 ? buyPoint : price;

    if (!isRearHalf) {
      final half = divAmount * 0.5;
      if (usePrice <= 0) {
        return [_PlanItem(day: '전반전', label: '★별지점 LOC (0.5포션)',
            qty: 0, price: 0, side: 'BUY')];
      }
      return [
        _PlanItem(day: '전반전', label: '★별지점 LOC (0.5포션)',
            qty: math.max((half / usePrice).floor(), 1), price: buyPoint, side: 'BUY'),
        if (avg > 0)
          _PlanItem(day: '전반전', label: '평단가 LOC (0.5포션)',
              qty: math.max((half / avg).floor(), 1), price: avg, side: 'BUY'),
      ];
    } else {
      if (usePrice <= 0) {
        return [_PlanItem(day: '후반전', label: '★별지점 LOC (1포션)',
            qty: 0, price: 0, side: 'BUY')];
      }
      return [_PlanItem(day: '후반전', label: '★별지점 LOC (1포션)',
          qty: math.max((divAmount / usePrice).floor(), 1), price: buyPoint, side: 'BUY')];
    }
  }

  // ── V4 sell plan ────────────────────────────────────────────────

  List<_PlanItem> _v4Sell(Strategy s, double price, double avg, int shares, bool done) {
    final tVal = s.tValue ?? 0.0;
    final starBase = (s.starBase ?? 20).toDouble();
    final starCoeff = s.starCoeff ?? 2.0;
    final isReverse = tVal >= starBase - 1;
    final starPct = (starBase - starCoeff * tVal) / 100.0;
    final starPrice = avg > 0 ? avg * (1 + starPct) : 0.0;

    // Reverse mode: 10% LOC sell
    if (isReverse) {
      if (shares <= 0) {
        return [_PlanItem(day: '리버스', label: '5MA LOC 매도 (10%)',
            qty: 0, price: 0, side: 'SELL')];
      }
      final sq = math.max((shares * 0.10).floor(), 1);
      return [_PlanItem(day: '리버스', label: '5MA LOC 매도 (10%)',
          qty: sq, price: price, side: 'SELL')];
    }

    // No position: show what the sell plan would look like
    if (shares <= 0) {
      return [_PlanItem(day: '쿼터매도', label: '쿼터매도 LOC @별지점',
          qty: 0, price: starPrice > 0 ? starPrice : 0, side: 'SELL')];
    }

    if (avg <= 0 || starPrice <= 0) return [];
    final quarterQty = math.max((shares * 0.25).floor(), 1);
    final finalQty = math.max(shares - quarterQty, 0);

    return [
      _PlanItem(day: '쿼터매도', label: '쿼터매도 LOC @별지점',
          qty: quarterQty, price: starPrice, side: 'SELL'),
      if (finalQty > 0)
        _PlanItem(day: '최종매도', label: '최종매도 @평단×1.20',
            qty: finalQty, price: avg * 1.20, side: 'SELL'),
    ];
  }

  // ── V1 buy plan ─────────────────────────────────────────────────

  List<_PlanItem> _v1Buy(Strategy s, double price, double avg, int shares, bool done) {
    final divisions = s.divisions ?? 10;
    final divAmount = (s.calcCapital ?? s.capital) / divisions;

    // No position: fresh buy
    if (shares <= 0 || avg <= 0) {
      final buyQty = price > 0 ? math.max((divAmount / price).floor(), 1) : 0;
      return [_PlanItem(day: '다음 매수', label: '신규 매수 LOC (1분할)',
          qty: buyQty, price: price, side: 'BUY')];
    }

    // Have position: follow-up buys
    final half = divAmount * 0.5;
    final capPrice = avg - 0.01;
    return [
      _PlanItem(day: '후속매수', label: '평단가 LOC (0.5포션)',
          qty: math.max((half / avg).floor(), 1), price: avg, side: 'BUY'),
      if (capPrice > 0)
        _PlanItem(day: '후속매수', label: '평단-0.01 LOC (0.5포션)',
            qty: math.max((half / capPrice).floor(), 1), price: capPrice, side: 'BUY'),
    ];
  }

  // ── V1 sell plan ────────────────────────────────────────────────

  List<_PlanItem> _v1Sell(Strategy s, double price, double avg, int shares, bool done) {
    final profitPct = s.v1Value ?? 5.0;
    // No position: show sell target placeholder
    if (shares <= 0 || avg <= 0) {
      return [_PlanItem(day: '다음 매도', label: '익절 대기 (+${profitPct.toStringAsFixed(1)}%)',
          qty: 0, price: 0, side: 'SELL')];
    }
    final targetPrice = avg * (1 + profitPct / 100);
    final atTarget = price > 0 && price >= targetPrice;
    return [
      _PlanItem(
        day: '다음 매도',
        label: atTarget
            ? '★매도 (익절 조건 충족)'
            : '익절 대기 (+${profitPct.toStringAsFixed(1)}%)',
        qty: shares,
        price: atTarget ? price : targetPrice,
        side: 'SELL',
      ),
    ];
  }

  // ── Modal ────────────────────────────────────────────────────────

  void _showDetailModal(Strategy s, _StratPlan plan) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 200),
      transitionBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
      pageBuilder: (ctx, _, __) => _StratDetailModal(
        strategy: s,
        plan: plan,
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final active = _strategies.where((s) => s.active).toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        title: const Text('주문현황'),
        actions: [
          IconButton(
            icon: const Icon(Icons.receipt_long_outlined, size: 20),
            tooltip: '체결내역',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FillsScreen()),
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(child: SizedBox(width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))),
            )
          else
            IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _refresh),
        ],
      ),
      body: _error != null
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(_error!, style: const TextStyle(color: Color(0xFFF85149))),
              const SizedBox(height: 12),
              ElevatedButton(onPressed: _refresh, child: const Text('다시 시도')),
            ]))
          : active.isEmpty
              ? const Center(child: Text('활성 전략이 없습니다',
                  style: TextStyle(color: Color(0xFF8B949E))))
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: active.length,
                    itemBuilder: (_, i) {
                      final s = active[i];
                      if (s.type == 'kr_value') {
                        final qtPlan = _qtPlans[s.strategyId];
                        return _QtPlanCard(strategy: s, data: qtPlan);
                      }
                      final plan = _computePlan(s);
                      return _StratPlanCard(
                        strategy: s,
                        plan: plan,
                        onTap: () => _showDetailModal(s, plan),
                      );
                    },
                  ),
                ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// QT 전략 주문 현황 카드 — 세션 + 항목 테이블
// ══════════════════════════════════════════════════════════════════

class _QtPlanCard extends StatefulWidget {
  final Strategy strategy;
  final _QtPlanData? data;
  const _QtPlanCard({required this.strategy, required this.data});
  @override
  State<_QtPlanCard> createState() => _QtPlanCardState();
}

class _QtPlanCardState extends State<_QtPlanCard> {
  bool _expanded = false;
  static const _preview = 2;

  String _typeLabel(String t) => switch (t) {
        'create' => '전략 생성',
        'rebalance' => '재밸런싱',
        'modify' => '비중 조절',
        _ => t,
      };

  String _fmtMoney(double v, String market) =>
      market == 'KR' ? Fmt.krw(v) : Fmt.usd(v);

  String _fmtDate(String iso) {
    try {
      return iso.substring(0, 16).replaceFirst('T', ' ');
    } catch (_) {
      return iso;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.strategy;
    final d = widget.data;
    final items = d?.items ?? [];

    final hasPeek = items.length > _preview;
    final visibleItems = _expanded ? items : items.take(_preview).toList();
    final peekItem = (!_expanded && hasPeek) ? items[_preview] : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(children: [
        // 헤더
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          child: Row(children: [
            Container(width: 3, height: 13,
                decoration: BoxDecoration(color: AppTheme.accent, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 8),
            Text(s.strategyId,
                style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
            _Badge(s.typeLabel),
            const SizedBox(width: 4),
            _Badge(s.market),
            const Spacer(),
            if (d != null) ...[
              Text(_typeLabel(d.session['session_type'] as String? ?? ''),
                  style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
              const SizedBox(width: 6),
              Text(_fmtDate(d.session['created_at'] as String? ?? ''),
                  style: const TextStyle(color: Color(0xFF6E7681), fontSize: 9)),
            ],
          ]),
        ),
        const Divider(color: Color(0xFF21262D), height: 1),

        if (d == null || items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('주문 계획 없음', style: TextStyle(color: Color(0xFF6E7681), fontSize: 11)),
          )
        else ...[
          // 컬럼 헤더
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            child: Row(children: const [
              SizedBox(width: 120, child: Text('종목', style: TextStyle(color: Color(0xFF6E7681), fontSize: 10))),
              Expanded(child: Row(children: [
                SizedBox(width: 76, child: Text('비중/할당', textAlign: TextAlign.right, style: TextStyle(color: Color(0xFF6E7681), fontSize: 10))),
                SizedBox(width: 8),
                SizedBox(width: 60, child: Text('계획 수량', textAlign: TextAlign.right, style: TextStyle(color: Color(0xFF6E7681), fontSize: 10))),
                SizedBox(width: 8),
                SizedBox(width: 60, child: Text('실행 수량', textAlign: TextAlign.right, style: TextStyle(color: Color(0xFF6E7681), fontSize: 10))),
              ])),
            ]),
          ),
          const Divider(color: Color(0xFF21262D), height: 1),
          ...visibleItems.map((item) => _QtItemRow(item: item, market: s.market)),
          if (peekItem != null)
            ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.white, Colors.transparent],
                stops: [0.15, 1.0],
              ).createShader(bounds),
              blendMode: BlendMode.dstIn,
              child: _QtItemRow(item: peekItem, market: s.market),
            ),
          if (hasPeek)
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 2, 0, 6),
                child: Center(
                  child: Icon(
                    _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 14,
                    color: const Color(0xFF484F58),
                  ),
                ),
              ),
            ),
          // 세션 합계
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
            child: Row(children: [
              const Expanded(child: Text('합계', style: TextStyle(color: Color(0xFF8B949E), fontSize: 10))),
              Text(
                _fmtMoney(
                  items.fold(0.0, (sum, i) => sum + (i['allocation_amount'] as num? ?? 0).toDouble()),
                  s.market,
                ),
                style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 10, fontWeight: FontWeight.w600),
              ),
            ]),
          ),
        ],
      ]),
    );
  }
}

class _QtItemRow extends StatelessWidget {
  final Map<String, dynamic> item;
  final String market;
  const _QtItemRow({required this.item, required this.market});

  String _fmt(double v) => market == 'KR' ? Fmt.krw(v) : Fmt.usd(v);

  @override
  Widget build(BuildContext context) {
    final ticker = item['ticker'] as String? ?? '';
    final name = item['name'] as String? ?? ticker;
    final weight = (item['weight'] as num? ?? 0).toDouble();
    final alloc = (item['allocation_amount'] as num? ?? 0).toDouble();
    final plannedQty = item['planned_qty'] as int? ?? 0;
    final plannedPrice = (item['planned_price'] as num? ?? 0).toDouble();
    final actualQty = item['actual_qty'] as int? ?? 0;
    final actualPrice = (item['actual_price'] as num? ?? 0).toDouble();
    final side = (item['side'] as String? ?? 'BUY').toUpperCase();
    final status = item['status'] as String? ?? 'Scheduled';

    final isBuy = side == 'BUY';
    final sideColor = isBuy ? const Color(0xFF2EA043) : const Color(0xFFF85149);

    final (statusColor, statusText) = switch (status) {
      'Success' => (const Color(0xFF2EA043), 'Success'),
      'Failed' => (const Color(0xFFF85149), 'Failed'),
      'Stopped' => (const Color(0xFF484F58), 'Stopped'),
      _ => (const Color(0xFF8B949E), 'Sched'),
    };

    final plannedTotal = plannedQty * plannedPrice;
    final actualTotal = actualQty * actualPrice;

    return Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 0, 6),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFF21262D))),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          // ── 고정 왼쪽: 사이드 뱃지 + 회사명(bold) + 티커(small) ──
          SizedBox(
            width: 120,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                  decoration: BoxDecoration(
                      color: sideColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(3)),
                  child: Text(isBuy ? '매수' : '매도',
                      style: TextStyle(
                          color: sideColor, fontSize: 8, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(name,
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFFE6EDF3)),
                      overflow: TextOverflow.ellipsis),
                ),
              ]),
              Padding(
                padding: const EdgeInsets.only(left: 1),
                child: Text(ticker,
                    style: const TextStyle(color: Color(0xFF6E7681), fontSize: 9)),
              ),
            ]),
          ),
          // ── 오른쪽: 2열 완전 표시 + 3열 그라데이션 ──
          Expanded(
            child: ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Colors.white, Colors.white, Colors.transparent],
                stops: [0.0, 0.60, 1.0],
              ).createShader(bounds),
              blendMode: BlendMode.dstIn,
              child: Row(children: [
                // 열 1: 비중 + 할당금액
                SizedBox(
                  width: 76,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('${weight.toStringAsFixed(0)}%',
                        style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
                    Text(_fmt(alloc),
                        style: const TextStyle(color: Color(0xFF6E7681), fontSize: 8)),
                  ]),
                ),
                const SizedBox(width: 8),
                // 열 2: 계획 수량
                SizedBox(
                  width: 60,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('${plannedQty}주',
                        style: const TextStyle(
                            color: Color(0xFFE6EDF3),
                            fontSize: 10,
                            fontWeight: FontWeight.w600)),
                    if (plannedTotal > 0)
                      Text(_fmt(plannedTotal),
                          style: const TextStyle(color: Color(0xFF6E7681), fontSize: 8)),
                  ]),
                ),
                const SizedBox(width: 8),
                // 열 3: 실행 수량 (그라데이션 fade)
                SizedBox(
                  width: 60,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    if (actualQty > 0) ...[
                      Text('${actualQty}주',
                          style: TextStyle(
                              color: statusColor, fontSize: 10, fontWeight: FontWeight.w600)),
                      if (actualTotal > 0)
                        Text(_fmt(actualTotal),
                            style: const TextStyle(color: Color(0xFF6E7681), fontSize: 8)),
                    ] else
                      const Text('-',
                          style: TextStyle(color: Color(0xFF484F58), fontSize: 10)),
                  ]),
                ),
                const SizedBox(width: 8),
                // 열 4: 상태 (완전히 fade됨 — 터치 시 웹뷰에서 확인)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(statusText,
                      style: TextStyle(
                          color: statusColor, fontSize: 8, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 10),
              ]),
            ),
          ),
        ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Strategy plan card: takes _StratPlan and shows 2 columns
// ══════════════════════════════════════════════════════════════════

class _StratPlanCard extends StatelessWidget {
  final Strategy strategy;
  final _StratPlan plan;
  final VoidCallback onTap;

  const _StratPlanCard({
    required this.strategy,
    required this.plan,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final s = strategy;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: Column(children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
            child: Row(children: [
              Container(width: 3, height: 13,
                decoration: BoxDecoration(
                  color: AppTheme.accent,
                  borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 8),
              Text(s.strategyId,
                  style: const TextStyle(
                      color: Color(0xFFE6EDF3),
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              _Badge(s.typeLabel),
              const SizedBox(width: 4),
              _Badge(s.market),
              const Spacer(),
              const Icon(Icons.chevron_right, size: 14, color: Color(0xFF484F58)),
            ]),
          ),
          const Divider(color: Color(0xFF21262D), height: 1),
          // 2-column: BUY | SELL
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _PlanColumn(
                label: '매수',
                color: const Color(0xFF2EA043),
                items: plan.buy,
                market: s.market,
              )),
              const VerticalDivider(color: Color(0xFF21262D), width: 1),
              Expanded(child: _PlanColumn(
                label: '매도',
                color: const Color(0xFFF85149),
                items: plan.sell,
                market: s.market,
              )),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Plan column: shows up to 3 items + gradient peek at item 4
// ══════════════════════════════════════════════════════════════════

class _PlanColumn extends StatelessWidget {
  final String label;
  final Color color;
  final List<_PlanItem> items;
  final String market;

  static const _preview = 2;

  const _PlanColumn({
    required this.label,
    required this.color,
    required this.items,
    required this.market,
  });

  @override
  Widget build(BuildContext context) {
    final hasPeek = items.length > _preview;

    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Column header
        Row(children: [
          Container(width: 3, height: 11,
              decoration: BoxDecoration(
                  color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w700)),
          const SizedBox(width: 4),
          Text('${items.length}건',
              style: const TextStyle(color: Color(0xFF6E7681), fontSize: 9)),
        ]),
        const SizedBox(height: 6),

        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text('계획 없음',
                style: TextStyle(color: Color(0xFF57606A), fontSize: 10)),
          )
        else ...[
          // Items 1-2: fully visible
          for (final item in items.take(_preview))
            _PlanRow(item: item, market: market),

          // Item 3: gradient "peek" — shows there's more
          if (hasPeek)
            ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.white, Colors.transparent],
                stops: [0.15, 1.0],
              ).createShader(bounds),
              blendMode: BlendMode.dstIn,
              child: _PlanRow(item: items[_preview], market: market),
            ),
        ],
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Detail modal — 2-column blur modal showing all buy + sell items
// ══════════════════════════════════════════════════════════════════

class _StratDetailModal extends StatelessWidget {
  final Strategy strategy;
  final _StratPlan plan;

  const _StratDetailModal({
    required this.strategy,
    required this.plan,
  });

  @override
  Widget build(BuildContext context) {
    final s = strategy;
    final screenH = MediaQuery.of(context).size.height;

    return Material(
      color: Colors.transparent,
      child: Stack(children: [
        // Blurred dimmed backdrop — tap to dismiss
        GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
            child: Container(
              color: const Color(0x74000000),
              width: double.infinity,
              height: double.infinity,
            ),
          ),
        ),
        // Modal panel — taps absorbed
        SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              child: GestureDetector(
                onTap: () {},
                child: Container(
                  constraints: BoxConstraints(maxHeight: screenH * 0.80),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161B22),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF30363D)),
                    boxShadow: [BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 28, offset: const Offset(0, 10),
                    )],
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    // Header
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                      child: Row(children: [
                        Container(width: 3, height: 14,
                            decoration: BoxDecoration(
                                color: AppTheme.accent,
                                borderRadius: BorderRadius.circular(2))),
                        const SizedBox(width: 8),
                        Text(s.strategyId,
                            style: const TextStyle(
                                color: Color(0xFFE6EDF3),
                                fontSize: 14, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 6),
                        _Badge(s.typeLabel),
                        const SizedBox(width: 4),
                        _Badge(s.market),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => Navigator.of(context).pop(),
                          child: const Icon(Icons.close,
                              size: 18, color: Color(0xFF8B949E)),
                        ),
                      ]),
                    ),
                    const Divider(color: Color(0xFF30363D), height: 1),
                    // 2-column scrollable body
                    Flexible(
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: _DetailColumn(
                              label: '매수',
                              color: const Color(0xFF2EA043),
                              items: plan.buy,
                              market: s.market,
                            )),
                            const VerticalDivider(
                                color: Color(0xFF21262D), width: 1),
                            Expanded(child: _DetailColumn(
                              label: '매도',
                              color: const Color(0xFFF85149),
                              items: plan.sell,
                              market: s.market,
                            )),
                          ],
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _DetailColumn extends StatelessWidget {
  final String label;
  final Color color;
  final List<_PlanItem> items;
  final String market;

  const _DetailColumn({
    required this.label,
    required this.color,
    required this.items,
    required this.market,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
          child: Row(children: [
            Container(width: 3, height: 11,
                decoration: BoxDecoration(
                    color: color, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    color: color, fontSize: 11, fontWeight: FontWeight.w700)),
            const SizedBox(width: 4),
            Text('${items.length}건',
                style: const TextStyle(color: Color(0xFF6E7681), fontSize: 9)),
          ]),
        ),
        const Divider(color: Color(0xFF21262D), height: 1),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: items.isEmpty
                  ? [const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('계획 없음',
                          style: TextStyle(
                              color: Color(0xFF57606A), fontSize: 10)))]
                  : items.map((item) => _PlanRow(item: item, market: market)).toList(),
            ),
          ),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Shared small widgets
// ══════════════════════════════════════════════════════════════════

class _Badge extends StatelessWidget {
  final String label;
  final Color? color;
  final Color? textColor;
  const _Badge(this.label, {this.color, this.textColor});
  @override
  Widget build(BuildContext context) {
    final tc = textColor ?? AppTheme.accent;
    final bg = color ?? AppTheme.accent.withValues(alpha: 0.13);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(label, style: TextStyle(fontSize: 9, color: tc)),
    );
  }
}

class _PlanRow extends StatelessWidget {
  final _PlanItem item;
  final String market;
  const _PlanRow({required this.item, required this.market});

  @override
  Widget build(BuildContext context) {
    final isBuy = item.side == 'BUY';
    final sideColor =
        isBuy ? const Color(0xFF2EA043) : const Color(0xFFF85149);
    // qty=0 & price=0 → placeholder item (no live data yet)
    final isPlaceholder = item.qty == 0 && item.price == 0;
    final priceStr = item.price > 0
        ? (market == 'KR' ? Fmt.krw(item.price) : Fmt.usd(item.price))
        : isPlaceholder ? '-' : '시장가';

    final (statusColor, statusText) = switch (item.status) {
      'Success' => (const Color(0xFF2EA043), 'Success'),
      'Failed' => (const Color(0xFFF85149), 'Failed'),
      _ => (const Color(0xFF6E7681), 'Scheduled'),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1117),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF21262D)),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          decoration: BoxDecoration(
              color: sideColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(3)),
          child: Text(isBuy ? '매수' : '매도',
              style: TextStyle(
                  color: sideColor, fontSize: 8, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 5),
        Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Text(item.label,
              style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10),
              overflow: TextOverflow.ellipsis),
          if (!isPlaceholder)
            Row(children: [
              Text('${item.qty}주',
                  style: const TextStyle(
                      color: Color(0xFFE6EDF3),
                      fontSize: 10,
                      fontWeight: FontWeight.w500)),
              const SizedBox(width: 4),
              Text(priceStr,
                  style: const TextStyle(color: Color(0xFF6E7681), fontSize: 9)),
            ])
          else
            Text(priceStr,   // "-"
                style: const TextStyle(color: Color(0xFF57606A), fontSize: 9)),
        ])),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(statusText,
              style: TextStyle(
                  color: statusColor,
                  fontSize: 8,
                  fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }
}

// Minimal filled order reference — used only for _planStatus computation
class _Filled {
  final String ticker, side;
  final DateTime orderedAt;
  const _Filled({
    required this.ticker,
    required this.side,
    required this.orderedAt,
  });
  factory _Filled.fromMap(Map<String, dynamic> m) => _Filled(
        ticker: m['ticker']?.toString() ?? '',
        side: m['side']?.toString() ?? '',
        orderedAt: DateTime.tryParse(
          (m['ordered_at']?.toString() ?? '').replaceFirst(' ', 'T'),
        ) ?? DateTime(2000),
      );
}
