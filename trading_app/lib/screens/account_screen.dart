import 'package:flutter/material.dart';
import '../core/api_service.dart';
import '../core/common.dart';
import '../core/database.dart';
import '../models/strategy.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _data;
  List<Strategy> _strategies = [];
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

  List<Map<String, dynamic>> _noStratHoldings(String market) {
    if (_data == null) return [];
    final key = market == 'KR' ? 'kr' : 'us';
    final result = <Map<String, dynamic>>[];
    for (final acc in (_data![key] as List? ?? [])) {
      for (final h in (acc['holdings'] as List? ?? [])) {
        final ticker = h['ticker'] as String? ?? '';
        final hasActive = _strategies.any((s) => s.symbol == ticker && s.active);
        if (!hasActive) result.add(Map<String, dynamic>.from(h));
      }
    }
    return result;
  }

  double _totalEval(String market) {
    if (_data == null) return 0;
    final key = market == 'KR' ? 'kr' : 'us';
    return (_data![key] as List? ?? []).fold(0.0, (s, acc) {
      final cash = market == 'KR'
          ? ((acc['orderable_krw'] ?? acc['cash_krw']) as num? ?? 0).toDouble()
          : (acc['cash_usd'] as num? ?? 0).toDouble();
      final stocks = ((acc['holdings'] as List?) ?? []).fold(0.0,
          (hs, h) => hs + (h['shares'] as num? ?? 0) * (h['current_price'] as num? ?? 0));
      return s + cash + stocks;
    });
  }

  void _openAddSheet(String market, [String? preselected]) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _AddStrategySheet(
        market: market,
        noStratHoldings: _noStratHoldings(market),
        totalCash: _totalEval(market),
        preselectedTicker: preselected,
        onSaved: _load,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('전략현황'),
        actions: [
          if (_lastUpdated != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(child: Text(
                Fmt.datetime(_lastUpdated!).substring(6),
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
    final krList = (_data?['kr'] as List? ?? []);
    final usList = (_data?['us'] as List? ?? []);

    return RefreshIndicator(
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _MarketCol(
              market: 'KR', label: '한국',
              accounts: krList, strategies: _strategies,
              onAdd: (t) => _openAddSheet('KR', t),
            )),
            const SizedBox(width: 8),
            Expanded(child: _MarketCol(
              market: 'US', label: '미국',
              accounts: usList, strategies: _strategies,
              onAdd: (t) => _openAddSheet('US', t),
            )),
          ],
        ),
      ),
    );
  }
}

// ── 시장별 컬럼 ──────────────────────────────────────────────────
class _MarketCol extends StatelessWidget {
  final String market, label;
  final List accounts;
  final List<Strategy> strategies;
  final void Function(String?) onAdd;

  const _MarketCol({
    required this.market, required this.label,
    required this.accounts, required this.strategies,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    double totalCash = 0;
    double usedCapital = 0;

    for (final acc in accounts) {
      if (market == 'KR') {
        totalCash += (acc['total_eval_krw'] as num? ?? 0).toDouble();
      } else {
        final cash = (acc['cash_usd'] as num? ?? 0).toDouble();
        final stocks = ((acc['holdings'] as List?) ?? []).fold(0.0,
            (hs, h) => hs + (h['shares'] as num? ?? 0) * (h['current_price'] as num? ?? 0));
        totalCash += cash + stocks;
      }
    }

    final cards = <Widget>[
      Row(children: [
        Container(width: 8, height: 8,
          decoration: BoxDecoration(
            color: market == 'KR' ? const Color(0xFF2EA043) : const Color(0xFF58A6FF),
            shape: BoxShape.circle,
          )),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(
            color: Color(0xFF8B949E), fontSize: 12, fontWeight: FontWeight.w600)),
        const Spacer(),
        GestureDetector(
          onTap: () => onAdd(null),
          child: const Icon(Icons.add_circle_outline, size: 16, color: Color(0xFF58A6FF)),
        ),
      ]),
      const SizedBox(height: 6),
    ];

    // 활성 전략 카드
    final active = strategies.where((s) => s.active && s.market == market).toList();
    for (final s in active) {
      usedCapital += s.capital;
      double pnl = 0;
      for (final acc in accounts) {
        for (final h in (acc['holdings'] as List? ?? [])) {
          if (h['ticker'] == s.symbol) {
            final avg = (h['avg_price'] as num? ?? 0).toDouble();
            final cur = (h['current_price'] as num? ?? 0).toDouble();
            pnl = Calc.pnlPct(avg, cur);
            break;
          }
        }
      }
      cards.add(_StratCard(strategy: s, pnlPct: pnl, market: market));
    }

    // 전략없음 카드
    for (final acc in accounts) {
      for (final h in (acc['holdings'] as List? ?? [])) {
        final ticker = h['ticker'] as String? ?? '';
        if (!strategies.any((s) => s.symbol == ticker && s.active)) {
          final shares = (h['shares'] as num? ?? 0).toDouble();
          final price = (h['current_price'] as num? ?? 0).toDouble();
          final avg = (h['avg_price'] as num? ?? 0).toDouble();
          cards.add(_NoStratCard(
            ticker: ticker,
            name: h['name'] as String? ?? ticker,
            value: shares * price,
            pnlPct: Calc.pnlPct(avg, price),
            market: market,
            onAdd: () => onAdd(ticker),
          ));
        }
      }
    }

    // 잉여현금
    final surplus = totalCash - usedCapital;
    cards.add(_CashCard(market: market, value: surplus > 0 ? surplus : 0));

    return Column(children: cards);
  }
}

