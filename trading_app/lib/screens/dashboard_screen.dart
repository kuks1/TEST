import 'package:flutter/material.dart';
import '../core/api_service.dart';
import '../core/common.dart';
import '../core/database.dart';
import '../models/strategy.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _data;
  List<Strategy> _strategies = [];
  bool _noStrategyExpanded = false;
  DateTime? _lastUpdated;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([ApiService.getAccount(), AppDatabase.getStrategies()]);
      setState(() {
        _data = results[0] as Map<String, dynamic>;
        _strategies = results[1] as List<Strategy>;
        _lastUpdated = DateTime.now();
      });
    } catch (e) {
      setState(() { _error = e.toString(); });
    } finally {
      setState(() { _loading = false; });
    }
  }

  double _krTotal() {
    final list = (_data?['kr'] as List?) ?? [];
    return list.fold(0.0, (s, a) => s + (a['total_eval_krw'] as num? ?? 0).toDouble());
  }

  double _usTotal() {
    final list = (_data?['us'] as List?) ?? [];
    return list.fold(0.0, (s, a) {
      final cash = (a['cash_usd'] as num? ?? 0).toDouble();
      final stocks = ((a['holdings'] as List?) ?? []).fold(0.0,
          (hs, h) => hs + (h['shares'] as num? ?? 0) * (h['current_price'] as num? ?? 0));
      return s + cash + stocks;
    });
  }

  // 전략이 없는 보유 종목 목록
  List<Map<String, dynamic>> _noStrategyHoldings() {
    if (_data == null) return [];
    final result = <Map<String, dynamic>>[];
    for (final marketKey in ['kr', 'us']) {
      final market = marketKey == 'kr' ? 'KR' : 'US';
      for (final acc in (_data![marketKey] as List? ?? [])) {
        for (final h in (acc['holdings'] as List? ?? [])) {
          final ticker = h['ticker'] as String? ?? '';
          final hasStrategy = _strategies.any((s) => s.symbol == ticker && s.active);
          if (!hasStrategy) {
            result.add({...Map<String, dynamic>.from(h), 'market': market});
          }
        }
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('계좌현황'),
        actions: [
          if (_lastUpdated != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(child: Text(
                Fmt.datetime(_lastUpdated!).substring(6), // HH:mm
                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11),
              )),
            ),
          IconButton(
            icon: _loading
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _error != null
          ? _ErrView(msg: _error!, onRetry: _load)
          : _loading && _data == null
              ? const Center(child: CircularProgressIndicator())
              : _buildBody(),
    );
  }

  Widget _buildBody() {
    final activeStrategies = _strategies.where((s) => s.active).toList();
    final noStratHoldings = _noStrategyHoldings();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          // ── KR / US 총평가금액 2열 ─────────────────────────
          Row(children: [
            Expanded(child: _TotalCard(
              label: '한국', market: 'KR',
              value: Fmt.krw(_krTotal()),
            )),
            const SizedBox(width: 8),
            Expanded(child: _TotalCard(
              label: '미국', market: 'US',
              value: Fmt.usd(_usTotal()),
            )),
          ]),
          const SizedBox(height: 14),

          // ── 활성 전략 ──────────────────────────────────────
          if (activeStrategies.isNotEmpty) ...[
            const _SectionLabel('활성 전략'),
            ...activeStrategies.map((s) => _ActiveStrategyRow(
              strategy: s,
              accountData: _data,
            )),
            const SizedBox(height: 14),
          ],

          // ── 전략없음 종목 ──────────────────────────────────
          if (noStratHoldings.isNotEmpty) ...[
            Row(children: [
              _SectionLabel('전략없음 (${noStratHoldings.length}개)'),
              const Spacer(),
              if (noStratHoldings.length > 10)
                GestureDetector(
                  onTap: () => setState(() { _noStrategyExpanded = !_noStrategyExpanded; }),
                  child: Text(
                    _noStrategyExpanded ? '접기' : '전체 보기',
                    style: const TextStyle(color: Color(0xFF58A6FF), fontSize: 11),
                  ),
                ),
            ]),
            const SizedBox(height: 6),
            ...(_noStrategyExpanded
                    ? noStratHoldings
                    : noStratHoldings.take(10).toList())
                .map((h) => _NoStratRow(holding: h)),
            if (!_noStrategyExpanded && noStratHoldings.length > 10)
              GestureDetector(
                onTap: () => setState(() { _noStrategyExpanded = true; }),
                child: Container(
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161B22),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF30363D)),
                  ),
                  child: Center(
                    child: Text(
                      '... ${noStratHoldings.length - 10}개 더 보기',
                      style: const TextStyle(color: Color(0xFF58A6FF), fontSize: 12),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// ── 위젯들 ──────────────────────────────────────────────────────

class _TotalCard extends StatelessWidget {
  final String label, market, value;
  const _TotalCard({required this.label, required this.market, required this.value});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 8, height: 8,
              decoration: BoxDecoration(
                color: market == 'KR' ? const Color(0xFF2EA043) : const Color(0xFF58A6FF),
                shape: BoxShape.circle,
              )),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
          ]),
          const SizedBox(height: 8),
          Text('총 평가금액', style: const TextStyle(color: Color(0xFF6E7681), fontSize: 10)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(
              color: Color(0xFF58A6FF), fontSize: 14, fontWeight: FontWeight.bold)),
        ]),
      );
}

