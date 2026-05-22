import 'package:flutter/material.dart';
import '../core/api_service.dart';
import '../core/app_theme.dart';
import '../core/common.dart';
import '../core/database.dart';
import '../models/strategy.dart';
import 'detail/mm_detail_screen.dart';
import 'detail/qt_detail_screen.dart';
import 'detail/vr_detail_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _loading = false;
  bool _syncing = false;
  String? _error;
  Map<String, dynamic>? _data;
  List<Strategy> _strategies = [];
  DateTime? _lastUpdated;
  bool _noStratExpanded = false;

  Set<String> _portfolioTickers = {};
  List<Map<String, dynamic>> _pendingSells = [];
  Map<String, String> _tickerNames = {};

  @override
  void initState() {
    super.initState();
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${payload.length}개 전략 서버 동기화 완료'),
          duration: const Duration(seconds: 2),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('동기화 실패: $e'),
          backgroundColor: const Color(0xFFF85149),
        ));
      }
    }
    setState(() { _syncing = false; });
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        ApiService.getAccount(),
        AppDatabase.getStrategies(),
      ]);
      final strategies = results[1] as List<Strategy>;

      final tickers = <String>{};
      for (final s in strategies) {
        if (s.symbol.isNotEmpty) tickers.add(s.symbol);
        final stocks = await AppDatabase.getPortfolioStocks(s.strategyId);
        for (final st in stocks) {
          final t = st['ticker'] as String? ?? '';
          if (t.isNotEmpty) tickers.add(t);
        }
      }

      final pendingSells = await AppDatabase.getPendingSells();
      final tickerNames = await AppDatabase.getTickerNames();

      setState(() {
        _data = results[0] as Map<String, dynamic>;
        _strategies = strategies;
        _portfolioTickers = tickers;
        _pendingSells = pendingSells;
        _tickerNames = tickerNames;
        _lastUpdated = DateTime.now();
      });
    } catch (e) {
      setState(() { _error = e.toString(); });
    } finally {
      setState(() { _loading = false; });
    }
  }

  double _krTotal() {
    return (_data?['kr'] as List? ?? []).fold(0.0, (s, a) {
      final total = (a['total_eval_krw'] as num?)?.toDouble() ?? 0;
      if (total > 0) return s + total;
      // fallback
      final cash = ((a['cash_krw'] ?? a['orderable_krw']) as num? ?? 0).toDouble();
      final stocks = ((a['holdings'] as List?) ?? []).fold(0.0,
          (hs, h) => hs + (h['shares'] as num? ?? 0) * (h['current_price'] as num? ?? 0));
      return s + cash + stocks;
    });
  }

  double _usTotal() {
    return (_data?['us'] as List? ?? []).fold(0.0, (s, a) {
      final total = (a['total_eval_usd'] as num?)?.toDouble() ?? 0;
      if (total > 0) return s + total;
      // fallback
      final cash = (a['cash_usd'] as num? ?? 0).toDouble();
      final stocks = ((a['holdings'] as List?) ?? []).fold(0.0,
          (hs, h) => hs + (h['shares'] as num? ?? 0) * (h['current_price'] as num? ?? 0));
      return s + cash + stocks;
    });
  }

  List<Map<String, dynamic>> _noStratHoldings() {
    if (_data == null) return [];
    final result = <Map<String, dynamic>>[];
    for (final mk in ['kr', 'us']) {
      final market = mk == 'kr' ? 'KR' : 'US';
      for (final acc in (_data![mk] as List? ?? [])) {
        for (final h in (acc['holdings'] as List? ?? [])) {
          final ticker = h['ticker'] as String? ?? '';
          if (!_portfolioTickers.contains(ticker)) {
            final enriched = Map<String, dynamic>.from(h);
            if ((enriched['name'] as String? ?? '').isEmpty) {
              final cached = _tickerNames[ticker] ?? _tickerNames[ticker.toUpperCase()];
              if (cached != null && cached.isNotEmpty) enriched['name'] = cached;
            }
            result.add({...enriched, 'market': market});
          }
        }
      }
    }
    return result;
  }

  double _stratPnl(Strategy s) {
    if (_data == null || s.symbol.isEmpty) return 0;
    final key = s.market == 'KR' ? 'kr' : 'us';
    for (final acc in (_data![key] as List? ?? [])) {
      for (final h in (acc['holdings'] as List? ?? [])) {
        if (h['ticker'] == s.symbol) {
          return Calc.pnlPct(
            (h['avg_price'] as num? ?? 0).toDouble(),
            (h['current_price'] as num? ?? 0).toDouble(),
          );
        }
      }
    }
    return 0;
  }

  Map<String, List<Map<String, dynamic>>> _allNoStratHoldingsMap() {
    final kr = <Map<String, dynamic>>[];
    final us = <Map<String, dynamic>>[];
    if (_data == null) return {'KR': kr, 'US': us};
    for (final acc in (_data!['kr'] as List? ?? [])) {
      for (final h in (acc['holdings'] as List? ?? [])) {
        final ticker = h['ticker'] as String? ?? '';
        if (!_portfolioTickers.contains(ticker)) {
          final enriched = Map<String, dynamic>.from(h);
          if ((enriched['name'] as String? ?? '').isEmpty) {
            final cached = _tickerNames[ticker] ?? _tickerNames[ticker.toUpperCase()];
            if (cached != null && cached.isNotEmpty) enriched['name'] = cached;
          }
          kr.add(enriched);
        }
      }
    }
    for (final acc in (_data!['us'] as List? ?? [])) {
      for (final h in (acc['holdings'] as List? ?? [])) {
        final ticker = h['ticker'] as String? ?? '';
        if (!_portfolioTickers.contains(ticker)) {
          final enriched = Map<String, dynamic>.from(h);
          if ((enriched['name'] as String? ?? '').isEmpty) {
            final cached = _tickerNames[ticker] ?? _tickerNames[ticker.toUpperCase()];
            if (cached != null && cached.isNotEmpty) enriched['name'] = cached;
          }
          us.add(enriched);
        }
      }
    }
    return {'KR': kr, 'US': us};
  }

  double _cashKr() => _krTotal();
  double _cashUs() => _usTotal();

  void _openDetail(Strategy s) {
    Widget screen;
    if (s.type == 'vr') {
      screen = VrDetailScreen(strategy: s);
    } else if (s.type == 'kr_value') {
      screen = KrValueDetailScreen(strategy: s);
    } else {
      screen = V4DetailScreen(strategy: s);
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen))
        .then((_) => _load());
  }

  void _openAddSheet([String? preselected]) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _AddSheet(
        noStratHoldings: _allNoStratHoldingsMap(),
        cashKr: _cashKr(),
        cashUs: _cashUs(),
        preselectedTicker: preselected,
        onSaved: _load,
      ),
    );
  }

  Future<void> _renameStrategy(Strategy s) async {
    final ctrl = TextEditingController(text: s.strategyId);
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('이름 변경'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: s.strategyId,
            hintStyle: const TextStyle(color: Color(0xFF6E7681)),
            filled: true, fillColor: const Color(0xFF0D1117),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Color(0xFF30363D))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Color(0xFF30363D))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Color(0xFF58A6FF))),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('변경'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (newName == null || newName.isEmpty || newName == s.strategyId) return;
    await AppDatabase.renameStrategy(s.id!, s.strategyId, newName);
    _load();
  }

  Future<void> _toggleStrategy(Strategy s) async {
    await AppDatabase.toggleActive(s);
    _load();
  }

  Future<void> _deleteStrategy(Strategy s) async {
    final portfolioStocks = await AppDatabase.getPortfolioStocks(s.strategyId);

    final heldStocks = portfolioStocks.where((stock) {
      final ticker = stock['ticker'] as String;
      return _findHolding(ticker, s.market) != null;
    }).toList();

    if (!mounted) return;

    if (heldStocks.isNotEmpty) {
      final choice = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF161B22),
          title: Text('${s.strategyId} 삭제'),
          content: Text('보유 종목 ${heldStocks.length}개를 어떻게 처리할까요?'),
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
        final scheduled = await _showScheduleSheet();
        if (scheduled == null) return;
        for (final stock in heldStocks) {
          final ticker = stock['ticker'] as String;
          final holding = _findHolding(ticker, s.market);
          await AppDatabase.insertPendingSell({
            'ticker': ticker,
            'name': stock['name'] as String? ?? ticker,
            'market': s.market,
            'quantity': (holding?['shares'] as num?)?.toDouble() ?? 0,
            'avg_price': (holding?['avg_price'] as num?)?.toDouble() ?? 0,
            'scheduled_at': scheduled.toIso8601String(),
            'status': 'pending',
            'source_strategy_id': s.strategyId,
            'created_at': DateTime.now().toIso8601String(),
          });
        }
      }
    }

    await AppDatabase.clearPortfolioStocks(s.strategyId);
    await AppDatabase.softDeleteStrategy(s.id!);
    _load();
  }

  Map<String, dynamic>? _findHolding(String ticker, String market) {
    if (_data == null) return null;
    final key = market == 'KR' ? 'kr' : 'us';
    for (final acc in (_data![key] as List? ?? [])) {
      for (final h in (acc['holdings'] as List? ?? [])) {
        if (h['ticker'] == ticker) return Map<String, dynamic>.from(h);
      }
    }
    return null;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text(
          'Gold Mine',
          style: TextStyle(
            color: Color(0xFFD4AF37),
            fontSize: 18,
            fontFamily: 'KBLJump_B',
            letterSpacing: 1.5,
          ),
        ),
        actions: [
          if (_lastUpdated != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(child: Text(
                Fmt.datetime(_lastUpdated!).substring(6),
                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11),
              )),
            ),
          if (_syncing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Center(child: SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))),
            )
          else
            IconButton(
              icon: const Icon(Icons.cloud_upload_outlined, size: 20),
              tooltip: '서버 동기화',
              onPressed: _syncToServer,
            ),
          IconButton(
            icon: _loading
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 20),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: _error != null
          ? _ErrView(msg: _error!, onRetry: _load)
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                children: [
                  if (_data != null) ...[
                    _buildSummary(),
                    const SizedBox(height: 16),
                    _buildStrategies(),
                    const SizedBox(height: 16),
                    _buildNoStrat(),
                    const SizedBox(height: 24),
                  ] else if (!_loading)
                    const Center(child: Text('데이터 없음',
                        style: TextStyle(color: Color(0xFF8B949E)))),
                ],
              ),
            ),
    );
  }

  Widget _buildSummary() {
    final krTotal = _krTotal();
    final usTotal = _usTotal();
    final activeKrCap = _strategies
        .where((s) => s.active && s.market == 'KR')
        .fold(0.0, (a, s) => a + s.capital);
    final activeUsCap = _strategies
        .where((s) => s.active && s.market == 'US')
        .fold(0.0, (a, s) => a + s.capital);
    return Row(children: [
      Expanded(child: _SumCard(
        label: '한국', market: 'KR', value: Fmt.krw(krTotal),
        activePct: krTotal > 0 ? (activeKrCap / krTotal).clamp(0.0, 1.0) : 0.0,
        activeCapStr: Fmt.krw(activeKrCap),
      )),
      const SizedBox(width: 8),
      Expanded(child: _SumCard(
        label: '미국', market: 'US', value: Fmt.usd(usTotal),
        activePct: usTotal > 0 ? (activeUsCap / usTotal).clamp(0.0, 1.0) : 0.0,
        activeCapStr: Fmt.usd(activeUsCap),
      )),
    ]);
  }

  Widget _buildStrategies() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const _SecLabel('전략'),
        const Spacer(),
        GestureDetector(
          onTap: _openAddSheet,
          child: Row(children: [
            Icon(Icons.add, size: 14, color: AppTheme.accent),
            const SizedBox(width: 2),
            Text('추가', style: TextStyle(color: AppTheme.accent, fontSize: 12)),
          ]),
        ),
      ]),
      const SizedBox(height: 8),
      if (_strategies.isEmpty)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 20),
          alignment: Alignment.center,
          child: const Text('등록된 전략이 없습니다',
              style: TextStyle(color: Color(0xFF6E7681), fontSize: 12)),
        )
      else
        ..._strategies.map((s) => _StratCard(
          strategy: s,
          pnlPct: (s.type != 'kr_value' && s.symbol.isNotEmpty)
              ? _stratPnl(s) : null,
          onTap: () => _openDetail(s),
          onToggle: () => _toggleStrategy(s),
          onDelete: () => _deleteStrategy(s),
          onRename: () => _renameStrategy(s),
        )),
    ]);
  }

  Widget _buildNoStrat() {
    final holdings = _noStratHoldings();

    final pendingMap = <String, Map<String, dynamic>>{};
    for (final ps in _pendingSells) {
      pendingMap[ps['ticker'] as String] = ps;
    }

    // KR / US 분리
    final krItems = <Map<String, dynamic>>[];
    final usItems = <Map<String, dynamic>>[];
    final seenTickers = <String>{};
    for (final h in holdings) {
      final ticker = h['ticker'] as String;
      seenTickers.add(ticker);
      final item = {...h, 'pending_sell': pendingMap[ticker]};
      if ((h['market'] as String? ?? 'KR') == 'KR') {
        krItems.add(item);
      } else {
        usItems.add(item);
      }
    }
    for (final ps in _pendingSells) {
      final ticker = ps['ticker'] as String;
      if (!seenTickers.contains(ticker)) {
        final item = {
          'ticker': ticker,
          'name': ps['name'],
          'market': ps['market'],
          'shares': ps['quantity'],
          'avg_price': ps['avg_price'],
          'current_price': 0.0,
          'eval_profit': 0.0,
          'return_pct': 0.0,
          'pending_sell': ps,
        };
        if ((ps['market'] as String? ?? 'KR') == 'KR') {
          krItems.add(item);
        } else {
          usItems.add(item);
        }
      }
    }

    if (krItems.isEmpty && usItems.isEmpty) return const SizedBox.shrink();

    Widget _buildItems(List<Map<String, dynamic>> items) {
      final total = items.length;
      final shown = _noStratExpanded ? items : items.take(10).toList();
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ...shown.map((item) {
          final pendingSell = item['pending_sell'] as Map<String, dynamic>?;
          if (pendingSell != null) {
            return _PendingSellRow(
              holding: item,
              pendingSell: pendingSell,
              onCancel: () async {
                await AppDatabase.deletePendingSell(pendingSell['id'] as int);
                _load();
              },
              onModify: () async {
                final newTime = await _showScheduleSheet();
                if (newTime != null) {
                  await AppDatabase.updatePendingSell(
                    pendingSell['id'] as int,
                    {'scheduled_at': newTime.toIso8601String()},
                  );
                  _load();
                }
              },
            );
          }
          return _NoStratRow(
            holding: item,
            onAdd: () => _openAddSheet(item['ticker'] as String?),
          );
        }),
        if (!_noStratExpanded && total > 10)
          GestureDetector(
            onTap: () => setState(() { _noStratExpanded = true; }),
            child: Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF30363D)),
              ),
              child: Center(child: Text(
                '... ${total - 10}개 더 보기',
                style: TextStyle(color: AppTheme.accent, fontSize: 12),
              )),
            ),
          ),
      ]);
    }

    final totalCount = krItems.length + usItems.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _SecLabel('보유 ($totalCount개)'),
        const Spacer(),
        if (totalCount > 10)
          GestureDetector(
            onTap: () => setState(() { _noStratExpanded = !_noStratExpanded; }),
            child: Text(
              _noStratExpanded ? '접기' : '전체 보기',
              style: TextStyle(color: AppTheme.accent, fontSize: 11),
            ),
          ),
      ]),
      const SizedBox(height: 8),

      // ── 한국 ──────────────────────────────
      if (krItems.isNotEmpty) ...[
        Row(children: [
          Container(width: 7, height: 7,
              decoration: BoxDecoration(color: AppTheme.krColor, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text('한국 (${krItems.length})',
              style: TextStyle(color: AppTheme.krColor, fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 5),
        _buildItems(krItems),
        if (usItems.isNotEmpty) const SizedBox(height: 12),
      ],

      // ── 미국 ──────────────────────────────
      if (usItems.isNotEmpty) ...[
        Row(children: [
          Container(width: 7, height: 7,
              decoration: BoxDecoration(color: AppTheme.usColor, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text('미국 (${usItems.length})',
              style: TextStyle(color: AppTheme.usColor, fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 5),
        _buildItems(usItems),
      ],
    ]);
  }

}

// ── Summary card ─────────────────────────────────────────────────
class _SumCard extends StatelessWidget {
  final String label, market, value, activeCapStr;
  final double activePct;
  const _SumCard({
    required this.label, required this.market, required this.value,
    required this.activePct, required this.activeCapStr,
  });

  @override
  Widget build(BuildContext context) {
    final accent = market == 'KR' ? AppTheme.krColor : AppTheme.usColor;
    final pctStr = '${(activePct * 100).toStringAsFixed(0)}%';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 8, height: 8,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle)),
            const SizedBox(width: 5),
            Text(label, style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
          ]),
          const Spacer(),
          Flexible(
            child: Text(value, style: TextStyle(
              color: AppTheme.accent, fontSize: 13, fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: activePct,
            minHeight: 5,
            backgroundColor: const Color(0xFF21262D),
            valueColor: AlwaysStoppedAnimation<Color>(accent),
          ),
        ),
        const SizedBox(height: 5),
        Row(children: [
          Text('전략 운용 $pctStr', style: const TextStyle(color: Color(0xFF6E7681), fontSize: 10)),
          const Spacer(),
          Text(activeCapStr, style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
        ]),
      ]),
    );
  }
}

// ── Strategy card ────────────────────────────────────────────────
class _StratCard extends StatelessWidget {
  final Strategy strategy;
  final double? pnlPct;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  final VoidCallback onRename;

  const _StratCard({
    required this.strategy, required this.onTap,
    required this.onToggle, required this.onDelete,
    required this.onRename,
    this.pnlPct,
  });

  @override
  Widget build(BuildContext context) {
    final s = strategy;
    final pnl = pnlPct ?? 0;
    final pnlColor = pnl >= 0 ? const Color(0xFF2EA043) : const Color(0xFFF85149);
    final capitalStr = s.market == 'KR' ? Fmt.krw(s.capital) : Fmt.usd(s.capital);

    return GestureDetector(
      onTap: onTap,
      onLongPress: () => _showMenu(context),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(width: 3,
                color: s.active ? AppTheme.accent : const Color(0xFF6E7681)),
            Expanded(
              child: Container(
                color: const Color(0xFF161B22),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                child: Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text(s.strategyId,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(width: 6),
                      _Chip(s.typeLabel),
                      const SizedBox(width: 4),
                      _Chip(s.market),
                      if (!s.active) ...[
                        const SizedBox(width: 4),
                        _Chip('비활성', color: const Color(0xFF21262D),
                            textColor: const Color(0xFF6E7681)),
                      ],
                    ]),
                    const SizedBox(height: 3),
                    Text(capitalStr,
                        style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
                  ])),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    if (s.active && pnlPct != null)
                      Text(Fmt.pct(pnl),
                          style: TextStyle(
                              color: pnlColor, fontWeight: FontWeight.w600, fontSize: 13))
                    else
                      const Text('상세 ›',
                          style: TextStyle(color: Color(0xFF6E7681), fontSize: 11)),
                    Text('${MarketClock.elapsedDays(s.createdAt)}일',
                        style: const TextStyle(color: Color(0xFF6E7681), fontSize: 10)),
                  ]),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  void _showMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(margin: const EdgeInsets.symmetric(vertical: 8),
            width: 36, height: 4,
            decoration: BoxDecoration(color: const Color(0xFF30363D),
                borderRadius: BorderRadius.circular(2))),
          ListTile(
            leading: Icon(Icons.drive_file_rename_outline, color: AppTheme.accent),
            title: const Text('이름 변경'),
            onTap: () { Navigator.pop(context); onRename(); },
          ),
          ListTile(
            leading: Icon(strategy.active ? Icons.pause : Icons.play_arrow,
                color: AppTheme.accent),
            title: Text(strategy.active ? '비활성화' : '활성화'),
            onTap: () { Navigator.pop(context); onToggle(); },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Color(0xFFF85149)),
            title: const Text('삭제', style: TextStyle(color: Color(0xFFF85149))),
            onTap: () { Navigator.pop(context); onDelete(); },
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}

// ── No-strategy holding row ──────────────────────────────────────
class _NoStratRow extends StatelessWidget {
  final Map<String, dynamic> holding;
  final VoidCallback onAdd;
  const _NoStratRow({required this.holding, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final ticker  = holding['ticker'] as String? ?? '';
    final name    = holding['name'] as String? ?? ticker;
    final shares  = (holding['shares'] as num? ?? 0).toDouble();
    final price   = (holding['current_price'] as num? ?? 0).toDouble();
    final avg     = (holding['avg_price'] as num? ?? 0).toDouble();
    final market  = holding['market'] as String? ?? 'KR';
    final evalAmt = shares * price;
    final pnl     = Calc.pnlPct(avg, price);
    final pnlColor = pnl >= 0 ? const Color(0xFF2EA043) : const Color(0xFFF85149);

    final evalStr  = market == 'KR' ? Fmt.krw(evalAmt)  : Fmt.usd(evalAmt);
    final priceStr = market == 'KR' ? Fmt.krw(price)    : Fmt.usd(price);
    final sharesStr = Fmt.shares(shares);

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF21262D)),
      ),
      child: Row(children: [
        // 티커 + 종목명
        SizedBox(
          width: 64,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ticker,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
            Text(_Chip._truncate(name, 10),
                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
          ]),
        ),
        const SizedBox(width: 6),
        // 평가금
        Expanded(child: Text(evalStr,
            style: const TextStyle(fontSize: 11),
            textAlign: TextAlign.right)),
        const SizedBox(width: 10),
        // 보유수량
        Text(sharesStr,
            style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
        const SizedBox(width: 10),
        // 1주당 현재가
        Text(priceStr,
            style: const TextStyle(fontSize: 11)),
        const SizedBox(width: 10),
        // ±%
        Text(Fmt.pct(pnl),
            style: TextStyle(color: pnlColor, fontSize: 11)),
        const SizedBox(width: 10),
        // + 추가
        GestureDetector(
          onTap: onAdd,
          child: Text('+ 추가',
              style: TextStyle(color: AppTheme.accent, fontSize: 10)),
        ),
      ]),
    );
  }
}

