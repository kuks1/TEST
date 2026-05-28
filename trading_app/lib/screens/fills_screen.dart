import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../core/api_service.dart';
import '../core/app_theme.dart';
import '../core/common.dart';
import '../core/database.dart';

class FillsScreen extends StatefulWidget {
  const FillsScreen({super.key});
  @override
  State<FillsScreen> createState() => _FillsScreenState();
}

class _FillsScreenState extends State<FillsScreen> {
  bool _loading = false;
  String? _error;
  String _market = 'KR';
  String _viewMode = 'pending'; // 'filled' | 'pending'
  List<_Fill> _orders = [];
  Map<String, _StratRef> _tickerToStrategy = {};
  Map<String, double> _holdingAvg = {};

  final _filledHScroll = ScrollController();
  final _pendingHScroll = ScrollController();

  late DateTime _startDate;
  late DateTime _endDate;

  @override
  void dispose() {
    _filledHScroll.dispose();
    _pendingHScroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _endDate = DateTime.now();
    _startDate = _endDate.subtract(const Duration(days: 7));
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      // 전략 ticker 맵핑 (createdAt 포함 — 전략 생성 전 체결내역 필터링용)
      final strategies = await AppDatabase.getStrategies();
      final map = <String, _StratRef>{};
      for (final s in strategies) {
        final ref = _StratRef(s.strategyId, s.createdAt);
        if (s.symbol.isNotEmpty) map[s.symbol.toUpperCase()] = ref;
        if (s.type == 'kr_value') {
          final stocks = await AppDatabase.getPortfolioStocks(s.strategyId);
          for (final st in stocks) {
            final t = (st['ticker'] as String? ?? '').toUpperCase();
            if (t.isNotEmpty) map[t] = ref;
          }
        }
      }

      // 계좌 보유 평균단가
      final accountData = await ApiService.getAccount();
      final avgMap = <String, double>{};
      for (final key in ['kr', 'us']) {
        for (final acc in (accountData[key] as List? ?? [])) {
          for (final h in (acc['holdings'] as List? ?? [])) {
            final t = (h['ticker'] as String? ?? '').toUpperCase();
            final p = (h['avg_price'] as num? ?? 0).toDouble();
            if (t.isNotEmpty && p > 0) avgMap[t] = p;
          }
        }
      }

      setState(() {
        _tickerToStrategy = map;
        _holdingAvg = avgMap;
      });
      await _loadOrders();
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _loadOrders() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final sd = _fmt(_startDate);
      final ed = _fmt(_endDate);
      final result = await ApiService.getOrders(_market, startDate: sd, endDate: ed);
      if (!mounted) return;
      final orders = (result['orders'] as List? ?? [])
          .map((o) => _Fill.fromMap(o as Map<String, dynamic>))
          .toList();
      setState(() { _orders = orders; });
      // Cache ticker→name from orders API (KIS has names here but not in balance API)
      final names = <String, String>{};
      for (final o in orders) {
        if (o.ticker.isNotEmpty && o.name.isNotEmpty && o.name != o.ticker) {
          names[o.ticker.toUpperCase()] = o.name;
        }
      }
      if (names.isNotEmpty) AppDatabase.cacheTickerNames(names);
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); });
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate(bool isStart) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart ? _startDate : _endDate,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      builder: (ctx, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: ColorScheme.dark(
            primary: AppTheme.accent,
            onPrimary: Colors.white,
            surface: const Color(0xFF161B22),
            onSurface: const Color(0xFFE6EDF3),
          ),
          dialogBackgroundColor: const Color(0xFF161B22),
        ),
        child: child!,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isStart) {
        _startDate = picked;
        if (_startDate.isAfter(_endDate)) _endDate = _startDate;
      } else {
        _endDate = picked;
        if (_endDate.isBefore(_startDate)) _startDate = _endDate;
      }
    });
    await _loadOrders();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        title: const Text('주문내역'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _load),
        ],
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: const Color(0xFF161B22),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            _MarketChip(
              label: '국내 KR',
              selected: _market == 'KR',
              onTap: () { setState(() { _market = 'KR'; }); _loadOrders(); },
            ),
            const SizedBox(width: 8),
            _MarketChip(
              label: '해외 US',
              selected: _market == 'US',
              onTap: () { setState(() { _market = 'US'; }); _loadOrders(); },
            ),
            const Spacer(),
            _ViewToggle(
              value: _viewMode,
              onChanged: (v) => setState(() { _viewMode = v; }),
            ),
          ]),
        ),
        if (_viewMode == 'filled') _buildDateFilter(),
        const Divider(color: Color(0xFF21262D), height: 1),
        Expanded(child: _buildTable()),
      ]),
    );
  }

  Widget _buildDateFilter() {
    String fmtDisplay(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    return Container(
      color: const Color(0xFF0D1117),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        const Icon(Icons.date_range, size: 14, color: Color(0xFF8B949E)),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: () => _pickDate(true),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF21262D),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(fmtDisplay(_startDate),
                style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 12)),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6),
          child: Text('~', style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
        ),
        GestureDetector(
          onTap: () => _pickDate(false),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF21262D),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(fmtDisplay(_endDate),
                style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 12)),
          ),
        ),
        const Spacer(),
        GestureDetector(
          onTap: _loadOrders,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.accent.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text('조회', style: TextStyle(color: AppTheme.accent, fontSize: 12)),
          ),
        ),
      ]),
    );
  }

  Widget _buildTable() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_error!, style: const TextStyle(color: Color(0xFFF85149))),
        const SizedBox(height: 12),
        ElevatedButton(onPressed: _load, child: const Text('다시 시도')),
      ]));
    }
    return _viewMode == 'filled' ? _buildFilledTable() : _buildPendingTable();
  }

  Widget _buildFilledTable() {
    final filled = _orders.where((o) => o.status == '체결').toList();
    if (filled.isEmpty) {
      return const Center(
          child: Text('체결 내역 없음', style: TextStyle(color: Color(0xFF8B949E))));
    }

    const colWidths = [130.0, 130.0, 100.0, 70.0, 120.0, 110.0, 110.0];
    const totalWidth = 770.0;
    const headerStyle = TextStyle(
        color: Color(0xFF8B949E), fontSize: 11, fontWeight: FontWeight.w600);

    Widget hCell(String text, double w) => SizedBox(
      width: w,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Text(text, style: headerStyle),
      ),
    );

    final headerRow = Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF30363D))),
        color: Color(0xFF161B22),
      ),
      child: Row(children: [
        hCell('체결일시', colWidths[0]),
        hCell('종목명', colWidths[1]),
        hCell('체결가격 / ±%', colWidths[2]),
        hCell('수량', colWidths[3]),
        hCell('매입단가', colWidths[4]),
        hCell('매입단×수량', colWidths[5]),
        hCell('전략', colWidths[6]),
      ]),
    );

    return Scrollbar(
      controller: _filledHScroll,
      thumbVisibility: true,
      scrollbarOrientation: ScrollbarOrientation.bottom,
      child: SingleChildScrollView(
        controller: _filledHScroll,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: totalWidth,
          child: ListView.builder(
            itemCount: filled.length + 1,
            itemBuilder: (_, i) {
              if (i == 0) return headerRow;
              final o = filled[i - 1];
              return _FillRow(
                order: o,
                stratRef: _tickerToStrategy[o.ticker.toUpperCase()],
                holdingAvg: _holdingAvg[o.ticker.toUpperCase()],
                colWidths: colWidths,
                market: _market,
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildPendingTable() {
    final pending = _orders.where((o) => o.status == '미체결' || o.status == '부분체결').toList();
    if (pending.isEmpty) {
      return const Center(
          child: Text('미체결 주문 없음', style: TextStyle(color: Color(0xFF8B949E))));
    }

    const colWidths = [120.0, 140.0, 110.0, 75.0, 80.0, 100.0, 110.0];
    const totalWidth = 735.0;
    const headerStyle = TextStyle(
        color: Color(0xFF8B949E), fontSize: 11, fontWeight: FontWeight.w600);

    Widget hCell(String text, double w) => SizedBox(
      width: w,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Text(text, style: headerStyle),
      ),
    );

    final headerRow = Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF30363D))),
        color: Color(0xFF161B22),
      ),
      child: Row(children: [
        hCell('주문일시', colWidths[0]),
        hCell('종목명', colWidths[1]),
        hCell('주문가격', colWidths[2]),
        hCell('수량', colWidths[3]),
        hCell('상태', colWidths[4]),
        hCell('전략', colWidths[5]),
        hCell('', colWidths[6]),
      ]),
    );

    return Scrollbar(
      controller: _pendingHScroll,
      thumbVisibility: true,
      scrollbarOrientation: ScrollbarOrientation.bottom,
      child: SingleChildScrollView(
        controller: _pendingHScroll,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: totalWidth,
          child: ListView.builder(
            itemCount: pending.length + 1,
            itemBuilder: (_, i) {
              if (i == 0) return headerRow;
              final o = pending[i - 1];
              return _PendingRow(
                key: ValueKey(o.orderId),
                order: o,
                stratRef: _tickerToStrategy[o.ticker.toUpperCase()],
                colWidths: colWidths,
                market: _market,
                onRefresh: _loadOrders,
              );
            },
          ),
        ),
      ),
    );
  }
}

