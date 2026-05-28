import 'dart:async';
import 'dart:math' as math;
import 'api_service.dart';
import 'common.dart';
import 'database.dart';
import '../models/strategy.dart';

/// 5분마다 QT 주문 체결 확인, VR V값 기록, MM 사이클 종료 감지, 매도 예약 실행
class QTMonitor {
  static Timer? _timer;
  static String? _lastSyncDateKr;
  static String? _lastSyncDateUs;

  static void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => _tick());
  }

  static void stop() => _timer?.cancel();

  /// 앱 시작·새로고침 시 호출: VR/MM 오늘 주문 생성 + 장마감 후라면 즉시 상태 동기화
  static Future<void> checkOnDemand() async {
    try {
      final now = DateTime.now();
      final today = now.toIso8601String().substring(0, 10);
      await _ensureVrFirstCycleOrders(now, today);
      await _ensureMmDailyOrders(now, today, force: true);
      if (_isAfterClose30('KR', now) && _lastSyncDateKr != today) {
        _lastSyncDateKr = today;
        await _syncStrategyOrderStatuses('KR', now, today);
        await _checkVrStrategies();
        await _checkMmCycleEnd();
      }
      if (_isAfterClose30('US', now) && _lastSyncDateUs != today) {
        _lastSyncDateUs = today;
        await _syncStrategyOrderStatuses('US', now, today);
        await _checkVrStrategies();
        await _checkMmCycleEnd();
      }
    } catch (_) {}
  }

  static String _fmtDate(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  static Future<void> _tick() async {
    try {
      await _checkQtSessions();
      await _checkPendingSells();
      await _checkV4LocReset();

      final now = DateTime.now();
      final today = now.toIso8601String().substring(0, 10);

      await _ensureVrFirstCycleOrders(now, today);
      await _ensureMmDailyOrders(now, today);

      if (_isAfterClose30('KR', now) && _lastSyncDateKr != today) {
        _lastSyncDateKr = today;
        await _syncStrategyOrderStatuses('KR', now, today);
        await _checkVrStrategies();
        await _checkMmCycleEnd();
      }
      if (_isAfterClose30('US', now) && _lastSyncDateUs != today) {
        _lastSyncDateUs = today;
        await _syncStrategyOrderStatuses('US', now, today);
        await _checkVrStrategies();
        await _checkMmCycleEnd();
      }
    } catch (_) {}
  }

  // ── DST 헬퍼 ─────────────────────────────────────────────────

  static bool _isEdtStatic(DateTime utc) {
    final y = utc.year;
    int marchDay = 8;
    while (DateTime(y, 3, marchDay).weekday != DateTime.sunday) { marchDay++; }
    int novDay = 1;
    while (DateTime(y, 11, novDay).weekday != DateTime.sunday) { novDay++; }
    final dstStart = DateTime.utc(y, 3, marchDay, 7, 0);
    final dstEnd   = DateTime.utc(y, 11, novDay,  6, 0);
    return utc.isAfter(dstStart) && utc.isBefore(dstEnd);
  }

  /// 장 마감 30분 후인지 확인 (KR: 15:30+30=16:00, US: 16:00ET+30=16:30ET)
  static bool _isAfterClose30(String market, DateTime now) {
    if (market == 'KR') {
      final kst = now.toUtc().add(const Duration(hours: 9));
      if (kst.weekday >= 6) return false;
      return kst.hour * 60 + kst.minute >= 16 * 60;
    } else {
      final utc = now.toUtc();
      final et = utc.subtract(Duration(hours: _isEdtStatic(utc) ? 4 : 5));
      if (et.weekday >= 6) return false;
      return et.hour * 60 + et.minute >= 16 * 60 + 30;
    }
  }

  /// 장마감 15분전 창: US 15:45~16:00 ET, KR 15:15~15:30 KST
  static bool _isPreClosePeriod(String market, DateTime now) {
    if (market == 'KR') {
      final kst = now.toUtc().add(const Duration(hours: 9));
      if (kst.weekday >= 6) return false;
      final m = kst.hour * 60 + kst.minute;
      return m >= 15 * 60 + 15 && m < 15 * 60 + 30;
    } else {
      final utc = now.toUtc();
      final et = utc.subtract(Duration(hours: _isEdtStatic(utc) ? 4 : 5));
      if (et.weekday >= 6) return false;
      final m = et.hour * 60 + et.minute;
      return m >= 15 * 60 + 45 && m < 16 * 60;
    }
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
    List<Map<String, dynamic>> pendingOrders = [];
    try {
      final ordersData = await ApiService.getOrders(
        market,
        startDate: _fmtDate(now.subtract(const Duration(days: 1))),
        endDate: _fmtDate(now),
      );
      final allOrders = (ordersData['orders'] as List? ?? [])
          .map((o) => o as Map<String, dynamic>)
          .toList();
      filledOrders = allOrders.where((o) => o['status'] == '체결').toList();
      pendingOrders = allOrders.where((o) => o['status'] == '미체결').toList();
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

        await _checkSessionComplete(session, accountData, market, now);
      } else {
        if (side != 'BUY') continue;

        // 이미 미체결(주문 전송됨)인 경우 중복 전송 방지
        final alreadyPending = pendingOrders.any((f) {
          final fTicker = (f['ticker'] as String? ?? '').toUpperCase();
          final fSide = (f['side'] as String? ?? '').toUpperCase();
          final fTime = (f['ordered_at'] ?? f['created_at'] ?? '').toString();
          return fTicker == ticker.toUpperCase() &&
              fSide == side &&
              fTime.compareTo(createdAt) >= 0;
        });
        if (alreadyPending) continue;

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

    final stratId = session['strategy_id'] as String;
    final logs = await AppDatabase.getTradeLog(stratId);
    final alreadyLogged = logs.any((l) =>
        (l['action'] as String? ?? '') == '리밸런싱 완료' &&
        (l['created_at'] as String? ?? '').startsWith(now.toIso8601String().substring(0, 10)));
    if (alreadyLogged) return;

    final capital = (session['total_capital'] as num? ?? 0).toDouble();

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

  // ── VR 전략 V값 기록 — 장마감 30분 후, 사이클 주기마다 ──────────

  static Future<void> _checkVrStrategies() async {
    final strategies = await AppDatabase.getStrategies();
    final now = DateTime.now();

    // 장마감 30분 후인 시장의 VR 전략만 필터
    final vrStrategies = strategies.where((s) =>
        s.type == 'vr' && s.active && _isAfterClose30(s.market, now)).toList();
    if (vrStrategies.isEmpty) return;

    Map<String, dynamic>? accountData;
    try {
      accountData = await ApiService.getAccount();
    } catch (_) {
      return;
    }

    for (final s in vrStrategies) {
      final logs = await AppDatabase.getTradeLog(s.strategyId);
      final vLogs = logs.where((l) => (l['action'] as String? ?? '') == 'V값 기록').toList();

      DateTime? lastVLog;
      if (vLogs.isNotEmpty) {
        lastVLog = DateTime.tryParse(vLogs.first['created_at'] as String? ?? '');
      }

      final daysSinceLast = lastVLog == null
          ? 999
          : now.difference(lastVLog).inDays;

      final cycleDays = (s.cyclePeriod ?? 4) * 7;
      if (daysSinceLast < cycleDays) continue;

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

  // ── MM(V1) 사이클 종료 감지 — 장 마감 30분 후, 보유수량 0 확인 ──────

  static Future<void> _checkMmCycleEnd() async {
    final strategies = await AppDatabase.getStrategies();
    final mmStrategies =
        strategies.where((s) => s.type == 'v1' && s.active).toList();
    if (mmStrategies.isEmpty) return;

    final now = DateTime.now();

    Map<String, dynamic>? accountData;
    try {
      accountData = await ApiService.getAccount();
    } catch (_) {
      return;
    }

    final today = now.toIso8601String().substring(0, 10);

    for (final s in mmStrategies) {
      // 장 마감 30분 후에만 실행
      if (!_isAfterClose30(s.market, now)) continue;

      // 이미 오늘 사이클 종료 기록 있으면 스킵
      final logs = await AppDatabase.getTradeLog(s.strategyId);
      final alreadyClosed = logs.any((l) =>
          (l['action'] as String? ?? '') == '사이클 종료' &&
          (l['date'] as String? ?? '').startsWith(today));
      if (alreadyClosed) continue;

      // 보유 수량 확인
      final marketKey = s.market == 'KR' ? 'kr' : 'us';
      int shares = 0;
      for (final acc in ((accountData[marketKey]) as List? ?? [])) {
        for (final h in (acc['holdings'] as List? ?? [])) {
          if ((h['ticker'] as String? ?? '') == s.symbol) {
            shares = (h['shares'] as num? ?? 0).toInt();
          }
        }
      }
      if (shares > 0) continue;

      // 사이클 수익 계산
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

      // 매수/매도 기록이 없으면 초기 상태 — 스킵
      if (totalBuy == 0 && totalSell == 0) continue;

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

  // ── 매도 예약 처리 — 5분마다 미체결 회수 후 시장가 재발송 ──────────

  static Future<void> _checkPendingSells() async {
    final sells = await AppDatabase.getPendingSells();
    if (sells.isEmpty) return;

    final now = DateTime.now();
    final krOpen = MarketClock.isKrOpen;
    final usOpen = MarketClock.isUsOpen;
    if (!krOpen && !usOpen) return;

    Map<String, dynamic>? accountData;
    try {
      accountData = await ApiService.getAccount();
    } catch (_) {
      return;
    }

    for (final sell in sells) {
      final id = sell['id'] as int;
      final ticker = sell['ticker'] as String;
      final market = (sell['market'] as String?) ?? 'KR';
      final scheduledAt =
          DateTime.tryParse(sell['scheduled_at'] as String? ?? '');

      // 예약 시간 전이면 스킵
      if (scheduledAt != null && now.isBefore(scheduledAt)) continue;

      // 해당 시장이 닫혀있으면 스킵
      final isOpen = market == 'KR' ? krOpen : usOpen;
      if (!isOpen) continue;

      // 현재 보유수량 확인
      final marketKey = market == 'KR' ? 'kr' : 'us';
      int currentShares = 0;
      for (final acc in (accountData[marketKey] as List? ?? [])) {
        for (final h in (acc['holdings'] as List? ?? [])) {
          if ((h['ticker'] as String? ?? '').toUpperCase() ==
              ticker.toUpperCase()) {
            currentShares = (h['shares'] as num? ?? 0).toInt();
          }
        }
      }

      // 보유수량 0 → 이미 체결됨, 삭제
      if (currentShares == 0) {
        await AppDatabase.deletePendingSell(id);
        continue;
      }

      // 미체결 주문 전량 회수
      try {
        final ordersData = await ApiService.getOrders(market);
        final openOrders = (ordersData['orders'] as List? ?? [])
            .where((o) {
              final m = o as Map<String, dynamic>;
              final t = (m['ticker'] as String? ?? '').toUpperCase();
              final st = m['status'] as String? ?? '';
              return t == ticker.toUpperCase() && st != '체결' && st != '취소';
            })
            .toList();
        for (final order in openOrders) {
          final m = order as Map<String, dynamic>;
          final orderId =
              m['order_id'] as String? ?? m['id']?.toString() ?? '';
          if (orderId.isEmpty) continue;
          try {
            await ApiService.cancelOrder(orderId, market);
          } catch (_) {}
        }
      } catch (_) {}

      // 시장가 매도 주문
      try {
        await ApiService.placeOrder(
          market: market,
          ticker: ticker,
          side: 'SELL',
          quantity: currentShares,
          price: 0,
          ordDvsn: '01',
        );
        // 성공: 에러 메시지 초기화
        await AppDatabase.updatePendingSell(id, {'error_msg': null});
      } catch (e) {
        String msg = e.toString();
        if (msg.startsWith('Exception: ')) msg = msg.substring(11);
        // 실패 시 다음 장시작으로 scheduled_at 갱신
        final nextOpen = nextMarketOpen(market);
        await AppDatabase.updatePendingSell(id, {
          'error_msg': msg,
          'scheduled_at': nextOpen.toIso8601String(),
        });
      }
    }
  }

  /// 해당 시장의 다음 장시작 DateTime 반환 (KR: 09:00 KST, US: 22:30 KST)
  static DateTime nextMarketOpen(String market) {
    final now = DateTime.now();
    if (market == 'KR') {
      var next = DateTime(now.year, now.month, now.day, 9, 0);
      if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
      // 주말 건너뜀
      while (next.weekday == DateTime.saturday || next.weekday == DateTime.sunday) {
        next = next.add(const Duration(days: 1));
      }
      return next;
    } else {
      // US: 22:30 KST
      var next = DateTime(now.year, now.month, now.day, 22, 30);
      if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
      while (next.weekday == DateTime.saturday || next.weekday == DateTime.sunday) {
        next = next.add(const Duration(days: 1));
      }
      return next;
    }
  }

  // ── V4 LOC 매수 가격 재조정 — 장마감 15분전 ─────────────────────────
  // 하락장에서 매수 LOC가 현재가 대비 15%+ 위에 있으면 KIS가 거부.
  // 매도 LOC는 원본 유지 (지정가 이상에 팔겠다는 것이므로 건드리지 않음).

  static Future<void> _checkV4LocReset() async {
    final strategies = await AppDatabase.getStrategies();
    final now = DateTime.now();
    final today = now.toIso8601String().substring(0, 10);

    // 15분전 창에 해당하는 활성 V4 전략 (US only — KR은 LOC 방식 다름)
    final v4s = strategies.where((s) =>
        s.type == 'v4' && s.active && s.symbol.isNotEmpty &&
        s.market == 'US' && _isPreClosePeriod(s.market, now)).toList();
    if (v4s.isEmpty) return;

    // 미체결 주문 1회 조회
    List<Map<String, dynamic>> openOrders = [];
    try {
      final data = await ApiService.getOrders('US');
      openOrders = (data['orders'] as List? ?? [])
          .cast<Map<String, dynamic>>()
          .where((o) {
            final st = o['status'] as String? ?? '';
            return st != '체결' && st != '취소';
          })
          .toList();
    } catch (_) { return; }

    for (final s in v4s) {
      final resetKey = 'v4_loc_reset_${today}_${s.strategyId}';
      if ((await AppDatabase.getSetting(resetKey)) == '1') continue;

      final ticker = s.symbol.toUpperCase();

      // 현재가 조회
      double currentPrice = 0;
      try {
        final q = await ApiService.getQuote(ticker, 'US');
        currentPrice = (q['price'] as num? ?? q['current_price'] as num? ?? 0).toDouble();
      } catch (_) { continue; }
      if (currentPrice <= 0) continue;

      // 해당 종목 BUY 주문 중 현재가 × 1.13 초과인 것만 재조정 (SELL은 원본 유지)
      for (final order in openOrders) {
        final t = (order['ticker'] as String? ?? '').toUpperCase();
        final side = (order['side'] as String? ?? '').toUpperCase();
        if (t != ticker || side != 'BUY') continue;

        final orderPrice = (order['price'] as num? ?? 0).toDouble();
        // 허용 범위 내(13% 이하)이거나 가격 없으면 스킵
        if (orderPrice <= 0 || orderPrice <= currentPrice * 1.13) continue;

        final orderId = order['order_id'] as String? ??
                        order['id']?.toString() ?? '';
        final qty = (order['quantity'] as num? ?? 0).toInt();
        if (orderId.isEmpty || qty <= 0) continue;

        // 취소
        try {
          await ApiService.cancelOrder(orderId, 'US');
        } catch (_) { continue; }

        // 현재가로 LOC 재제출
        try {
          await ApiService.placeOrder(
            market: 'US',
            ticker: ticker,
            side: 'BUY',
            quantity: qty,
            price: currentPrice,
            ordDvsn: '34', // LOC
          );
        } catch (_) {}
      }

      // 오늘 처리 완료 표시
      await AppDatabase.setSetting(resetKey, '1');
    }
  }

  // ── 장마감 후 strategy_order_log 상태 동기화 ────────────────────────

  static Future<void> _syncStrategyOrderStatuses(
      String market, DateTime now, String today) async {
    final strategies = await AppDatabase.getStrategies();
    final marketStrategies =
        strategies.where((s) => s.market == market && s.active).toList();
    if (marketStrategies.isEmpty) return;

    // 오늘 체결 내역 조회
    List<Map<String, dynamic>> filledOrders = [];
    try {
      final dateStr = today.replaceAll('-', '');
      final data = await ApiService.getOrders(market,
          startDate: dateStr, endDate: dateStr);
      filledOrders = (data['orders'] as List? ?? [])
          .cast<Map<String, dynamic>>()
          .where((o) => (o['status'] as String? ?? '') == '체결')
          .toList();
    } catch (_) {
      return;
    }

    for (final s in marketStrategies) {
      if (s.id == null) continue;
      final scheduled = await AppDatabase.getScheduledOrderLogs(s.id!);
      if (scheduled.isEmpty) continue;

      final ticker = s.symbol.toUpperCase();

      for (final log in scheduled) {
        final logId = log['id'] as int;
        final logDate = log['date'] as String? ?? '';

        if (logDate != today) {
          // 오늘이 아닌 과거 Scheduled → 장이 지났으므로 Failed
          await AppDatabase.updateOrderLogStatus(logId, 'Failed');
          continue;
        }

        final side = (log['side'] as String? ?? 'BUY').toUpperCase();
        final matched = filledOrders.any((f) {
          final fTicker = (f['ticker'] as String? ?? '').toUpperCase();
          final fSide = (f['side'] as String? ?? '').toUpperCase();
          return fTicker == ticker && fSide == side;
        });
        await AppDatabase.updateOrderLogStatus(
            logId, matched ? 'Success' : 'Failed');
      }
    }
  }

  // ── MM(V4/V1) 오늘 첫 매수 계획 레코드 생성 ────────────────────────────
  // force=true : Scheduled 항목이 있으면 삭제 후 재계산 (calcCapital 변경 반영)
  // force=false: 오늘 기록이 이미 있으면 스킵 (5분 tick 절약)

  static Future<void> _ensureMmDailyOrders(DateTime now, String today,
      {bool force = false}) async {
    final strategies = await AppDatabase.getStrategies();
    final mmStrategies = strategies
        .where((s) =>
            (s.type == 'v4' || s.type == 'v1') &&
            s.active &&
            s.symbol.isNotEmpty)
        .toList();
    if (mmStrategies.isEmpty) return;

    final toProcess = <Strategy>[];
    for (final s in mmStrategies) {
      if (s.id == null) continue;
      final todayLogs = await AppDatabase.getOrderLogs(s.id!, date: today);
      if (force) {
        // force: 모든 항목이 체결 완료(Success/Failed)일 때만 skip
        if (todayLogs.isNotEmpty &&
            todayLogs.every((l) =>
                (l['status'] as String? ?? '') != 'Scheduled')) continue;
        // Scheduled 항목 있으면 삭제 후 재계산
        if (todayLogs.any(
            (l) => (l['status'] as String? ?? '') == 'Scheduled')) {
          await AppDatabase.deleteScheduledOrderLogsForDate(s.id!, today);
        }
      } else {
        if (todayLogs.isNotEmpty) continue;
      }
      toProcess.add(s);
    }
    if (toProcess.isEmpty) return;

    Map<String, dynamic>? accountData;
    try {
      accountData = await ApiService.getAccount();
    } catch (_) {
      return;
    }

    for (final s in toProcess) {
      final marketKey = s.market == 'KR' ? 'kr' : 'us';

      int shares = 0;
      double avg = 0, currentPrice = 0;
      for (final acc in (accountData[marketKey] as List? ?? [])) {
        for (final h in (acc['holdings'] as List? ?? [])) {
          if ((h['ticker'] as String? ?? '').toUpperCase() ==
              s.symbol.toUpperCase()) {
            shares = (h['shares'] as num? ?? 0).toInt();
            avg = (h['avg_price'] as num? ?? 0).toDouble();
            currentPrice = (h['current_price'] as num? ?? 0).toDouble();
          }
        }
      }

      if (shares == 0 || currentPrice <= 0) {
        try {
          final q = await ApiService.getQuote(s.symbol.toUpperCase(), s.market);
          currentPrice =
              (q['price'] as num? ?? q['current_price'] as num? ?? 0).toDouble();
        } catch (_) {}
      }

      if (currentPrice <= 0) continue;

      final tVal = s.tValue ?? 0.0;
      final divisions = math.max(s.divisions ?? 20, 1);
      final divAmount = (s.calcCapital ?? s.capital) / divisions;

      if (s.type == 'v4' && tVal == 0 && shares == 0) {
        final capPrice = currentPrice * 1.10;
        final qty = math.max((divAmount / capPrice).floor(), 1);
        await AppDatabase.upsertOrderLog({
          'strategy_db_id': s.id!,
          'strategy_id': s.strategyId,
          'date': today,
          'side': 'BUY',
          'day': '첫 매수',
          'label': '시장 LOC @전일종가×1.10',
          'planned_qty': qty,
          'planned_price': capPrice,
          'status': 'Scheduled',
          'created_at': now.toIso8601String(),
        });
      } else if (s.type == 'v1' && (shares <= 0 || avg <= 0)) {
        final qty =
            currentPrice > 0 ? math.max((divAmount / currentPrice).floor(), 1) : 0;
        if (qty <= 0) continue;
        await AppDatabase.upsertOrderLog({
          'strategy_db_id': s.id!,
          'strategy_id': s.strategyId,
          'date': today,
          'side': 'BUY',
          'day': '첫 매수',
          'label': '신규 매수 LOC (1분할)',
          'planned_qty': qty,
          'planned_price': currentPrice,
          'status': 'Scheduled',
          'created_at': now.toIso8601String(),
        });
      }
    }
  }

  // ── VR 적립식 첫사이클 오늘 매수 주문 레코드 생성 ───────────────────

  static Future<void> _ensureVrFirstCycleOrders(DateTime now, String today) async {
    final strategies = await AppDatabase.getStrategies();
    final vrStrategies = strategies
        .where((s) => s.type == 'vr' && s.active && s.vrMode == '적립식')
        .toList();
    if (vrStrategies.isEmpty) return;

    for (final s in vrStrategies) {
      if (s.id == null || s.symbol.isEmpty) continue;

      // 사이클 기록 있으면 첫사이클 아님
      final cycleRecords = await AppDatabase.getVrCycleRecords(s.strategyId);
      if (cycleRecords.isNotEmpty) continue;

      // 오늘 BUY 주문 기록 이미 있으면 스킵
      final todayLogs = await AppDatabase.getOrderLogs(s.id!, date: today);
      if (todayLogs.any((l) => (l['side'] as String? ?? '') == 'BUY')) continue;

      // 현재가 조회
      double price = 0;
      try {
        final q = await ApiService.getQuote(s.symbol, s.market);
        price = (q['price'] as num? ?? q['current_price'] as num? ?? 0).toDouble();
      } catch (_) {}

      await AppDatabase.upsertOrderLog({
        'strategy_db_id': s.id,
        'strategy_id': s.strategyId,
        'date': today,
        'side': 'BUY',
        'day': '',
        'label': '첫사이클 매수',
        'planned_qty': s.vrQtyPerStep ?? 1,
        'planned_price': price,
        'status': 'Scheduled',
        'created_at': now.toIso8601String(),
      });
    }
  }
}