class _SecLabel extends StatelessWidget {
  final String text;
  const _SecLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          color: Color(0xFF8B949E), fontSize: 12, fontWeight: FontWeight.w600));
}

class _Chip extends StatelessWidget {
  final String label;
  final Color? color;
  final Color? textColor;
  const _Chip(this.label, {this.color, this.textColor});

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

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

class _ErrView extends StatelessWidget {
  final String msg;
  final VoidCallback onRetry;
  const _ErrView({required this.msg, required this.onRetry});
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, color: Color(0xFFF85149), size: 36),
          const SizedBox(height: 12),
          SelectableText(
            msg,
            style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11, fontFamily: 'monospace'),
            textAlign: TextAlign.left,
          ),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: onRetry, child: const Text('다시 시도')),
        ]),
      );
}

// ═══════════════════════════════════════════════════════════════
// 전략 추가 시트 (3-step)
// ═══════════════════════════════════════════════════════════════
class _AddSheet extends StatefulWidget {
  final Map<String, List<Map<String, dynamic>>> noStratHoldings;
  final double cashKr;
  final double cashUs;
  final String? preselectedTicker;
  final VoidCallback onSaved;

  const _AddSheet({
    required this.noStratHoldings,
    required this.cashKr,
    required this.cashUs,
    this.preselectedTicker,
    required this.onSaved,
  });