// ── 전략 카드 ─────────────────────────────────────────────────────
class _StratCard extends StatelessWidget {
  final Strategy strategy;
  final double pnlPct;
  final String market;
  const _StratCard({required this.strategy, required this.pnlPct, required this.market});

  @override
  Widget build(BuildContext context) {
    final pnlColor = pnlPct >= 0 ? const Color(0xFF2EA043) : const Color(0xFFF85149);
    final capitalStr = market == 'KR' ? Fmt.krw(strategy.capital) : Fmt.usd(strategy.capital);

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
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(strategy.strategyId,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                      overflow: TextOverflow.ellipsis)),
                  _Chip(strategy.typeLabel),
                ]),
                const SizedBox(height: 4),
                Text(capitalStr,
                    style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
                const SizedBox(height: 2),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(Fmt.pct(pnlPct),
                      style: TextStyle(color: pnlColor, fontSize: 12, fontWeight: FontWeight.w600)),
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

// ── 전략없음 카드 ─────────────────────────────────────────────────
class _NoStratCard extends StatelessWidget {
  final String ticker, name, market;
  final double value, pnlPct;
  final VoidCallback onAdd;
  const _NoStratCard({
    required this.ticker, required this.name, required this.market,
    required this.value, required this.pnlPct, required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final pnlColor = pnlPct >= 0 ? const Color(0xFF2EA043) : const Color(0xFFF85149);
    final valStr = market == 'KR' ? Fmt.krw(value) : Fmt.usd(value);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(ticker,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
          _Chip('전략없음', color: const Color(0xFF21262D), textColor: const Color(0xFF6E7681)),
        ]),
        const SizedBox(height: 2),
        Text(name, style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10),
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 4),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(valStr, style: const TextStyle(fontSize: 11)),
          Text(Fmt.pct(pnlPct),
              style: TextStyle(color: pnlColor, fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: onAdd,
          child: const Text('+ 전략 추가',
              style: TextStyle(color: Color(0xFF58A6FF), fontSize: 10)),
        ),
      ]),
    );
  }
}

// ── 잉여현금 카드 ─────────────────────────────────────────────────
class _CashCard extends StatelessWidget {
  final String market;
  final double value;
  const _CashCard({required this.market, required this.value});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF21262D)),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('잉여현금', style: TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
          Text(market == 'KR' ? Fmt.krw(value) : Fmt.usd(value),
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
        ]),
      );
}

// ── 전략 추가 시트 ────────────────────────────────────────────────
class _AddStrategySheet extends StatefulWidget {
  final String market;
  final List<Map<String, dynamic>> noStratHoldings;
  final double totalCash;
  final String? preselectedTicker;
  final VoidCallback onSaved;

  const _AddStrategySheet({
    required this.market,
    required this.noStratHoldings,
    required this.totalCash,
    this.preselectedTicker,
    required this.onSaved,
  });

  @override
  State<_AddStrategySheet> createState() => _AddStrategySheetState();
}

class _AddStrategySheetState extends State<_AddStrategySheet> {
  int _step = 0;

  // Step 0
  final _idCtrl = TextEditingController();
  String _type = 'kr_value';
  final _capitalCtrl = TextEditingController();
  bool _usePct = false;

  // Step 1
  final _searchCtrl = TextEditingController();
  Set<String> _selected = {};
  final Map<String, String> _names = {};

  // Step 2
  final Map<String, TextEditingController> _wCtrl = {};
  Map<String, Map<String, dynamic>> _quotes = {};
  bool _validating = false;
  bool _saving = false;
  String? _errMsg;

