import 'dart:async';
import 'dart:math' as math;
import 'api_service.dart';
import 'common.dart';
import 'database.dart';

/// 5분마다 QT 주문 체결 확인, VR V값 기록, MM 사이클 종료 감지
class QTMonitor {
  static Timer? _timer;

  static void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => _tick());
  }

  static void stop() => _timer?.cancel();

  static String _fmtDate(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  static Future<void> _tick() async {
    try {
      await _checkQtSessions();
      await _checkVrStrategies();
      await _checkMmCycleEnd();
    } catch (_) {}
  }

  // ── QT 세션 체결 확인 ─────────────────────────────────────────────

  static Future<void> _checkQtSessions() async {
    final items = await AppDatabase.getScheduledQtItems();
    if (items.isEmpty) return;

    final now = DateTime.now();
    final bySession = <int, List<Map<String, dynamic>>>{};
    for (final item in items) {
      final sid = item['session_id'] as int;
      bySession.putIfAbsent(sid, () => []).add(Map<String, dynamic>.from(item));
    }

    for (final entry in bySession.entries) {
      final sessionId = entry.key;
      final sessionItems = entry.value;

      final session = await AppDatabase.getQtSession(sessionId);
      if (session == null) continue;
      if ((session['status'] as String?) == 'stopped') continue;

      final market = session['market'] as String;
      final createdAt =
          DateTime.tryParse(session['created_at'] as String? ?? '') ?? now;

      // 24시간 초과 → 세션 정지
      if (now.difference(createdAt).inHours >= 24) {
        await AppDatabase.stopQtSession(sessionId);
        for (final item in sessionItems) {
          await AppDatabase.updateQtOrderItem(item['id'] as int, {
            'status': 'Stopped',
            'updated_at': now.toIso8601String(),
          });
        }
        continue;
      }

      final isOpen = market == 'KR' ? MarketClock.isKrOpen : MarketClock.isUsOpen;

      if (!isOpen) {
        if (_sessionEndedToday(market, now)) {
          for (final item in sessionItems) {
            if ((item['status'] as String?) == 'Scheduled') {
              await AppDatabase.updateQtOrderItem(item['id'] as int, {
                'status': 'Failed',
                'updated_at': now.toIso8601String(),
              });
            }
          }
        }
        continue;
      }

      await _processOpenMarket(sessionItems, session, market, now);
    }
  }

  static bool _sessionEndedToday(String market, DateTime now) {
    if (market == 'KR') {
      final close = DateTime(now.year, now.month, now.day, 15, 30);
      return now.isAfter(close);
    } else {
      return now.hour >= 5 && now.hour < 22;
    }
  }

  static Future<void> _processOpenMarket(
    List<Map<String, dynamic>> items,
    Map<String, dynamic> session,
    String market,
    DateTime now,
  ) async {
    Map<String, dynamic>? accountData;
    try {
      accountData = await ApiService.getAccount();
    } catch (_) {
      return;
    }

    final marketKey = market == 'KR' ? 'kr' : 'us';
    final holdingsMap = <String, Map<String, dynamic>>{};
    for (final acc in (accountData[marketKey] as List? ?? [])) {
      for (final h in (acc['holdings'] as List? ?? [])) {
        holdingsMap[h['ticker'] as String] = Map<String, dynamic>.from(h);
      }
    }

    List<Map<String, dynamic>> filledOrders = [];
    try {
      final ordersData = await ApiService.getOrders(
        market,
        startDate: _fmtDate(now.subtract(const Duration(days: 1))),
        endDate: _fmtDate(now),
      );
      filledOrders = (ordersData['orders'] as List? ?? [])
          .where((o) => (o as Map<String, dynamic>)['status'] == '체결')
          .map((o) => o as Map<String, dynamic>)
          .toList();
    } catch (_) {}

    for (final item in items) {
      if ((item['status'] as String?) != 'Scheduled') continue;

      final ticker = item['ticker'] as String;
      final side = (item['side'] as String? ?? 'BUY').toUpperCase();
      final allocationAmount = (item['allocation_amount'] as num).toDouble();
      final createdAt = item['created_at'] as String? ?? '';

      final matchFill = filledOrders.where((f) {
        final fTicker = (f['ticker'] as String? ?? '').toUpperCase();
        final fSide = (f['side'] as String? ?? '').toUpperCase();
        final fTime = (f['ordered_at'] ?? f['created_at'] ?? '').toString();
        return fTicker == ticker.toUpperCase() &&
            fSide == side &&
            fTime.compareTo(createdAt) >= 0;
      }).toList();

      if (matchFill.isNotEmpty) {
        final fill = matchFill.last;
        final actualQty =
            (fill['quantity'] as num? ?? item['planned_qty']).toInt();
        final actualPrice =
            (fill['price'] as num? ?? item['planned_price']).toDouble();

        await AppDatabase.updateQtOrderItem(item['id'] as int, {
          'status': 'Success',
          'actual_qty': actualQty,
          'actual_price': actualPrice,
          'updated_at': now.toIso8601String(),
        });

        await AppDatabase.insertLog({
          'strategy_id': item['strategy_id'],
          'date': now.toIso8601String().substring(0, 10),
          'event': '$ticker ${item['name']} ${actualQty}주',
          'action': side == 'BUY' ? '매수' : '매도',
          'quantity': actualQty.toDouble(),
          'price': actualPrice,
          'pnl_pct': 0.0,
          'created_at': now.toIso8601String(),
        });

        // 세션 전체 완료 확인 → 수익률 기록
        await _checkSessionComplete(session, accountData, market, now);
      } else {
        // 미체결 → 재주문 (매수만)
        if (side != 'BUY') continue;
        double currentPrice = 0;
        try {
          final quote = await ApiService.getQuote(ticker, market);
          currentPrice = (quote['price'] as num? ??
                  quote['current_price'] as num? ??
                  0)
              .toDouble();
        } catch (_) {
          continue;
        }
        if (currentPrice <= 0) continue;

        final used = (item['actual_qty'] as int? ?? 0) *
            (item['actual_price'] as num? ?? 0).toDouble();
        final remaining = allocationAmount - used;
        final newQty = remaining > 0 ? (remaining / currentPrice).floor() : 0;
        if (newQty <= 0) continue;

        try {
          await ApiService.placeOrder(
            market: market,
            ticker: ticker,
            side: side,
            quantity: newQty,
            price: 0,
            ordDvsn: '01',
          );
          await AppDatabase.updateQtOrderItem(item['id'] as int, {
            'planned_qty': newQty,
            'planned_price': currentPrice,
            'updated_at': now.toIso8601String(),
          });
        } catch (_) {}
      }
    }
  }

  /// 세션 내 모든 항목이 Success → 총 수익률 기록
  static Future<void> _checkSessionComplete(
    Map<String, dynamic> session,
    Map<String, dynamic> accountData,
    String market,
    DateTime now,
  ) async {
    final sessionId = session['id'] as int;
    final allItems = await AppDatabase.getQtOrderItems(sessionId);
    if (allItems.isEmpty) return;
    final allSuccess = allItems.every((i) {
      final st = i['status'] as String? ?? '';
      return st == 'Success' || st == 'Failed' || st == 'Stopped';
    });
    if (!allSuccess) return;

    // 이미 완료 기록이 있는지 확인
    final stratId = session['strategy_id'] as String;
    final logs = await AppDatabase.getTradeLog(stratId);
    final alreadyLogged = logs.any((l) =>
        (l['action'] as String? ?? '') == '리밸런싱 완료' &&
        (l['created_at'] as String? ?? '').startsWith(now.toIso8601String().substring(0, 10)));
    if (alreadyLogged) return;

    final capital = (session['total_capital'] as num? ?? 0).toDouble();

    // 현재 포트폴리오 평가금액
    final marketKey = market == 'KR' ? 'kr' : 'us';
    double currentValue = 0;
    for (final acc in (accountData[marketKey] as List? ?? [])) {
      for (final h in (acc['holdings'] as List? ?? [])) {
        final shares = (h['shares'] as num? ?? 0).toDouble();
        final price = (h['current_price'] as num? ?? 0).toDouble();
        currentValue += shares * price;
      }
    }

    final pnlPct = capital > 0 ? (currentValue - capital) / capital * 100 : 0.0;

    await AppDatabase.insertLog({
      'strategy_id': stratId,
      'date': now.toIso8601String().substring(0, 10),
      'event': '리밸런싱 완료 (평가금액 ${market == 'KR' ? Fmt.krw(currentValue) : Fmt.usd(currentValue)})',
      'action': '리밸런싱 완료',
      'quantity': 0.0,
      'price': currentValue,
      'pnl_pct': pnlPct,
      'created_at': now.toIso8601String(),
    });

    await AppDatabase.stopQtSession(sessionId);
  }

  // ── VR 전략 V값 주기적 기록 (2주 간격) ───────────────────────────

  static Future<void> _checkVrStrategies() async {
    final strategies = await AppDatabase.getStrategies();
    final vrStrategies = strategies.where((s) => s.type == 'vr' && s.active).toList();
    if (vrStrategies.isEmpty) return;

    final now = DateTime.now();
    Map<String, dynamic>? accountData;
    try {
      accountData = await ApiService.getAccount();
    } catch (_) {
      return;
    }

    for (final s in vrStrategies) {
      final logs = await AppDatabase.getTradeLog(s.strategyId);
      final vLogs = logs.where((l) => (l['action'] as String? ?? '') == 'V값 기록').toList();

      // 마지막 V값 기록 이후 14일(2주) 경과 여부
      DateTime? lastVLog;
      if (vLogs.isNotEmpty) {
        lastVLog = DateTime.tryParse(vLogs.first['created_at'] as String? ?? '');
      }

      final daysSinceLast = lastVLog == null
          ? 999
          : now.difference(lastVLog).inDays;

      if (daysSinceLast < 14) continue;

      // 현재 보유 수량 + 가격
      final marketKey = s.market == 'KR' ? 'kr' : 'us';
      double shares = 0, avgPrice = 0, currentPrice = 0;
      for (final acc in ((accountData[marketKey]) as List? ?? [])) {
        for (final h in (acc['holdings'] as List? ?? [])) {
          if ((h['ticker'] as String? ?? '') == s.symbol) {
            shares = (h['shares'] as num? ?? 0).toDouble();
            avgPrice = (h['avg_price'] as num? ?? 0).toDouble();
            currentPrice = (h['current_price'] as num? ?? 0).toDouble();
          }
        }
      }

      // V값 계산
      final weekNo = now.difference(s.createdAt).inDays ~/ 7;
      final mode = s.vrMode ?? '적립식';
      final g = s.vrG != null && s.vrG! > 0
          ? s.vrG!.toDouble()
          : _vrG(mode, weekNo);
      final pool = (s.capital - shares * avgPrice).clamp(0.0, s.capital);
      final equity = shares * currentPrice;
      final cf = mode == '적립식'
          ? s.vrEffectiveDeposit
          : mode == '인출식'
              ? -s.vrEffectiveWithdrawal.abs()
              : 0.0;
      final v1 = s.tValue ?? 0.0;
      final v2 = _vrV2(v1, pool, g, equity, cf);
      final portfolioValue = equity + pool;

      await AppDatabase.insertLog({
        'strategy_id': s.strategyId,
        'date': now.toIso8601String().substring(0, 10),
        'event':
            'V1=${_fmt(v1, s.market)} V2=${_fmt(v2, s.market)} 평가=${_fmt(portfolioValue, s.market)}',
        'action': 'V값 기록',
        'quantity': 0.0,
        'price': portfolioValue,
        'pnl_pct': s.capital > 0
            ? (portfolioValue - s.capital) / s.capital * 100
            : 0.0,
        'created_at': now.toIso8601String(),
      });
    }
  }

  static double _vrG(String mode, int weekNo) {
    if (mode == '인출식') return 20;
    if (mode == '거치식') return 12;
    return (10 + weekNo ~/ 52).toDouble();
  }

  static double _vrV2(
      double v1, double pool, double g, double equity, double cf) {
    if (g <= 0) return v1;
    return v1 + (pool / g) + (equity - v1) / (2.0 * math.sqrt(g)) + cf;
  }

  static String _fmt(double v, String market) =>
      market == 'KR' ? Fmt.krw(v) : Fmt.usd(v);

  // ── MM(V1) 사이클 종료 감지 ───────────────────────────────────────

  static Future<void> _checkMmCycleEnd() async {
    final strategies = await AppDatabase.getStrategies();
    final mmStrategies =
        strategies.where((s) => s.type == 'v1' && s.active).toList();
    if (mmStrategies.isEmpty) return;

    Map<String, dynamic>? accountData;
    try {
      accountData = await ApiService.getAccount();
    } catch (_) {
      return;
    }

    final now = DateTime.now();

    for (final s in mmStrategies) {
      final logs = await AppDatabase.getTradeLog(s.strategyId);
      if (logs.isEmpty) continue;

      // 마지막 기록이 매도이고 오늘 발생한 경우에만 확인
      final lastLog = logs.first;
      final lastAction = lastLog['action'] as String? ?? '';
      final lastDate = lastLog['date'] as String? ?? '';
      final today = now.toIso8601String().substring(0, 10);
      if (lastAction != '매도' || !lastDate.startsWith(today)) continue;

      // 이미 사이클 종료 기록 있는지
      final alreadyClosed = logs.any((l) =>
          (l['action'] as String? ?? '') == '사이클 종료' &&
          (l['date'] as String? ?? '').startsWith(today));
      if (alreadyClosed) continue;

      // 현재 보유 수량 확인
      final marketKey = s.market == 'KR' ? 'kr' : 'us';
      int shares = 0;
      for (final acc in ((accountData[marketKey]) as List? ?? [])) {
        for (final h in (acc['holdings'] as List? ?? [])) {
          if ((h['ticker'] as String? ?? '') == s.symbol) {
            shares = (h['shares'] as num? ?? 0).toInt();
          }
        }
      }
      if (shares > 0) continue; // 아직 보유 중

      // 사이클 수익 계산 (trade_log에서 마지막 '사이클 종료' 이후 매수/매도 합산)
      final cycleStartIdx = logs.indexWhere(
          (l) => (l['action'] as String? ?? '') == '사이클 종료');
      final cycleLogs = cycleStartIdx >= 0
          ? logs.sublist(0, cycleStartIdx)
          : logs;

      double totalBuy = 0, totalSell = 0;
      for (final l in cycleLogs) {
        final action = l['action'] as String? ?? '';
        final qty = (l['quantity'] as num? ?? 0).toDouble();
        final price = (l['price'] as num? ?? 0).toDouble();
        if (action == '매수') totalBuy += qty * price;
        if (action == '매도') totalSell += qty * price;
      }
      final cycleProfit = totalSell - totalBuy;
      final profitPct =
          totalBuy > 0 ? cycleProfit / totalBuy * 100 : 0.0;

      await AppDatabase.insertLog({
        'strategy_id': s.strategyId,
        'date': today,
        'event':
            '사이클 종료 · 매수합계 ${_fmt(totalBuy, s.market)} → 매도합계 ${_fmt(totalSell, s.market)}',
        'action': '사이클 종료',
        'quantity': 0.0,
        'price': cycleProfit,
        'pnl_pct': profitPct,
        'created_at': now.toIso8601String(),
      });
    }
  }
}