  @override
  State<_AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<_AddSheet> {
  int _step = 0;

  // Step 0
  final _idCtrl = TextEditingController();
  String _type = 'kr_value'; // 'kr_value', 'mm', 'vr'
  String _mmType = 'v4';     // MM sub-type: 'v1', 'v4'
  String _vrMode = '적립식'; // VR sub-type: '적립식' | '거치식' | '인출식'
  bool _vrResume = false;   // 기존 VR 이어받기
  int _vrCyclePeriod = 4;   // 사이클 주기 (2주 or 4주)
  final _vrV1Ctrl = TextEditingController();
  final _vrCycleCtrl = TextEditingController(text: '1');
  final _capitalCtrl = TextEditingController();
  String _capCurrency = 'KRW'; // 'KRW' or 'USD' — flip toggle
  bool _usePct = false;        // % 버튼 on/off
  final _divCtrl = TextEditingController(text: '40');
  final _starBaseCtrl = TextEditingController(text: '20');
  final _starCoeffCtrl = TextEditingController(text: '2.0');
  final _v1ProfitCtrl = TextEditingController(text: '5');

  // Step 1
  final _searchCtrl = TextEditingController();
  final Set<String> _selected = {};
  final Map<String, String> _names = {};
  String? _market; // 자동 감지

  // Step 2
  final Map<String, TextEditingController> _wCtrl = {};
  Map<String, Map<String, dynamic>> _quotes = {};
  bool _saving = false;
  String? _errMsg;

  // ── Helpers ──────────────────────────────────────────────────
  String get _actualType => _type == 'mm' ? _mmType : _type;
  bool get _isPortfolio => _actualType == 'kr_value';
  String get _capUnit => _usePct ? 'PCT' : _capCurrency;

  String _detectMarket(String ticker) =>
      RegExp(r'^\d+$').hasMatch(ticker) ? 'KR' : 'US';

  List<Map<String, dynamic>> get _allHoldings {
    final all = <Map<String, dynamic>>[];
    for (final mk in ['KR', 'US']) {
      for (final h in widget.noStratHoldings[mk] ?? []) {
        all.add({...Map<String, dynamic>.from(h as Map), 'market': mk});
      }
    }
    return all;
  }

  double get _availableInCapUnit {
    if (_capUnit == 'KRW') return widget.cashKr;
    if (_capUnit == 'USD') return widget.cashUs;
    // PCT: use detected market or fall back to KR
    return _market == null ? widget.cashKr : (_market == 'KR' ? widget.cashKr : widget.cashUs);
  }

  double get _capital {
    final v = double.tryParse(_capitalCtrl.text) ?? 0;
    if (_capUnit == 'PCT') {
      return _availableInCapUnit > 0 ? _availableInCapUnit * v / 100 : 0;
    }
    return v;
  }

  @override
  void initState() {
    super.initState();
    for (final mk in ['KR', 'US']) {
      for (final h in widget.noStratHoldings[mk] ?? []) {
        final t = h['ticker'] as String? ?? '';
        _names[t] = h['name'] as String? ?? t;
      }
    }
    if (widget.preselectedTicker != null) {
      final t = widget.preselectedTicker!;
      _selected.add(t);
      // Use holding's market tag if available, else detect from format
      String? detected;
      Map<String, dynamic>? holdingData;
      for (final mk in ['KR', 'US']) {
        for (final h in widget.noStratHoldings[mk] ?? []) {
          if (h['ticker'] == t) { detected = mk; holdingData = Map<String, dynamic>.from(h as Map); }
        }
      }
      _market = detected ?? _detectMarket(t);
      // Auto-set currency to match the pre-selected holding's market
      _capCurrency = _market == 'US' ? 'USD' : 'KRW';
      // Pre-populate quote so step 1 chip shows green immediately
      if (holdingData != null) {
        _quotes[t] = {
          'current_price': holdingData['current_price'],
          'price': holdingData['current_price'],
          'name': holdingData['name'] ?? t,
        };
      }
    }
  }

  @override
  void dispose() {
    _idCtrl.dispose();
    _capitalCtrl.dispose();
    _searchCtrl.dispose();
    _divCtrl.dispose();
    _starBaseCtrl.dispose();
    _starCoeffCtrl.dispose();
    _v1ProfitCtrl.dispose();
    _vrV1Ctrl.dispose();
    _vrCycleCtrl.dispose();
    for (final c in _wCtrl.values) { c.dispose(); }
    super.dispose();
  }

  bool _canProceed() {
    switch (_step) {
      case 0:
        final rawV = double.tryParse(_capitalCtrl.text) ?? 0;
        if (_idCtrl.text.trim().isEmpty || rawV <= 0) return false;
        // QT/VR: must not exceed available balance
        if (_type != 'mm' && _availableInCapUnit > 0 && _capital > _availableInCapUnit) return false;
        return true;
      case 1:
        if (_saving) return false;
        if (_selected.isEmpty) return false;
        // Block if any ticker is still loading (no entry in _quotes yet)
        if (_selected.any((t) => !_quotes.containsKey(t))) return false;
        // Block if any ticker is invalid
        if (_selected.any((t) => _quotes[t]?['error'] == true)) return false;
        // Weight sum check (portfolio)
        if (_selected.length > 1) {
          final totalW = _selected.fold(0.0,
              (s, t) => s + (double.tryParse(_wCtrl[t]?.text ?? '0') ?? 0));
          if (totalW > 100) return false;
        }
        for (final ticker in _selected) {
          final q = _quotes[ticker];
          if (q == null) return false;
          final price = (q['price'] as num? ?? q['current_price'] as num? ?? 0).toDouble();
          if (price <= 0) continue;
          final w = double.tryParse(_wCtrl[ticker]?.text ?? '0') ?? 0;
          if (_capital * w / 100 < price) return false;
        }
        return true;
      default:
        return false;
    }
  }

  Future<void> _next() async {
    setState(() { _step++; _errMsg = null; });
  }

  Future<void> _addAndValidate(String raw) async {
    final mkt = _detectMarket(raw);
    if (!_isPortfolio && _selected.isNotEmpty) {
      setState(() { _errMsg = 'MM/VR 전략은 종목 1개만 선택 가능합니다'; });
      return;
    }
    // Currency → Market constraint (non-PCT mode)
    if (!_usePct) {
      final expectedMkt = _capCurrency == 'KRW' ? 'KR' : 'US';
      if (mkt != expectedMkt) {
        final curr = _capCurrency == 'KRW' ? '원화(KRW)' : '달러(USD)';
        setState(() { _errMsg = '$curr 할당 시 $expectedMkt 시장 종목만 추가 가능합니다'; });
        return;
      }
    }
    if (_market != null && _market != mkt) {
      setState(() { _errMsg = '$_market 시장 종목만 추가할 수 있습니다'; });
      return;
    }
    final t = mkt == 'KR' ? raw.padLeft(6, '0') : raw.toUpperCase();
    _names[t] = t;
    setState(() {
      _selected.add(t);
      _market ??= mkt;
      _errMsg = null;
      _searchCtrl.clear();
    });
    try {
      final q = await ApiService.getQuote(t, mkt);
      if (!mounted) return;
      setState(() {
        if (q.containsKey('name')) _names[t] = q['name'] as String;
        _quotes[t] = q;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() { _quotes[t] = {'error': true}; });
    }
  }

  void _equalWeight() {
    if (_selected.isEmpty) return;
    final raw = 100.0 / _selected.length;
    final floored = (raw * 1000).floor() / 1000;
    final w = floored.toStringAsFixed(3);
    for (final t in _selected) {
      _wCtrl.putIfAbsent(t, () => TextEditingController());
      _wCtrl[t]!.text = w;
    }
    setState(() {});
  }

  Future<void> _save() async {
    setState(() { _saving = true; _errMsg = null; });
    try {
      final stratId = _idCtrl.text.trim();
      final isPortfolio = _actualType == 'kr_value';
      final isVrResume = _actualType == 'vr' && _vrResume;
      final s = Strategy(
        strategyId: stratId,
        type: _actualType,
        symbol: isPortfolio ? '' : (_selected.isNotEmpty ? _selected.first : ''),
        market: _market ?? 'KR',
        capital: _capital,
        createdAt: DateTime.now(),
        v1Value: _actualType == 'v1' ? (double.tryParse(_v1ProfitCtrl.text) ?? 5.0) : null,
        divisions: (_actualType == 'v1' || _actualType == 'v4') ? (int.tryParse(_divCtrl.text) ?? (_actualType == 'v1' ? 10 : 40)) : null,
        starBase: _actualType == 'v4' ? (int.tryParse(_starBaseCtrl.text) ?? 20) : null,
        starCoeff: _actualType == 'v4' ? (double.tryParse(_starCoeffCtrl.text) ?? 2.0) : null,
        vrMode: _actualType == 'vr' ? _vrMode : null,
        tValue: isVrResume ? double.tryParse(_vrV1Ctrl.text.trim()) : null,
        cycleNo: isVrResume ? (int.tryParse(_vrCycleCtrl.text.trim()) ?? 1) : null,
        cyclePeriod: _actualType == 'vr' ? _vrCyclePeriod : null,
      );
      await AppDatabase.insertStrategy(s);
      for (final ticker in _selected) {
        final w = double.tryParse(_wCtrl[ticker]?.text ?? '0') ?? 0;
        final name = (_quotes[ticker] as Map?)?['name'] as String? ?? _names[ticker] ?? ticker;
        await AppDatabase.savePortfolioStock(stratId, ticker, name, w);
      }

      // QT 전략: 생성 즉시 종목별 비중대로 매수 주문 실행
      if (isPortfolio && _selected.isNotEmpty && mounted) {
        final mkt = _market ?? 'KR';
        final quotesMap = <String, Map<String, dynamic>>{};
        for (final ticker in _selected) {
          final q = _quotes[ticker];
          if (q is Map<String, dynamic> && q['error'] != true) quotesMap[ticker] = q;
        }

        // 1주도 못 사는 종목 검증
        final blockedTickers = <String>{};
        final blockedNames = <String>[];
        for (final ticker in _selected) {
          final q = quotesMap[ticker];
          final price = (q?['price'] as num? ?? q?['current_price'] as num? ?? 0).toDouble();
          final w = double.tryParse(_wCtrl[ticker]?.text ?? '100') ?? 100.0;
          final qty = price > 0 ? (_capital * w / 100 / price).floor() : 0;
          if (qty < 1) {
            blockedTickers.add(ticker);
            blockedNames.add('$ticker (${_names[ticker] ?? ticker})');
          }
        }
        if (blockedTickers.isNotEmpty && mounted) {
          final proceed = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              backgroundColor: const Color(0xFF161B22),
              title: const Text('매수 불가 종목'),
              content: Text('할당금액으로 1주도 매수할 수 없는 종목:\n${blockedNames.join('\n')}\n\n해당 종목을 제외하고 진행할까요?'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('취소')),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: TextButton.styleFrom(foregroundColor: const Color(0xFF58A6FF)),
                  child: const Text('제외 후 진행'),
                ),
              ],
            ),
          );
          if (proceed != true) {
            setState(() { _saving = false; });
            return;
          }
          for (final t in blockedTickers) {
            _selected.remove(t);
            quotesMap.remove(t);
          }
          if (_selected.isEmpty) {
            setState(() { _errMsg = '매수 가능한 종목이 없습니다.'; _saving = false; });
            return;
          }
        }

        final stocksList = _selected.map((ticker) {
          final q = quotesMap[ticker];
          return <String, dynamic>{
            'ticker': ticker,
            'name': q?['name'] as String? ?? _names[ticker] ?? ticker,
            'weight': double.tryParse(_wCtrl[ticker]?.text ?? '100') ?? 100.0,
          };
        }).toList();

        if (mounted) {
          await showDialog(
            context: context,
            barrierDismissible: false,
            builder: (_) => _QtOrderDialog(
              stocks: stocksList,
              capital: _capital,
              market: mkt,
              quotes: quotesMap,
              strategyId: stratId,
            ),
          );
        }
      }