// ── Pending order row ─────────────────────────────────────────────

class _PendingRow extends StatefulWidget {
  final _Fill order;
  final _StratRef? stratRef;
  final List<double> colWidths;
  final String market;
  final VoidCallback onRefresh;

  const _PendingRow({
    super.key,
    required this.order,
    required this.stratRef,
    required this.colWidths,
    required this.market,
    required this.onRefresh,
  });

  @override
  State<_PendingRow> createState() => _PendingRowState();
}

class _PendingRowState extends State<_PendingRow> {
  bool _busy = false;

  Future<void> _cancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('주문 취소'),
        content: Text('${widget.order.name} ${widget.order.side} ${widget.order.quantity}주 주문을 취소할까요?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('아니오')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFF85149)),
            child: const Text('취소 확인'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() { _busy = true; });
    try {
      await ApiService.cancelOrder(widget.order.orderId, widget.market);
      widget.onRefresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('취소 실패: $e'), backgroundColor: const Color(0xFFF85149)),
        );
      }
    } finally {
      if (mounted) setState(() { _busy = false; });
    }
  }

  Widget _buildActionButtons() {
    // KR: inquire-psbl-rvsecncl이 이미 정정/취소 가능 주문만 반환 → 항상 허용
    // US: 당일(NY 날짜 기준) 주문만 허용 — 과거 날짜 주문은 API 에러 발생
    final canAct = widget.market == 'KR' ||
        MarketClock.isUsOrderFromToday(widget.order.orderedAt);
    if (!canAct) {
      return const Center(
        child: Tooltip(
          message: '당일 주문만 정정·취소 가능',
          child: Icon(Icons.lock_outline, size: 14, color: Color(0xFF484F58)),
        ),
      );
    }
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      _ActionBtn(label: '정정', color: const Color(0xFF58A6FF), onTap: _modify),
      const SizedBox(width: 6),
      _ActionBtn(label: '취소', color: const Color(0xFFF85149), onTap: _cancel),
    ]);
  }

  Future<void> _modify() async {
    final result = await showModalBottomSheet<_ModifyResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _ModifySheet(order: widget.order, market: widget.market),
    );
    if (result == null || !mounted) return;
    setState(() { _busy = true; });
    try {
      await ApiService.modifyOrder(widget.order.orderId, widget.market, result.price, result.qty);
      widget.onRefresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('정정 실패: $e'), backgroundColor: const Color(0xFFF85149)),
        );
      }
    } finally {
      if (mounted) setState(() { _busy = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    final priceStr = o.fillPrice > 0
        ? (widget.market == 'KR' ? Fmt.krw(o.fillPrice) : Fmt.usd(o.fillPrice))
        : '-';

    final isPending = o.status == '미체결';
    final statusColor = isPending ? const Color(0xFFE3B341) : const Color(0xFF1F6FEB);

    final orderDt = DateTime.tryParse(o.orderedAt.replaceFirst(' ', 'T')) ?? DateTime(2000);
    final showStrat = widget.stratRef != null &&
        (widget.stratRef!.createdAt == null || !orderDt.isBefore(widget.stratRef!.createdAt!));

    const cellStyle = TextStyle(color: Color(0xFFE6EDF3), fontSize: 12);
    const subStyle = TextStyle(color: Color(0xFF8B949E), fontSize: 11);
    final sideColor = o.side == 'BUY' ? const Color(0xFF2EA043) : const Color(0xFFF85149);
    final cw = widget.colWidths;

    Widget cell(Widget child, double w) => SizedBox(
          width: w,
          child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: child),
        );

    return Container(
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFF21262D)))),
      child: Row(children: [
        cell(
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
                children: [
                  Text(o.orderedAt.length >= 10 ? o.orderedAt.substring(0, 10) : o.orderedAt,
                      style: cellStyle),
                  Text(
                      o.orderedAt.length > 10
                          ? o.orderedAt.substring(11, math.min(19, o.orderedAt.length))
                          : '',
                      style: subStyle),
                ]),
            cw[0]),
        cell(
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                          color: sideColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(3)),
                      child: Text(o.side,
                          style: TextStyle(
                              color: sideColor, fontSize: 10, fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 4),
                    Flexible(child: Text(o.name, style: cellStyle, overflow: TextOverflow.ellipsis)),
                  ]),
                  Text(o.ticker, style: subStyle),
                ]),
            cw[1]),
        cell(Text(priceStr, style: cellStyle), cw[2]),
        cell(Text('${o.quantity}주', style: cellStyle), cw[3]),
        cell(
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: statusColor.withValues(alpha: 0.4))),
              child: Text(o.status,
                  style: TextStyle(color: statusColor, fontSize: 10, fontWeight: FontWeight.w600)),
            ),
            cw[4]),
        cell(
            showStrat
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                        color: AppTheme.accent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.4))),
                    child: Text(widget.stratRef!.id,
                        style: TextStyle(color: AppTheme.accent, fontSize: 10)))
                : Text('-', style: subStyle),
            cw[5]),
        // 정정 / 취소 버튼 — US는 장 운영 중일 때만 활성화
        SizedBox(
          width: cw[6],
          child: _busy
              ? const Center(child: SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)))
              : _buildActionButtons(),
        ),
      ]),
    );
  }
}