  @override
  void initState() {
    super.initState();
    for (final h in widget.noStratHoldings) {
      final t = h['ticker'] as String? ?? '';
      _names[t] = h['name'] as String? ?? t;
    }
    if (widget.preselectedTicker != null) {
      _selected.add(widget.preselectedTicker!);
    }
  }

  @override
  void dispose() {
    _idCtrl.dispose();
    _capitalCtrl.dispose();
    _searchCtrl.dispose();
    for (final c in _wCtrl.values) c.dispose();
    super.dispose();
  }

  double get _capital {
    final v = double.tryParse(_capitalCtrl.text) ?? 0;
    return _usePct ? widget.totalCash * v / 100 : v;
  }

  bool get _validated =>
      _quotes.isNotEmpty && _quotes.length == _selected.length;

  bool _canProceed() {
    switch (_step) {
      case 0: return _idCtrl.text.trim().isNotEmpty && _capital > 0;
      case 1: return _selected.isNotEmpty;
      case 2: return _validated && !_saving;
      default: return false;
    }
  }

  void _next() => setState(() { _step++; _errMsg = null; });

  void _equalWeight() {
    if (_selected.isEmpty) return;
    final w = (100.0 / _selected.length).toStringAsFixed(1);
    for (final t in _selected) {
      _wCtrl.putIfAbsent(t, () => TextEditingController());
      _wCtrl[t]!.text = w;
    }
    setState(() {});
  }

  Future<void> _validate() async {
    setState(() { _validating = true; _errMsg = null; _quotes = {}; });
    for (final ticker in _selected) {
      try {
        final q = await ApiService.getQuote(ticker, widget.market);
        if (q.containsKey('name')) _names[ticker] = q['name'] as String;
        _quotes[ticker] = q;
      } catch (_) {
        _quotes[ticker] = {'error': true};
      }
    }
    if (mounted) setState(() { _validating = false; });
  }