      if (mounted) Navigator.pop(context);
      widget.onSaved();
    } catch (e) {
      if (mounted) setState(() { _errMsg = e.toString(); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.88,
        child: Column(children: [
          Container(margin: const EdgeInsets.symmetric(vertical: 8),
            width: 36, height: 4,
            decoration: BoxDecoration(color: const Color(0xFF30363D),
                borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(children: [
              if (_step > 0)
                GestureDetector(
                  onTap: () => setState(() { _step--; _errMsg = null; }),
                  child: const Icon(Icons.arrow_back_ios, size: 16,
                      color: Color(0xFF8B949E)),
                )
              else
                const SizedBox(width: 16),
              const Spacer(),
              Text('전략 추가 (${_step + 1}/2)',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              const Spacer(),
              const SizedBox(width: 16),
            ]),
          ),
          const Divider(color: Color(0xFF30363D), height: 1),
          Expanded(child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: _stepContent(),
          )),
          if (_errMsg != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(_errMsg!, style: const TextStyle(
                  color: Color(0xFFF85149), fontSize: 11),
                  textAlign: TextAlign.center),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
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
                onPressed: _canProceed() ? (_step < 1 ? _next : _save) : null,
                child: _saving
                    ? const SizedBox(height: 16, width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(_step < 1 ? '다음 →' : '저장'),
              )),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _stepContent() {
    switch (_step) {
      case 0: return _step0();
      default: return _step1();
    }
  }

  // ── Step 0: 전략 기본 설정 ──────────────────────────────────
  Widget _step0() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _Lbl('전략 이름'),
      _Inp(controller: _idCtrl, hint: '예: MM-US-01', onChanged: (_) => setState(() {})),
      const SizedBox(height: 14),

      _Lbl('유형'),
      DropdownButtonFormField<String>(
        value: _type,
        dropdownColor: const Color(0xFF161B22),
        style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 13),
        decoration: _inputDecoration(),
        items: const [
          DropdownMenuItem(value: 'kr_value', child: Text('QT')),
          DropdownMenuItem(value: 'mm', child: Text('MM')),
          DropdownMenuItem(value: 'vr', child: Text('VR')),
        ],
        onChanged: (v) => setState(() { _type = v!; }),
      ),

      // MM sub-type scrollable selector
      if (_type == 'mm') ...[
        const SizedBox(height: 12),
        _Lbl('MM 전략'),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            _MmTypeChip(
              label: 'V1', subtitle: '영혼법',
              selected: _mmType == 'v1',
              onTap: () => setState(() {
                _mmType = 'v1';
                if (_divCtrl.text == '40') _divCtrl.text = '10';
              }),
            ),
            const SizedBox(width: 8),
            _MmTypeChip(
              label: 'V4', subtitle: '분할매수',
              selected: _mmType == 'v4',
              onTap: () => setState(() {
                _mmType = 'v4';
                if (_divCtrl.text == '10') _divCtrl.text = '40';
              }),
            ),
          ]),
        ),
      ],
      // VR mode selector
      if (_type == 'vr') ...[
        const SizedBox(height: 12),
        _Lbl('VR 운용 방식'),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final mode in ['적립식', '거치식', '인출식']) ...[
              if (mode != '적립식') const SizedBox(width: 8),
              _MmTypeChip(
                label: mode,
                subtitle: mode == '적립식' ? '매주 적립' : mode == '거치식' ? '거치 운용' : '매주 인출',
                selected: _vrMode == mode,
                onTap: () => setState(() { _vrMode = mode; }),
              ),
            ],
          ]),
        ),
        const SizedBox(height: 12),
        _Lbl('사이클 주기'),
        Row(children: [
          for (final p in [2, 4]) ...[
            if (p != 2) const SizedBox(width: 8),
            Expanded(child: GestureDetector(
              onTap: () => setState(() { _vrCyclePeriod = p; }),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: _vrCyclePeriod == p ? const Color(0xFF1F6FEB) : const Color(0xFF21262D),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: _vrCyclePeriod == p ? const Color(0xFF1F6FEB) : const Color(0xFF30363D),
                  ),
                ),
                child: Center(child: Text('$p주',
                  style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600,
                    color: _vrCyclePeriod == p ? Colors.white : const Color(0xFF8B949E),
                  ),
                )),
              ),
            )),
          ],
        ]),
        const SizedBox(height: 14),
        GestureDetector(
          onTap: () => setState(() { _vrResume = !_vrResume; }),
          child: Row(children: [
            Icon(
              _vrResume ? Icons.check_box : Icons.check_box_outline_blank,
              size: 18,
              color: _vrResume ? const Color(0xFF58A6FF) : const Color(0xFF8B949E),
            ),
            const SizedBox(width: 6),
            const Text('기존 진행 중인 VR 전략 이어받기',
                style: TextStyle(color: Color(0xFFE6EDF3), fontSize: 13)),
          ]),
        ),
        if (_vrResume) ...[
          const SizedBox(height: 12),
          _Lbl('V₁ 값 (이전 사이클의 V₂)'),
          _Inp(
            controller: _vrV1Ctrl,
            hint: '예: 10000000',
            keyboardType: TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          _Lbl('현재 사이클 번호'),
          _Inp(
            controller: _vrCycleCtrl,
            hint: '1',
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
          ),
        ],
      ],

      const SizedBox(height: 14),

      _Lbl('할당 금액'),
      Row(children: [
        Expanded(child: _Inp(
          controller: _capitalCtrl,
          hint: _capUnit == 'PCT' ? '% 입력' : '금액 입력',
          keyboardType: TextInputType.number,
          onChanged: (_) => setState(() {}),
        )),
        const SizedBox(width: 8),
        // 원↔$ 플립 토글 + % 온/오프 버튼
        Row(mainAxisSize: MainAxisSize.min, children: [
          // 시장이 확정되면(pre-selected 또는 holding 선택) 통화 토글 비활성화
          Opacity(
            opacity: _market != null ? 0.35 : 1.0,
            child: GestureDetector(
              onTap: _market != null ? null : () => setState(() {
                _capCurrency = _capCurrency == 'KRW' ? 'USD' : 'KRW';
                _selected.clear();
                _quotes.clear();
              }),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: const Color(0xFF21262D),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF30363D)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _CurrencySeg('원', _capCurrency == 'KRW'),
                  _CurrencySeg('\$', _capCurrency == 'USD'),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () => setState(() { _usePct = !_usePct; }),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              decoration: BoxDecoration(
                color: _usePct ? const Color(0xFF1F6FEB) : const Color(0xFF21262D),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _usePct ? const Color(0xFF1F6FEB) : const Color(0xFF30363D),
                ),
              ),
              child: Text('%', style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600,
                color: _usePct ? Colors.white : const Color(0xFF8B949E),
              )),
            ),
          ),
        ]),
      ]),
      // Balance display + virtual capital notice
      if (widget.cashKr > 0 || widget.cashUs > 0)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              _usePct
                  ? '총 평가금액  KR: ${Fmt.krw(widget.cashKr)}  /  US: ${Fmt.usd(widget.cashUs)}'
                  : _capCurrency == 'KRW'
                      ? '총 평가금액: ${Fmt.krw(widget.cashKr)}'
                      : '총 평가금액: ${Fmt.usd(widget.cashUs)}',
              style: const TextStyle(fontSize: 11, color: Color(0xFF8B949E)),
            ),
            if (_capital > _availableInCapUnit && _availableInCapUnit > 0 && _capital > 0)
              Text(
                _type == 'mm'
                    ? '⚠ 잔고 초과 — 가상원금으로 운용됩니다'
                    : '✗ 잔고 초과 — QT/VR 전략은 실제 잔고 내에서만 설정 가능합니다',
                style: TextStyle(
                  fontSize: 11,
                  color: _type == 'mm' ? const Color(0xFFD29922) : const Color(0xFFF85149),
                ),
              ),
          ]),
        ),

      // MM constants (V1 + V4 common: 분할수)
      if (_type == 'mm') ...[
        const SizedBox(height: 14),
        _Lbl('전략 설정'),
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_mmType == 'v1' ? '분할 수 (기본 10)' : '분할 수 (기본 40)',
                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
            const SizedBox(height: 4),
            _Inp(controller: _divCtrl,
                hint: _mmType == 'v1' ? '10' : '40',
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {})),
          ])),
          if (_mmType == 'v1') ...[
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('익절 % (기본 5)',
                  style: TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
              const SizedBox(height: 4),
              _Inp(controller: _v1ProfitCtrl, hint: '5',
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {})),
            ])),
          ],
          if (_mmType == 'v4') ...[
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('별지점 상수', style: TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
              const SizedBox(height: 4),
              _Inp(controller: _starBaseCtrl, hint: '20',
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {})),
            ])),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('별지점 계수', style: TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
              const SizedBox(height: 4),
              _Inp(controller: _starCoeffCtrl, hint: '2.0',
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {})),
            ])),
          ],
        ]),
        if (_mmType == 'v1')
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '${_divCtrl.text.isEmpty ? '10' : _divCtrl.text}분할 · 익절 ${_v1ProfitCtrl.text.isEmpty ? '5' : _v1ProfitCtrl.text}%',
              style: const TextStyle(color: Color(0xFF58A6FF), fontSize: 11),
            ),
          ),
        if (_mmType == 'v4')
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '별지점 식: ${_starBaseCtrl.text.isEmpty ? '20' : _starBaseCtrl.text} - ${_starCoeffCtrl.text.isEmpty ? '2.0' : _starCoeffCtrl.text}T  ·  ${_divCtrl.text.isEmpty ? '40' : _divCtrl.text}분할',
              style: const TextStyle(color: Color(0xFF58A6FF), fontSize: 11),
            ),
          ),
      ],
    ]);
  }

  // ── Step 1: 종목 선택 + 시장 자동 감지 ──────────────────────
  Widget _step1() {
    final holdings = _allHoldings;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // 감지된 시장 표시
      if (_market != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            Container(width: 8, height: 8,
              decoration: BoxDecoration(
                color: _market == 'KR' ? AppTheme.krColor : AppTheme.usColor,
                shape: BoxShape.circle,
              )),
            const SizedBox(width: 6),
            Text('$_market 시장 감지됨',
                style: TextStyle(fontSize: 11,
                  color: _market == 'KR' ? AppTheme.krColor : AppTheme.usColor,
                )),
          ]),
        ),

      _Lbl('보유 종목 (전략없음)'),
      const SizedBox(height: 4),
      if (holdings.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('전략없음 종목이 없습니다.',
              style: TextStyle(color: Color(0xFF6E7681), fontSize: 12)),
        )
      else
        ...holdings.map((h) {
          final ticker = h['ticker'] as String? ?? '';
          final name = h['name'] as String? ?? ticker;
          final price = (h['current_price'] as num? ?? 0).toDouble();
          final mkt = h['market'] as String? ?? 'KR';
          final priceStr = mkt == 'KR' ? Fmt.krw(price) : Fmt.usd(price);
          // Disable if currency (in non-PCT mode) doesn't match market
          final currencyLocked = !_usePct &&
              ((_capCurrency == 'KRW' && mkt != 'KR') ||
               (_capCurrency == 'USD' && mkt != 'US'));
          final disabled = currencyLocked || (_market != null && _market != mkt);

          final alreadyFull = !_isPortfolio && _selected.isNotEmpty && !_selected.contains(ticker);
          return CheckboxListTile(
            value: _selected.contains(ticker),
            onChanged: (disabled || alreadyFull) ? null : (v) {
              if (v == true) {
                setState(() {
                  _selected.add(ticker);
                  _market ??= mkt;
                  // Auto-switch currency to match the selected holding's market
                  if (!_usePct) {
                    _capCurrency = mkt == 'KR' ? 'KRW' : 'USD';
                  }
                  // Pre-validate from holding data (known valid)
                  _quotes[ticker] = {
                    'current_price': h['current_price'],
                    'price': h['current_price'],
                    'name': h['name'] ?? ticker,
                  };
                  _names[ticker] = h['name'] as String? ?? ticker;
                });
              } else {
                setState(() {
                  _selected.remove(ticker);
                  _quotes.remove(ticker);
                  if (_selected.isEmpty) _market = null;
                });
              }
            },
            title: Row(children: [
              Text(ticker,
                  style: TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 12,
                    color: (disabled || alreadyFull) ? const Color(0xFF6E7681) : null,
                  )),
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: mkt == 'KR'
                      ? AppTheme.krColor.withValues(alpha: 0.15)
                      : AppTheme.usColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(mkt, style: TextStyle(
                  fontSize: 8,
                  color: mkt == 'KR' ? AppTheme.krColor : AppTheme.usColor,
                )),
              ),
              const SizedBox(width: 4),
              Expanded(child: Text(name,
                  style: TextStyle(
                    color: disabled ? const Color(0xFF6E7681) : const Color(0xFF8B949E),
                    fontSize: 11,
                  ),
                  overflow: TextOverflow.ellipsis)),
            ]),
            subtitle: Text(priceStr,
                style: const TextStyle(color: Color(0xFF6E7681), fontSize: 10)),
            activeColor: AppTheme.accent,
            dense: true,
            contentPadding: EdgeInsets.zero,
          );
        }),

      const Divider(color: Color(0xFF30363D), height: 20),
      _Lbl('직접 입력'),
      Row(children: [
        Expanded(child: _Inp(
          controller: _searchCtrl,
          hint: '숫자 6자리=KR, 영문=US',
          onChanged: (_) => setState(() {}),
        )),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: _searchCtrl.text.trim().isEmpty ? null : () {
            _addAndValidate(_searchCtrl.text.trim());
          },
          style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
          child: const Text('추가'),
        ),
      ]),
      if (_selected.isNotEmpty) ...[
        const SizedBox(height: 12),
        _Lbl('선택 (${_selected.length}개)'),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('초록=유효 · 빨강=무효 · 회색=확인중',
              style: const TextStyle(color: Color(0xFF6E7681), fontSize: 10)),
        ),
        Wrap(spacing: 6, runSpacing: 4, children: _selected.map((t) {
          final isLoading = !_quotes.containsKey(t);
          final isInvalid = _quotes[t]?['error'] == true;
          final isValid = !isLoading && !isInvalid;
          final chipColor = isLoading
              ? const Color(0xFF30363D)
              : isInvalid
                  ? const Color(0xFFF85149)
                  : const Color(0xFF2EA043);
          final bgColor = isLoading
              ? const Color(0xFF21262D)
              : isInvalid
                  ? const Color(0xFFF85149).withValues(alpha: 0.12)
                  : const Color(0xFF2EA043).withValues(alpha: 0.12);
          return InputChip(
            label: Row(mainAxisSize: MainAxisSize.min, children: [
              if (isLoading)
                const SizedBox(width: 10, height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF8B949E)))
              else
                Icon(isValid ? Icons.check_circle_outline : Icons.cancel_outlined,
                    size: 12, color: chipColor),
              const SizedBox(width: 4),
              Text(t, style: TextStyle(fontSize: 11, color: chipColor)),
            ]),
            onDeleted: () => setState(() {
              _selected.remove(t);
              _quotes.remove(t);
              if (_selected.isEmpty) _market = null;
            }),
            deleteIconColor: const Color(0xFF8B949E),
            backgroundColor: bgColor,
            side: BorderSide(color: chipColor),
            padding: EdgeInsets.zero,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          );
        }).toList()),

        // ── 비중 + 매수 주수 인라인 프리뷰 ───────────────────────────
        if (_quotes.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Divider(color: Color(0xFF30363D), height: 1),
          const SizedBox(height: 12),

          // 가용 금액
          if (_availableInCapUnit > 0) ...[
            Text(
              '주문가능: ${_capUnit == "USD" ? Fmt.usd(_availableInCapUnit) : Fmt.krw(_availableInCapUnit)}'
              '  /  할당: ${_capUnit == "USD" ? Fmt.usd(_capital) : Fmt.krw(_capital)}',
              style: const TextStyle(fontSize: 11, color: Color(0xFF8B949E)),
            ),
            if (_capital > _availableInCapUnit && _capital > 0)
              Text(
                _type == 'mm'
                    ? '⚠ 잔고 초과 — 가상원금으로 운용됩니다'
                    : '✗ 잔고 초과',
                style: TextStyle(
                  fontSize: 11,
                  color: _type == 'mm' ? const Color(0xFFD29922) : const Color(0xFFF85149),
                ),
              ),
            const SizedBox(height: 10),
          ],

          // 종목별 비중 (포트폴리오 2개 이상)
          if (_selected.length > 1) ...[
            () {
              for (final t in _selected) {
                _wCtrl.putIfAbsent(t, () => TextEditingController(text: '0'));
              }
              final totalW = _selected.fold(0.0,
                  (s, t) => s + (double.tryParse(_wCtrl[t]?.text ?? '0') ?? 0));
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  _Lbl('종목별 비중 (%)'),
                  const Spacer(),
                  TextButton(
                    onPressed: _equalWeight,
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF58A6FF),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('동일 비중', style: TextStyle(fontSize: 11)),
                  ),
                ]),
                const SizedBox(height: 6),
                ..._selected.map((ticker) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(ticker, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                      Text(_names[ticker] ?? ticker,
                          style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10),
                          overflow: TextOverflow.ellipsis),
                    ])),
                    SizedBox(width: 72, child: _Inp(
                      controller: _wCtrl[ticker]!,
                      hint: '0.0',
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setState(() {}),
                    )),
                    const Padding(padding: EdgeInsets.only(left: 6),
                        child: Text('%', style: TextStyle(color: Color(0xFF8B949E), fontSize: 12))),
                  ]),
                )),
                Align(alignment: Alignment.centerRight, child: Text(
                  '합계: ${totalW.toStringAsFixed(1)}%',
                  style: TextStyle(
                    color: totalW > 100
                        ? const Color(0xFFF85149)
                        : (totalW - 100).abs() < 0.5
                            ? const Color(0xFF2EA043)
                            : const Color(0xFF8B949E),
                    fontSize: 11,
                  ),
                )),
                const SizedBox(height: 10),
              ]);
            }(),
          ] else if (_selected.length == 1) ...[
            () {
              final t = _selected.first;
              _wCtrl.putIfAbsent(t, () => TextEditingController(text: '100'));
              _wCtrl[t]!.text = '100';
              return const SizedBox.shrink();
            }(),
          ],

          // 매수 가능 주수 미리보기
          _Lbl('매수 가능 주수 (현재가 기준)'),
          const SizedBox(height: 6),
          ...() {
            final mkt = _market ?? 'KR';
            return _selected
                .where((t) => _quotes.containsKey(t) && _quotes[t]?['error'] != true)
                .map((ticker) {
              final q = _quotes[ticker]!;
              final price = (q['price'] as num? ?? q['current_price'] as num? ?? 0).toDouble();
              final w = double.tryParse(_wCtrl[ticker]?.text ?? '100') ?? 100;
              final allocated = _capital * w / 100;
              final shares = price > 0 ? (allocated / price).floor() : 0;
              final name = q['name'] as String? ?? _names[ticker] ?? ticker;
              final allocStr = mkt == 'KR' ? Fmt.krw(allocated) : Fmt.usd(allocated);
              final priceStr = mkt == 'KR' ? Fmt.krw(price) : Fmt.usd(price);
              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D1117),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF21262D)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(ticker, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                    const SizedBox(width: 6),
                    Expanded(child: Text(name,
                        style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10),
                        overflow: TextOverflow.ellipsis)),
                    Text('$shares주', style: TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 12,
                        color: shares < 1 ? const Color(0xFFF85149) : const Color(0xFF58A6FF))),
                  ]),
                  const SizedBox(height: 2),
                  Text('할당: $allocStr  ·  현재가: $priceStr',
                      style: const TextStyle(color: Color(0xFF6E7681), fontSize: 10)),
                ]),
              );
            }).toList();
          }(),

          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF30363D)),
            ),
            child: Row(children: [
              const Icon(Icons.schedule, size: 14, color: Color(0xFF8B949E)),
              const SizedBox(width: 8),
              Text(
                (_market ?? 'KR') == 'KR' ? MarketClock.nextKrOpen() : MarketClock.nextUsOpen(),
                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12),
              ),
            ]),
          ),
        ],
      ],
    ]);
  }

  InputDecoration _inputDecoration() => const InputDecoration(
    filled: true, fillColor: Color(0xFF0D1117),
    border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF30363D))),
    enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF30363D))),
    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  );
}