// ── 정정 결과 모델 ────────────────────────────────────────────────

class _ModifyResult {
  final double price;
  final int qty;
  const _ModifyResult(this.price, this.qty);
}

// ── 정정 바텀시트 ─────────────────────────────────────────────────

class _ModifySheet extends StatefulWidget {
  final _Fill order;
  final String market;
  const _ModifySheet({required this.order, required this.market});

  @override
  State<_ModifySheet> createState() => _ModifySheetState();
}

class _ModifySheetState extends State<_ModifySheet> {
  late final TextEditingController _priceCtrl;
  late final TextEditingController _qtyCtrl;

  @override
  void initState() {
    super.initState();
    final isKr = widget.market == 'KR';
    _priceCtrl = TextEditingController(
      text: isKr ? widget.order.fillPrice.toInt().toString()
                 : widget.order.fillPrice.toStringAsFixed(2),
    );
    _qtyCtrl = TextEditingController(text: widget.order.quantity.toString());
  }

  @override
  void dispose() {
    _priceCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isKr = widget.market == 'KR';
    final o = widget.order;

    return Padding(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
          children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('주문 정정', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text('${o.name} (${o.ticker}) · ${o.side} · ${o.quantity}주',
                  style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
            ]),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20, color: Color(0xFF8B949E)),
            onPressed: () => Navigator.pop(context),
          ),
        ]),
        const SizedBox(height: 4),
        Text('현재 지정가: ${isKr ? Fmt.krw(o.fillPrice) : Fmt.usd(o.fillPrice)}',
            style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('새 가격', style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
            const SizedBox(height: 6),
            TextField(
              controller: _priceCtrl,
              keyboardType: TextInputType.numberWithOptions(decimal: !isKr),
              decoration: _sheetInputDeco(isKr ? '원' : 'USD'),
            ),
          ])),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('수량', style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
            const SizedBox(height: 6),
            TextField(
              controller: _qtyCtrl,
              keyboardType: TextInputType.number,
              decoration: _sheetInputDeco('주'),
            ),
          ])),
        ]),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1F6FEB),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: () {
              final price = isKr
                  ? double.tryParse(_priceCtrl.text.replaceAll(',', ''))
                  : double.tryParse(_priceCtrl.text);
              final qty = int.tryParse(_qtyCtrl.text);
              if (price == null || price <= 0 || qty == null || qty <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('가격과 수량을 올바르게 입력하세요')),
                );
                return;
              }
              Navigator.pop(context, _ModifyResult(price, qty));
            },
            child: const Text('정정 주문', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
    );
  }
}