class _ActiveStrategyRow extends StatelessWidget {
  final Strategy strategy;
  final Map<String, dynamic>? accountData;
  const _ActiveStrategyRow({required this.strategy, required this.accountData});

  double _getPnlPct() {
    if (accountData == null) return 0;
    final marketKey = strategy.market == 'KR' ? 'kr' : 'us';
    for (final acc in (accountData![marketKey] as List? ?? [])) {
      for (final h in (acc['holdings'] as List? ?? [])) {
        if (h['ticker'] == strategy.symbol) {
          final avg = (h['avg_price'] as num? ?? 0).toDouble();
          final cur = (h['current_price'] as num? ?? 0).toDouble();
          return Calc.pnlPct(avg, cur);
        }
      }
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final pnl = _getPnlPct();
    final pnlColor = pnl >= 0 ? const Color(0xFF2EA043) : const Color(0xFFF85149);
    final capitalStr = strategy.market == 'KR'
        ? Fmt.krw(strategy.capital) : Fmt.usd(strategy.capital);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(width: 3, color: const Color(0xFF1F6FEB)),
          Expanded(
            child: Container(
              color: const Color(0xFF161B22),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(strategy.strategyId,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(width: 6),
            _Chip(strategy.typeLabel),
          ]),
          const SizedBox(height: 2),
          Text(capitalStr,
              style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(Fmt.pct(pnl), style: TextStyle(
              color: pnlColor, fontWeight: FontWeight.w600, fontSize: 13)),
          Text(Fmt.date(strategy.createdAt),
              style: const TextStyle(color: Color(0xFF6E7681), fontSize: 10)),
        ]),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _NoStratRow extends StatelessWidget {
  final Map<String, dynamic> holding;
  const _NoStratRow({required this.holding});

  @override
  Widget build(BuildContext context) {
    final ticker = holding['ticker'] as String? ?? '';
    final name = holding['name'] as String? ?? ticker;
    final shares = (holding['shares'] as num? ?? 0).toDouble();
    final price = (holding['current_price'] as num? ?? 0).toDouble();
    final avg = (holding['avg_price'] as num? ?? 0).toDouble();
    final market = holding['market'] as String? ?? 'KR';
    final value = shares * price;
    final pnl = Calc.pnlPct(avg, price);
    final pnlColor = pnl >= 0 ? const Color(0xFF2EA043) : const Color(0xFFF85149);
    final valStr = market == 'KR' ? Fmt.krw(value) : Fmt.usd(value);

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF21262D)),
      ),
      child: Row(children: [
        Text(ticker, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
        const SizedBox(width: 6),
        Expanded(child: Text(name,
            style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11),
            overflow: TextOverflow.ellipsis)),
        Text(valStr, style: const TextStyle(fontSize: 11)),
        const SizedBox(width: 8),
        Text(Fmt.pct(pnl), style: TextStyle(color: pnlColor, fontSize: 11)),
      ]),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(
            color: Color(0xFF8B949E), fontSize: 12, fontWeight: FontWeight.w600)),
      );
}

class _Chip extends StatelessWidget {
  final String label;
  const _Chip(this.label);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
            color: const Color(0x221F6FEB), borderRadius: BorderRadius.circular(8)),
        child: Text(label,
            style: const TextStyle(fontSize: 9, color: Color(0xFF58A6FF))),
      );
}

class _ErrView extends StatelessWidget {
  final String msg;
  final VoidCallback onRetry;
  const _ErrView({required this.msg, required this.onRetry});
  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.wifi_off, color: Color(0xFF8B949E), size: 48),
          const SizedBox(height: 12),
          Text(msg, style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12),
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: onRetry, child: const Text('다시 시도')),
        ]),
      );
}