// ── 원/$ 플립 토글 세그먼트 ───────────────────────────────────────
class _CurrencySeg extends StatelessWidget {
  final String label;
  final bool selected;
  const _CurrencySeg(this.label, this.selected);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1F6FEB) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label, style: TextStyle(
          fontSize: 12, fontWeight: FontWeight.w600,
          color: selected ? Colors.white : const Color(0xFF8B949E),
        )),
      );
}

// ── MM 세부 전략 선택 칩 ─────────────────────────────────────────
class _MmTypeChip extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  const _MmTypeChip({
    required this.label, required this.subtitle,
    required this.selected, required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF1F6FEB) : const Color(0xFF21262D),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? const Color(0xFF1F6FEB) : const Color(0xFF30363D),
            ),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w700,
              color: selected ? Colors.white : const Color(0xFFE6EDF3),
            )),
            const SizedBox(height: 2),
            Text(subtitle, style: TextStyle(
              fontSize: 10,
              color: selected ? Colors.white70 : const Color(0xFF8B949E),
            )),
          ]),
        ),
      );
}

// ── Sheet form helpers ───────────────────────────────────────────
class _Lbl extends StatelessWidget {
  final String text;
  const _Lbl(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: const TextStyle(
            color: Color(0xFF8B949E), fontSize: 11, fontWeight: FontWeight.w600)),
      );
}