InputDecoration _sheetInputDeco(String suffix) => InputDecoration(
  isDense: true,
  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  filled: true,
  fillColor: const Color(0xFF0D1117),
  border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: const BorderSide(color: Color(0xFF30363D))),
  enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: const BorderSide(color: Color(0xFF30363D))),
  focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: BorderSide(color: AppTheme.accent)),
  suffixText: suffix,
  suffixStyle: const TextStyle(color: Color(0xFF8B949E), fontSize: 12),
);

// ── 액션 버튼 ─────────────────────────────────────────────────────

class _ActionBtn extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionBtn({required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: color.withValues(alpha: 0.6)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(label,
              style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
        ),
      );
}

// ── Strategy reference (id + createdAt for fill-date filtering) ──

class _StratRef {
  final String id;
  final DateTime? createdAt;
  const _StratRef(this.id, this.createdAt);
}

// ── View toggle (체결 / 미체결) ───────────────────────────────────

class _ViewToggle extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _ViewToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget btn(String mode, String label) {
      final sel = value == mode;
      return GestureDetector(
        onTap: () => onChanged(mode),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: sel ? AppTheme.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(label,
              style: TextStyle(
                color: sel ? Colors.white : const Color(0xFF8B949E),
                fontSize: 12,
                fontWeight: sel ? FontWeight.w600 : FontWeight.normal,
              )),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF21262D),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        btn('filled', '체결'),
        btn('pending', '미체결'),
      ]),
    );
  }
}