  Future<void> _save() async {
    setState(() { _saving = true; _errMsg = null; });
    try {
      final stratId = _idCtrl.text.trim();
      final s = Strategy(
        strategyId: stratId,
        type: _type,
        symbol: _type == 'kr_value' ? '' : (_selected.isNotEmpty ? _selected.first : ''),
        market: widget.market,
        capital: _capital,
        createdAt: DateTime.now(),
      );
      await AppDatabase.insertStrategy(s);
      for (final ticker in _selected) {
        final w = double.tryParse(_wCtrl[ticker]?.text ?? '0') ?? 0;
        final name = _quotes[ticker]?['name'] as String? ?? _names[ticker] ?? ticker;
        await AppDatabase.savePortfolioStock(stratId, ticker, name, w);
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
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            width: 36, height: 4,
            decoration: BoxDecoration(
                color: const Color(0xFF30363D),
                borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(children: [
              if (_step > 0)
                GestureDetector(
                  onTap: () => setState(() { _step--; _errMsg = null; }),
                  child: const Icon(Icons.arrow_back_ios, size: 16, color: Color(0xFF8B949E)),
                )
              else
                const SizedBox(width: 16),
              const Spacer(),
              Text('전략 추가 (${_step + 1}/3)',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              const Spacer(),
              const SizedBox(width: 16),
            ]),
          ),
          const Divider(color: Color(0xFF30363D), height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: _stepContent(),
            ),
          ),
          if (_errMsg != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(_errMsg!,
                  style: const TextStyle(color: Color(0xFFF85149), fontSize: 11),
                  textAlign: TextAlign.center),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: _footer(),
          ),
        ]),
      ),
    );
  }

  Widget _stepContent() {
    switch (_step) {
      case 0: return _step0();
      case 1: return _step1();
      default: return _step2();
    }
  }

  Widget _footer() {
    return Row(children: [
      Expanded(
        child: OutlinedButton(
          onPressed: () => Navigator.pop(context),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Color(0xFF30363D)),
            foregroundColor: const Color(0xFF8B949E),
          ),
          child: const Text('취소'),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: ElevatedButton(
          onPressed: _canProceed() ? (_step < 2 ? _next : _save) : null,
          child: _saving
              ? const SizedBox(height: 16, width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text(_step < 2 ? '다음 →' : '저장'),
        ),
      ),
    ]);
  }

  // ── Step 0: 기본 정보 ──────────────────────────────────────────
  Widget _step0() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _SLabel('전략 이름'),
      _SInput(controller: _idCtrl, hint: '예: QT-KR-01',
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 14),
      _SLabel('유형'),
      DropdownButtonFormField<String>(
        value: _type,
        dropdownColor: const Color(0xFF161B22),
        style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 13),
        decoration: const InputDecoration(
          filled: true, fillColor: Color(0xFF0D1117),
          border: OutlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF30363D))),
          enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF30363D))),
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        items: const [
          DropdownMenuItem(value: 'kr_value', child: Text('QT KR (퀀트 한국)')),
          DropdownMenuItem(value: 'v4', child: Text('MM V4')),
          DropdownMenuItem(value: 'v1', child: Text('MM V1')),
          DropdownMenuItem(value: 'vr', child: Text('VR')),
        ],
        onChanged: (v) => setState(() { _type = v!; }),
      ),
      const SizedBox(height: 14),
      _SLabel('시장'),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF0D1117),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: Row(children: [
          const Icon(Icons.lock_outline, size: 12, color: Color(0xFF8B949E)),
          const SizedBox(width: 6),
          Text(widget.market, style: const TextStyle(fontSize: 13)),
          const Text('  (고정)',
              style: TextStyle(color: Color(0xFF6E7681), fontSize: 11)),
        ]),
      ),
      const SizedBox(height: 14),
      _SLabel('할당 금액'),
      Row(children: [
        Expanded(child: _SInput(
          controller: _capitalCtrl,
          hint: _usePct ? '% 입력' : (widget.market == 'KR' ? '원 단위' : 'USD 단위'),
          keyboardType: TextInputType.number,
          onChanged: (_) => setState(() {}),
        )),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => setState(() { _usePct = !_usePct; }),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: _usePct ? const Color(0xFF1F6FEB) : const Color(0xFF21262D),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(_usePct ? '%' : (widget.market == 'KR' ? '원' : '\$'),
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
      if (_usePct && widget.totalCash > 0)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '총 평가금액: ${widget.market == "KR" ? Fmt.krw(widget.totalCash) : Fmt.usd(widget.totalCash)}',
            style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11),
          ),
        ),
    ]);
  }

  // ── Step 1: 종목 선택 ──────────────────────────────────────────
  Widget _step1() {
    final holdings = widget.noStratHoldings;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _SLabel('보유 종목 (전략없음)'),
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
          final priceStr = widget.market == 'KR' ? Fmt.krw(price) : Fmt.usd(price);
          return CheckboxListTile(
            value: _selected.contains(ticker),
            onChanged: (v) => setState(() {
              v == true ? _selected.add(ticker) : _selected.remove(ticker);
            }),
            title: Row(children: [
              Text(ticker,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
              const SizedBox(width: 6),
              Expanded(child: Text(name,
                  style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11),
                  overflow: TextOverflow.ellipsis)),
            ]),
            subtitle: Text(priceStr,
                style: const TextStyle(color: Color(0xFF6E7681), fontSize: 10)),
            activeColor: const Color(0xFF1F6FEB),
            dense: true,
            contentPadding: EdgeInsets.zero,
          );
        }),
      const Divider(color: Color(0xFF30363D), height: 20),
      _SLabel('직접 입력'),
      Row(children: [
        Expanded(child: _SInput(
          controller: _searchCtrl,
          hint: '티커 직접 입력 (예: 005930)',
          onChanged: (_) => setState(() {}),
        )),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: _searchCtrl.text.trim().isEmpty ? null : () {
            final t = _searchCtrl.text.trim().toUpperCase();
            _names[t] = t;
            setState(() { _selected.add(t); _searchCtrl.clear(); });
          },
          style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
          child: const Text('추가'),
        ),
      ]),
      if (_selected.isNotEmpty) ...[
        const SizedBox(height: 12),
        _SLabel('선택 (${_selected.length}개)'),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6, runSpacing: 4,
          children: _selected.map((t) => InputChip(
            label: Text(t, style: const TextStyle(fontSize: 11)),
            onDeleted: () => setState(() { _selected.remove(t); }),
            deleteIconColor: const Color(0xFF8B949E),
            backgroundColor: const Color(0xFF21262D),
            side: const BorderSide(color: Color(0xFF30363D)),
            padding: EdgeInsets.zero,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          )).toList(),
        ),
      ],
    ]);
  }

  // ── Step 2: 비중 & 확인 ────────────────────────────────────────
  Widget _step2() {
    for (final t in _selected) {
      _wCtrl.putIfAbsent(t, () => TextEditingController(text: '0'));
    }

    final totalW = _selected.fold(0.0,
        (s, t) => s + (double.tryParse(_wCtrl[t]?.text ?? '0') ?? 0));

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _SLabel('종목별 비중 (%)'),
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
      ..._selected.map((ticker) {
        _wCtrl.putIfAbsent(ticker, () => TextEditingController(text: '0'));
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(ticker,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
              Text(_names[ticker] ?? ticker,
                  style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10),
                  overflow: TextOverflow.ellipsis),
            ])),
            SizedBox(
              width: 72,
              child: _SInput(
                controller: _wCtrl[ticker]!,
                hint: '0.0',
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Text('%', style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
            ),
          ]),
        );
      }),
      Align(
        alignment: Alignment.centerRight,
        child: Text(
          '합계: ${totalW.toStringAsFixed(1)}%',
          style: TextStyle(
            color: (totalW - 100).abs() < 0.5
                ? const Color(0xFF2EA043)
                : const Color(0xFF8B949E),
            fontSize: 11,
          ),
        ),
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          icon: _validating
              ? const SizedBox(width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.price_check, size: 16),
          label: Text(_validating ? '조회중...' : '시세 확인'),
          onPressed: _validating ? null : _validate,
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF58A6FF),
            side: const BorderSide(color: Color(0xFF30363D)),
          ),
        ),
      ),
      if (_validated) ...[
        const SizedBox(height: 14),
        const Divider(color: Color(0xFF30363D)),
        const SizedBox(height: 8),
        _SLabel('매수 가능 주수 (현재가 기준)'),
        const SizedBox(height: 6),
        ..._selected.map((ticker) {
          final q = _quotes[ticker];
          if (q == null) return const SizedBox.shrink();
          if (q['error'] == true) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                const Icon(Icons.error_outline,
                    color: Color(0xFFF85149), size: 14),
                const SizedBox(width: 4),
                Text(ticker,
                    style: const TextStyle(fontSize: 12)),
                const SizedBox(width: 4),
                const Text('조회 실패',
                    style: TextStyle(color: Color(0xFFF85149), fontSize: 11)),
              ]),
            );
          }
          final price =
              (q['price'] as num? ?? q['current_price'] as num? ?? 0).toDouble();
          final w = double.tryParse(_wCtrl[ticker]?.text ?? '0') ?? 0;
          final allocated = _capital * w / 100;
          final shares = price > 0 ? (allocated / price).floor() : 0;
          final name = q['name'] as String? ?? _names[ticker] ?? ticker;
          final allocStr =
              widget.market == 'KR' ? Fmt.krw(allocated) : Fmt.usd(allocated);
          final priceStr =
              widget.market == 'KR' ? Fmt.krw(price) : Fmt.usd(price);

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
                Text(ticker,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 12)),
                const SizedBox(width: 6),
                Expanded(child: Text(name,
                    style: const TextStyle(
                        color: Color(0xFF8B949E), fontSize: 10),
                    overflow: TextOverflow.ellipsis)),
                Text('$shares주',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        color: Color(0xFF58A6FF))),
              ]),
              const SizedBox(height: 2),
              Text('할당: $allocStr  ·  현재가: $priceStr',
                  style: const TextStyle(
                      color: Color(0xFF6E7681), fontSize: 10)),
            ]),
          );
        }),
        const SizedBox(height: 12),
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
              widget.market == 'KR'
                  ? MarketClock.nextKrOpen()
                  : MarketClock.nextUsOpen(),
              style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12),
            ),
          ]),
        ),
      ],
    ]);
  }
}

// ── 공통 위젯 ─────────────────────────────────────────────────────
class _SLabel extends StatelessWidget {
  final String text;
  const _SLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: const TextStyle(
            color: Color(0xFF8B949E), fontSize: 11, fontWeight: FontWeight.w600)),
      );
}

class _SInput extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final TextInputType? keyboardType;
  final void Function(String)? onChanged;
  const _SInput({
    required this.controller, required this.hint,
    this.keyboardType, this.onChanged,
  });

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        keyboardType: keyboardType,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: Color(0xFF6E7681), fontSize: 12),
          filled: true,
          fillColor: const Color(0xFF0D1117),
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
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      );
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;
  const _Chip(this.label, {
    this.color = const Color(0x221F6FEB),
    this.textColor = const Color(0xFF58A6FF),
  });
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration:
            BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
        child: Text(label, style: TextStyle(fontSize: 9, color: textColor)),
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
          Text(msg,
              style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12),
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: onRetry, child: const Text('다시 시도')),
        ]),
      );
}