class _Inp extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final TextInputType? keyboardType;
  final void Function(String)? onChanged;
  final bool readOnly;
  const _Inp({required this.controller, required this.hint,
      this.keyboardType, this.onChanged, this.readOnly = false});

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        keyboardType: keyboardType,
        onChanged: onChanged,
        readOnly: readOnly,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: Color(0xFF6E7681), fontSize: 12),
          filled: true, fillColor: const Color(0xFF0D1117),
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
        ),
      );
}


// ═══════════════════════════════════════════════════════════════
// QT 전략 생성 시 주문 로딩 다이얼로그
// ═══════════════════════════════════════════════════════════════
class _QtOrderDialog extends StatefulWidget {
  final List<Map<String, dynamic>> stocks;
  final double capital;
  final String market;
  final Map<String, Map<String, dynamic>> quotes;
  final String strategyId;

  const _QtOrderDialog({
    required this.stocks,
    required this.capital,
    required this.market,
    required this.quotes,
    required this.strategyId,
  });

  @override
  State<_QtOrderDialog> createState() => _QtOrderDialogState();
}

class _QtOrderDialogState extends State<_QtOrderDialog> {
  // ticker → 'pending' | 'done' | 'scheduled' | 'error' | 'skip'
  final Map<String, String> _status = {};
  // ticker → {plannedQty, plannedPrice, allocationAmount}
  final Map<String, Map<String, dynamic>> _plan = {};
  bool _done = false;