// ── Market chip ───────────────────────────────────────────────────

class _MarketChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _MarketChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? AppTheme.accent : const Color(0xFF21262D),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? AppTheme.accent : const Color(0xFF30363D),
            ),
          ),
          child: Text(label,
              style: TextStyle(
                color: selected ? Colors.white : const Color(0xFF8B949E),
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              )),
        ),
      );
}

// ── Fill model ────────────────────────────────────────────────────

class _Fill {
  final String orderId, orderedAt, ticker, name, status, side;
  // fillPrice: 체결가격 (order_price from API — actual execution price)
  // avgPrice:  체결평균가 of this order (not the account's cost basis)
  final double fillPrice, avgPrice;
  final int quantity;

  const _Fill({
    required this.orderId,
    required this.orderedAt,
    required this.ticker,
    required this.name,
    required this.fillPrice,
    required this.quantity,
    required this.avgPrice,
    required this.status,
    required this.side,
  });

  factory _Fill.fromMap(Map<String, dynamic> m) => _Fill(
        orderId: m['order_id']?.toString() ?? '',
        orderedAt: m['ordered_at']?.toString() ?? '',
        ticker: m['ticker']?.toString() ?? '',
        name: m['name']?.toString() ?? m['ticker']?.toString() ?? '',
        fillPrice: (m['order_price'] as num? ?? 0).toDouble(),
        quantity: (m['quantity'] as num? ?? 0).toInt(),
        avgPrice: (m['avg_price'] as num? ?? 0).toDouble(),
        status: m['status']?.toString() ?? '',
        side: m['side']?.toString() ?? '',
      );
}

// ── Fill row ──────────────────────────────────────────────────────

class _FillRow extends StatelessWidget {
  final _Fill order;
  final _StratRef? stratRef;
  final double? holdingAvg;
  final List<double> colWidths;
  final String market;

  const _FillRow({
    required this.order,
    required this.stratRef,
    required this.holdingAvg,
    required this.colWidths,
    required this.market,
  });