  @override
  void initState() {
    super.initState();
    for (final s in widget.stocks) {
      _status[s['ticker'] as String] = 'pending';
    }
    _run();
  }

  Future<void> _run() async {
    final isOpen = widget.market == 'KR' ? MarketClock.isKrOpen : MarketClock.isUsOpen;
    final now = DateTime.now();
    final createdAt = now.toIso8601String();

    // 계획 계산
    for (final stock in widget.stocks) {
      final ticker = stock['ticker'] as String;
      final weight = (stock['weight'] as num? ?? 0).toDouble();
      final q = widget.quotes[ticker];
      final price = (q?['price'] as num? ?? q?['current_price'] as num? ?? 0).toDouble();
      final alloc = widget.capital * weight / 100;
      final qty = price > 0 ? (alloc / price).floor() : 0;
      _plan[ticker] = {'plannedQty': qty, 'plannedPrice': price, 'allocationAmount': alloc};
    }

    // QT 세션 생성
    final sessionId = await AppDatabase.insertQtSession({
      'strategy_id': widget.strategyId,
      'session_type': 'create',
      'total_capital': widget.capital,
      'market': widget.market,
      'status': 'active',
      'created_at': createdAt,
    });

    if (!isOpen) {
      // 장 마감: 서버에 등록하고 Scheduled 상태로 저장
      try {
        await ApiService.rebalance(widget.strategyId);
      } catch (_) {}

      for (final stock in widget.stocks) {
        final ticker = stock['ticker'] as String;
        final name = stock['name'] as String? ?? ticker;
        final weight = (stock['weight'] as num? ?? 0).toDouble();
        final p = _plan[ticker]!;
        final qty = p['plannedQty'] as int;
        final price = p['plannedPrice'] as double;
        final alloc = p['allocationAmount'] as double;

        if (qty <= 0) {
          if (mounted) setState(() { _status[ticker] = 'skip'; });
          continue;
        }
        await AppDatabase.insertQtOrderItem({
          'session_id': sessionId,
          'strategy_id': widget.strategyId,
          'ticker': ticker,
          'name': name,
          'weight': weight,
          'allocation_amount': alloc,
          'planned_qty': qty,
          'planned_price': price,
          'actual_qty': 0,
          'actual_price': 0.0,
          'status': 'Scheduled',
          'side': 'BUY',
          'created_at': createdAt,
        });
        if (mounted) setState(() { _status[ticker] = 'scheduled'; });
      }
    } else {
      // 장 중: 즉시 주문
      for (final stock in widget.stocks) {
        final ticker = stock['ticker'] as String;
        final name = stock['name'] as String? ?? ticker;
        final weight = (stock['weight'] as num? ?? 0).toDouble();
        final p = _plan[ticker]!;
        final qty = p['plannedQty'] as int;
        final price = p['plannedPrice'] as double;
        final alloc = p['allocationAmount'] as double;

        if (qty <= 0 || price <= 0) {
          if (mounted) setState(() { _status[ticker] = 'skip'; });
          continue;
        }

        // DB에 항목 저장 (Scheduled 상태)
        await AppDatabase.insertQtOrderItem({
          'session_id': sessionId,
          'strategy_id': widget.strategyId,
          'ticker': ticker,
          'name': name,
          'weight': weight,
          'allocation_amount': alloc,
          'planned_qty': qty,
          'planned_price': price,
          'actual_qty': 0,
          'actual_price': 0.0,
          'status': 'Scheduled',
          'side': 'BUY',
          'created_at': createdAt,
        });

        try {
          await ApiService.placeOrder(
            market: widget.market,
            ticker: ticker,
            side: 'BUY',
            quantity: qty,
            price: 0,
            ordDvsn: '01',
          );
          if (mounted) setState(() { _status[ticker] = 'done'; });
        } catch (_) {
          if (mounted) setState(() { _status[ticker] = 'error'; });
        }
      }
    }

    if (mounted) setState(() { _done = true; });
    await Future.delayed(const Duration(milliseconds: 800));
    if (mounted && Navigator.canPop(context)) Navigator.of(context).pop();
  }