  @override
  Widget build(BuildContext context) {
    final o = order;

    // 체결가격: fillPrice가 0(시장가 주문)이면 avgPrice로 대체
    final displayPrice = o.fillPrice > 0 ? o.fillPrice : o.avgPrice;
    final priceStr = market == 'KR' ? Fmt.krw(displayPrice) : Fmt.usd(displayPrice);

    // 매입단가: 계좌 보유 평균단가 우선, 없으면 주문 체결평균가 사용
    final baseAvg = (holdingAvg != null && holdingAvg! > 0)
        ? holdingAvg!
        : (o.avgPrice > 0 ? o.avgPrice : null);

    // ±%: 체결가격 ÷ 매입단가
    final pnl = (displayPrice > 0 && baseAvg != null && baseAvg > 0)
        ? ((displayPrice - baseAvg) / baseAvg) * 100
        : 0.0;
    final pnlColor = pnl >= 0 ? const Color(0xFF2EA043) : const Color(0xFFF85149);
    final pnlStr = (displayPrice > 0 && baseAvg != null)
        ? '${pnl >= 0 ? '+' : ''}${pnl.toStringAsFixed(2)}%'
        : '-';

    final avgStr = baseAvg != null
        ? (market == 'KR' ? Fmt.krw(baseAvg) : Fmt.usd(baseAvg))
        : '-';

    // 매입단 × 수량
    final totalVal = baseAvg != null ? baseAvg * o.quantity : 0.0;
    final totalStr = totalVal > 0
        ? (market == 'KR'
            ? (totalVal >= 10000
                ? '${(totalVal / 10000).toStringAsFixed(1)}만'
                : totalVal.toStringAsFixed(0))
            : Fmt.usd(totalVal))
        : '-';

    // 전략 표시: 체결일시가 전략 생성일 이후인 경우에만
    final orderDt = DateTime.tryParse(o.orderedAt.replaceFirst(' ', 'T')) ?? DateTime(2000);
    final showStrat = stratRef != null &&
        (stratRef!.createdAt == null || !orderDt.isBefore(stratRef!.createdAt!));

    const cellStyle = TextStyle(color: Color(0xFFE6EDF3), fontSize: 12);
    const subStyle = TextStyle(color: Color(0xFF8B949E), fontSize: 11);
    final sideColor = o.side == 'BUY' ? const Color(0xFF2EA043) : const Color(0xFFF85149);

    Widget cell(Widget child, double w) => SizedBox(
          width: w,
          child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: child),
        );

    return Container(
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFF21262D)))),
      child: Row(children: [
        cell(
            Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                      o.orderedAt.length >= 10 ? o.orderedAt.substring(0, 10) : o.orderedAt,
                      style: cellStyle),
                  Text(
                      o.orderedAt.length > 10
                          ? o.orderedAt.substring(11, math.min(19, o.orderedAt.length))
                          : '',
                      style: subStyle),
                ]),
            colWidths[0]),
        cell(
            Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                          color: sideColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(3)),
                      child: Text(o.side,
                          style: TextStyle(
                              color: sideColor, fontSize: 10, fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                        child: Text(o.name, style: cellStyle, overflow: TextOverflow.ellipsis)),
                  ]),
                  Text(o.ticker, style: subStyle),
                ]),
            colWidths[1]),
        // 체결가격 + ±% (체결가격 ÷ 매입단가)
        cell(
            Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(priceStr, style: cellStyle),
                  if (pnlStr != '-')
                    Text(pnlStr, style: TextStyle(color: pnlColor, fontSize: 11)),
                ]),
            colWidths[2]),
        cell(Text('${o.quantity}주', style: cellStyle), colWidths[3]),
        cell(Text(avgStr, style: baseAvg != null ? cellStyle : subStyle), colWidths[4]),
        cell(Text(totalStr, style: cellStyle), colWidths[5]),
        cell(
            showStrat
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                        color: AppTheme.accent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                            color: AppTheme.accent.withValues(alpha: 0.4))),
                    child: Text(stratRef!.id,
                        style: TextStyle(color: AppTheme.accent, fontSize: 10)))
                : Text('-', style: subStyle),
            colWidths[6]),
      ]),
    );
  }
}