  String _fmtMoney(double v) =>
      widget.market == 'KR' ? Fmt.krw(v) : Fmt.usd(v);

  @override
  Widget build(BuildContext context) {
    final isOpen = widget.market == 'KR' ? MarketClock.isKrOpen : MarketClock.isUsOpen;
    return AlertDialog(
      backgroundColor: const Color(0xFF161B22),
      title: Text(
        _done
            ? (isOpen ? '주문 완료' : '장 마감 — 다음 개장 시 실행')
            : (isOpen ? '주문 생성 중...' : '서버 등록 중...'),
        style: const TextStyle(fontSize: 14),
      ),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!_done) const LinearProgressIndicator(
              backgroundColor: Color(0xFF21262D),
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF58A6FF)),
            ),
            const SizedBox(height: 10),
            // 컬럼 헤더
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(children: [
                Expanded(flex: 3, child: Text('종목', style: TextStyle(color: Color(0xFF6E7681), fontSize: 10))),
                SizedBox(width: 40, child: Text('비중', textAlign: TextAlign.right, style: TextStyle(color: Color(0xFF6E7681), fontSize: 10))),
                SizedBox(width: 56, child: Text('할당금액', textAlign: TextAlign.right, style: TextStyle(color: Color(0xFF6E7681), fontSize: 10))),
                SizedBox(width: 44, child: Text('수량', textAlign: TextAlign.right, style: TextStyle(color: Color(0xFF6E7681), fontSize: 10))),
                SizedBox(width: 32),
              ]),
            ),
            const Divider(color: Color(0xFF30363D), height: 8),
            ...widget.stocks.map((s) {
              final ticker = s['ticker'] as String;
              final name = s['name'] as String? ?? ticker;
              final weight = (s['weight'] as num? ?? 0).toDouble();
              final st = _status[ticker] ?? 'pending';
              final p = _plan[ticker];
              final qty = p?['plannedQty'] as int? ?? 0;
              final alloc = p?['allocationAmount'] as double? ?? 0;

              final Color stColor;
              final Widget stIcon;
              if (st == 'done' || st == 'scheduled') {
                stColor = const Color(0xFF2EA043);
                stIcon = const Icon(Icons.check_circle, size: 14, color: Color(0xFF2EA043));
              } else if (st == 'error') {
                stColor = const Color(0xFFF85149);
                stIcon = const Icon(Icons.error_outline, size: 14, color: Color(0xFFF85149));
              } else if (st == 'skip') {
                stColor = const Color(0xFF8B949E);
                stIcon = const Icon(Icons.remove_circle_outline, size: 14, color: Color(0xFF8B949E));
              } else {
                stColor = const Color(0xFF8B949E);
                stIcon = const SizedBox(width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8B949E)));
              }

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                child: Row(children: [
                  Expanded(flex: 3, child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(ticker, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: stColor)),
                      Text(name, style: const TextStyle(color: Color(0xFF6E7681), fontSize: 9),
                          overflow: TextOverflow.ellipsis),
                    ],
                  )),
                  SizedBox(width: 40, child: Text('${weight.toStringAsFixed(0)}%',
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 10, color: Color(0xFF8B949E)))),
                  SizedBox(width: 56, child: Text(_fmtMoney(alloc),
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 10, color: Color(0xFF8B949E)))),
                  SizedBox(width: 44, child: Text(qty > 0 ? '${qty}주' : '-',
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: stColor))),
                  const SizedBox(width: 6),
                  stIcon,
                ]),
              );
            }),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 매도 예약 주식 행
// ═══════════════════════════════════════════════════════════════
class _PendingSellRow extends StatelessWidget {
  final Map<String, dynamic> holding;
  final Map<String, dynamic> pendingSell;
  final VoidCallback onCancel;
  final VoidCallback onModify;

  const _PendingSellRow({
    required this.holding,
    required this.pendingSell,
    required this.onCancel,
    required this.onModify,
  });

  static String _fmtScheduled(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ticker = holding['ticker'] as String? ?? '';
    final name = holding['name'] as String? ?? ticker;
    final qty = (holding['shares'] as num? ?? 0).toDouble();
    final price = (holding['current_price'] as num? ?? 0).toDouble();
    final market = holding['market'] as String? ?? 'KR';
    final scheduledAt = pendingSell['scheduled_at'] as String? ?? '';

    final value = qty * price;
    final valStr = price > 0
        ? (market == 'KR' ? Fmt.krw(value) : Fmt.usd(value))
        : '${qty % 1 == 0 ? qty.toInt() : qty}주';

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFF85149).withValues(alpha: 0.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ticker,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
            Text(_Chip._truncate(name, 14),
                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
          ]),
          const SizedBox(width: 8),
          Expanded(child: Text(valStr, style: const TextStyle(fontSize: 11))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFF85149).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text('매도 예약',
                style: TextStyle(color: Color(0xFFF85149), fontSize: 9)),
          ),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          const Icon(Icons.schedule, size: 11, color: Color(0xFF8B949E)),
          const SizedBox(width: 4),
          Expanded(child: Text(
            '예정: ${_fmtScheduled(scheduledAt)}',
            style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10),
          )),
          GestureDetector(
            onTap: onModify,
            child: const Text('정정',
                style: TextStyle(color: Color(0xFF58A6FF), fontSize: 10)),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: onCancel,
            child: const Text('취소',
                style: TextStyle(color: Color(0xFFF85149), fontSize: 10)),
          ),
        ]),
      ]),
    );
  }
}
