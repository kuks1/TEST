import 'package:flutter/material.dart';
import '../core/app_theme.dart';
import '../core/database.dart';
import '../core/common.dart';
import '../models/strategy.dart';
import 'fills_screen.dart';

class TradeLogScreen extends StatefulWidget {
  const TradeLogScreen({super.key});
  @override
  State<TradeLogScreen> createState() => _TradeLogScreenState();
}

class _TradeLogScreenState extends State<TradeLogScreen> {
  List<Strategy> _strategies = [];
  Strategy? _selected;

  @override
  void initState() {
    super.initState();
    _loadStrategies();
  }

  Future<void> _loadStrategies() async {
    final list = await AppDatabase.getStrategies();
    if (!mounted) return;
    setState(() {
      _strategies = list;
      if (_selected == null && list.isNotEmpty) {
        _selected = list.first;
      } else if (_selected != null && list.isNotEmpty) {
        _selected = list.firstWhere(
          (s) => s.id == _selected!.id,
          orElse: () => list.first,
        );
      }
    });
  }

  void _openTrash() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => const _TrashSheet(),
    );
  }

  Future<void> _reorderTabs(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex--;
    setState(() {
      final s = _strategies.removeAt(oldIndex);
      _strategies.insert(newIndex, s);
    });
    await AppDatabase.updateStrategySortOrders(
        _strategies.map((s) => s.strategyId).toList());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        title: const Text('기록'),
        actions: [
          IconButton(
            icon: const Icon(Icons.receipt_long_outlined, size: 20),
            tooltip: '체결내역',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FillsScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: '휴지통',
            onPressed: _openTrash,
          ),
        ],
      ),
      body: Column(children: [
        if (_strategies.isNotEmpty)
          SizedBox(
            height: 42,
            child: ReorderableListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              buildDefaultDragHandles: false,
              proxyDecorator: (child, _, __) =>
                  Material(color: Colors.transparent, child: child),
              onReorder: _reorderTabs,
              children: [
                for (int i = 0; i < _strategies.length; i++)
                  ReorderableDragStartListener(
                    key: ValueKey(_strategies[i].id),
                    index: i,
                    child: GestureDetector(
                      onTap: () => setState(() { _selected = _strategies[i]; }),
                      child: Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: BoxDecoration(
                          color: _selected?.id == _strategies[i].id
                              ? AppTheme.accent
                              : const Color(0xFF21262D),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        alignment: Alignment.center,
                        child: Text(_strategies[i].strategyId,
                            style: TextStyle(
                              fontSize: 12,
                              color: _selected?.id == _strategies[i].id
                                  ? Colors.white
                                  : const Color(0xFF8B949E),
                            )),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        const Divider(color: Color(0xFF21262D), height: 1),
        Expanded(child: _buildBody()),
      ]),
    );
  }

  Widget _buildBody() {
    if (_selected == null) {
      return const Center(
          child: Text('전략을 선택하세요', style: TextStyle(color: Color(0xFF8B949E))));
    }
    switch (_selected!.type) {
      case 'v4':
      case 'v1':
        return _MmCycleLogView(key: ValueKey(_selected!.id), strategy: _selected!);
      case 'vr':
        return _VrCycleLogView(key: ValueKey(_selected!.id), strategy: _selected!);
      case 'kr_value':
        return _QtCycleLogView(key: ValueKey(_selected!.id), strategy: _selected!);
      default:
        return const Center(
            child: Text('지원하지 않는 전략 유형입니다',
                style: TextStyle(color: Color(0xFF8B949E))));
    }
  }
}

// ══════════════════════════════════════════════════════════════════
// MM 전략 사이클 뷰 (V4 / V1)
// ══════════════════════════════════════════════════════════════════

class _MmCycleLogView extends StatefulWidget {
  final Strategy strategy;
  const _MmCycleLogView({super.key, required this.strategy});
  @override
  State<_MmCycleLogView> createState() => _MmCycleLogViewState();
}

class _MmCycleLogViewState extends State<_MmCycleLogView> {
  List<_CycleRange> _cycles = [];
  List<Map<String, dynamic>> _allItems = [];
  int _cycleIdx = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    final s = widget.strategy;
    if (s.id == null) {
      if (mounted) setState(() { _loading = false; });
      return;
    }
    final allItems = await AppDatabase.getOrderLogs(s.id!);
    final cycles = _buildPositionCycles(allItems, s.createdAt);
    if (mounted) setState(() {
      _allItems = allItems;
      _cycles = cycles;
      _cycleIdx = cycles.isEmpty ? 0 : cycles.length - 1;
      _loading = false;
    });
  }

  List<_CycleRange> _buildPositionCycles(
      List<Map<String, dynamic>> allItems, DateTime strategyStart) {
    if (allItems.isEmpty) return [];
    final sorted = [...allItems]
      ..sort((a, b) {
        final dc = (a['date'] as String).compareTo(b['date'] as String);
        if (dc != 0) return dc;
        return (a['side'] as String? ?? '').compareTo(b['side'] as String? ?? '');
      });

    final cycles = <_CycleRange>[];
    int position = 0;
    DateTime? cycleStart;
    int cycleNo = 1;

    for (final item in sorted) {
      final date = DateTime.parse(item['date'] as String);
      final side = (item['side'] as String? ?? '').toUpperCase();
      final qty = (item['planned_qty'] as num? ?? 0).toInt();
      if (cycleStart == null && side == 'BUY') cycleStart = date;
      if (side == 'BUY') {
        position += qty;
      } else if (side == 'SELL') {
        position = (position - qty).clamp(0, 999999);
        if (position == 0 && cycleStart != null) {
          cycles.add(_CycleRange(no: cycleNo++, start: cycleStart,
              end: date.add(const Duration(days: 1))));
          cycleStart = null;
        }
      }
    }
    if (cycleStart != null) {
      cycles.add(_CycleRange(no: cycleNo, start: cycleStart,
          end: DateTime.now().add(const Duration(days: 365))));
    } else if (cycles.isEmpty) {
      cycles.add(_CycleRange(no: 1, start: strategyStart,
          end: DateTime.now().add(const Duration(days: 365))));
    }
    return cycles;
  }

  bool get _isCurrentCycle => _cycles.isEmpty || _cycleIdx == _cycles.length - 1;

  List<Map<String, dynamic>> get _cycleItems {
    if (_cycles.isEmpty) return [];
    final c = _cycles[_cycleIdx];
    return _allItems.where((it) {
      final d = DateTime.parse(it['date'] as String);
      return !d.isBefore(c.start) && d.isBefore(c.end);
    }).toList();
  }

  Map<String, List<Map<String, dynamic>>> get _groupedByDate {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final it in _cycleItems) {
      final date = it['date'] as String;
      (map[date] ??= []).add(it);
    }
    final sortedKeys = map.keys.toList()..sort((a, b) => b.compareTo(a));
    return {for (final k in sortedKeys) k: map[k]!};
  }

  String _cycleLabel(_CycleRange c) {
    final start = '${c.start.month}/${c.start.day}';
    if (_isCurrentCycle) return '$start ~ 진행중';
    final end = c.end.subtract(const Duration(days: 1));
    return '$start ~ ${end.month}/${end.day}';
  }

  void _showDayDetail(String date, List<Map<String, dynamic>> items) {
    showDialog(
      context: context,
      builder: (_) => _MmDayDetailDialog(
        date: date,
        items: items,
        isKr: widget.strategy.market == 'KR',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_cycles.isEmpty) {
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.history, color: Color(0xFF8B949E), size: 40),
        SizedBox(height: 10),
        Text('주문 기록이 없습니다', style: TextStyle(color: Color(0xFF8B949E), fontSize: 13)),
      ]));
    }

    final cycle = _cycles[_cycleIdx];
    final grouped = _groupedByDate;

    return Column(children: [
      Container(
        color: const Color(0xFF161B22),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 22),
            onPressed: _cycleIdx > 0 ? () => setState(() { _cycleIdx--; }) : null,
            color: _cycleIdx > 0 ? const Color(0xFF8B949E) : const Color(0xFF30363D),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('C${cycle.no}',
                style: TextStyle(
                    color: AppTheme.accent, fontSize: 13, fontWeight: FontWeight.w700)),
            Text(_cycleLabel(cycle),
                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
          ]))),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 22),
            onPressed: _isCurrentCycle ? null : () => setState(() { _cycleIdx++; }),
            color: _isCurrentCycle ? const Color(0xFF30363D) : const Color(0xFF8B949E),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
        ]),
      ),
      const Divider(color: Color(0xFF21262D), height: 1),
      Expanded(
        child: grouped.isEmpty
            ? const Center(child: Text('이 사이클에 기록이 없습니다',
                style: TextStyle(color: Color(0xFF8B949E))))
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 16),
                itemCount: grouped.length,
                itemBuilder: (_, i) {
                  final date = grouped.keys.elementAt(i);
                  final items = grouped[date]!;
                  return _MmDateGroup(
                    date: date,
                    items: items,
                    isKr: widget.strategy.market == 'KR',
                    onTap: () => _showDayDetail(date, items),
                  );
                },
              ),
      ),
    ]);
  }
}

class _MmDateGroup extends StatelessWidget {
  final String date;
  final List<Map<String, dynamic>> items;
  final bool isKr;
  final VoidCallback onTap;
  const _MmDateGroup({
    required this.date,
    required this.items,
    required this.isKr,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: AppTheme.accent.withValues(alpha: 0.4)),
            ),
          ),
          child: Row(children: [
            Text(date,
                style: TextStyle(
                    color: AppTheme.accent, fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Text('${items.length}건',
                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
            const Spacer(),
            Icon(Icons.open_in_new, size: 13,
                color: AppTheme.accent.withValues(alpha: 0.6)),
          ]),
        ),
      ),
      ...items.take(4).map((it) => GestureDetector(
        onTap: onTap,
        child: _OrderLogRow(item: it, isKr: isKr),
      )),
      const SizedBox(height: 4),
    ]);
  }
}

class _MmDayDetailDialog extends StatelessWidget {
  final String date;
  final List<Map<String, dynamic>> items;
  final bool isKr;
  const _MmDayDetailDialog(
      {required this.date, required this.items, required this.isKr});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF161B22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 60),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
          child: Row(children: [
            Text(date,
                style: TextStyle(
                    color: AppTheme.accent, fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Text('${items.length}개 계획',
                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
            const Spacer(),
            IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close, size: 18, color: Color(0xFF8B949E)),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ]),
        ),
        const Divider(color: Color(0xFF30363D), height: 1),
        Container(
          color: const Color(0xFF161B22),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: const Row(children: [
            SizedBox(width: 36,
                child: Text('구분',
                    style: TextStyle(color: Color(0xFF6E7681), fontSize: 10,
                        fontWeight: FontWeight.w600))),
            SizedBox(width: 6),
            Expanded(child: Text('단계',
                style: TextStyle(color: Color(0xFF6E7681), fontSize: 10,
                    fontWeight: FontWeight.w600))),
            SizedBox(width: 44,
                child: Text('수량',
                    style: TextStyle(color: Color(0xFF6E7681), fontSize: 10,
                        fontWeight: FontWeight.w600),
                    textAlign: TextAlign.right)),
            SizedBox(width: 6),
            SizedBox(width: 80,
                child: Text('가격',
                    style: TextStyle(color: Color(0xFF6E7681), fontSize: 10,
                        fontWeight: FontWeight.w600),
                    textAlign: TextAlign.right)),
            SizedBox(width: 6),
            SizedBox(width: 62,
                child: Text('날짜',
                    style: TextStyle(color: Color(0xFF6E7681), fontSize: 10,
                        fontWeight: FontWeight.w600),
                    textAlign: TextAlign.center)),
          ]),
        ),
        const Divider(color: Color(0xFF21262D), height: 1),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: ListView(
            shrinkWrap: true,
            children: items.map((it) => _OrderLogRow(item: it, isKr: isKr)).toList(),
          ),
        ),
        const SizedBox(height: 8),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// VR 전략 사이클 뷰
// ══════════════════════════════════════════════════════════════════

class _VrCycleLogView extends StatefulWidget {
  final Strategy strategy;
  const _VrCycleLogView({super.key, required this.strategy});
  @override
  State<_VrCycleLogView> createState() => _VrCycleLogViewState();
}

class _VrCycleLogViewState extends State<_VrCycleLogView> {
  List<Map<String, dynamic>> _records = [];
  List<Map<String, dynamic>> _orderItems = [];
  int _cycleIdx = 0;
  bool _loading = true;

  int get _totalCycles => _records.length + 1;
  bool get _isCurrentCycle => _cycleIdx == _totalCycles - 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final records = await AppDatabase.getVrCycleRecords(widget.strategy.strategyId);
    List<Map<String, dynamic>> orderItems = [];
    if (widget.strategy.id != null) {
      orderItems = await AppDatabase.getOrderLogs(widget.strategy.id!);
    }
    if (mounted) setState(() {
      _records = records;
      _orderItems = orderItems;
      _cycleIdx = records.length;
      _loading = false;
    });
  }

  DateTime _cycleStart(int idx) {
    if (idx == 0) return widget.strategy.createdAt;
    return DateTime.parse(_records[idx - 1]['recorded_at'] as String);
  }

  DateTime? _cycleEnd(int idx) {
    if (idx < _records.length) {
      return DateTime.parse(_records[idx]['recorded_at'] as String);
    }
    return null;
  }

  Map<String, dynamic>? get _v1Record =>
      _cycleIdx == 0 ? null : _records[_cycleIdx - 1];

  Map<String, dynamic>? get _v2Record =>
      _cycleIdx < _records.length ? _records[_cycleIdx] : null;

  double get _cyclePoolStart {
    if (_cycleIdx == 0) {
      return widget.strategy.calcCapital ?? widget.strategy.capital;
    }
    return (_records[_cycleIdx - 1]['pool'] as num).toDouble();
  }

  double get _cycleTradingAmount {
    return _cycleOrdersFor('BUY')
        .where((it) => (it['status'] as String? ?? '') == 'Success')
        .fold(0.0, (sum, it) =>
            sum + (it['planned_qty'] as num? ?? 0).toDouble() *
                  (it['planned_price'] as num? ?? 0).toDouble());
  }

  double get _v1PoolStart {
    if (_cycleIdx <= 1) return widget.strategy.calcCapital ?? widget.strategy.capital;
    return (_records[_cycleIdx - 2]['pool'] as num).toDouble();
  }

  double get _v1TradingAmount {
    if (_cycleIdx == 0) return 0;
    final v1Idx = _cycleIdx - 1;
    final start = _cycleStart(v1Idx);
    final end = _cycleEnd(v1Idx);
    return _orderItems
        .where((it) {
          final d = DateTime.parse(it['date'] as String);
          return !d.isBefore(start) &&
              (end == null || d.isBefore(end)) &&
              (it['side'] as String? ?? '') == 'BUY' &&
              (it['status'] as String? ?? '') == 'Success';
        })
        .fold(0.0, (sum, it) =>
            sum + (it['planned_qty'] as num? ?? 0).toDouble() *
                  (it['planned_price'] as num? ?? 0).toDouble());
  }

  List<Map<String, dynamic>> _cycleOrdersFor(String side) {
    final start = _cycleStart(_cycleIdx);
    final end = _cycleEnd(_cycleIdx);
    return _orderItems.where((it) {
      final d = DateTime.parse(it['date'] as String);
      final inRange = !d.isBefore(start) && (end == null || d.isBefore(end));
      return inRange && (it['side'] as String? ?? '') == side;
    }).toList()
      ..sort((a, b) => (a['date'] as String).compareTo(b['date'] as String));
  }

  String _cycleLabel() {
    final start = _cycleStart(_cycleIdx);
    final end = _cycleEnd(_cycleIdx);
    final s = '${start.month}/${start.day}';
    if (end == null) return '$s ~ 진행중';
    return '$s ~ ${end.month}/${end.day}';
  }

  Future<void> _confirmDeleteRecord(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('기록 삭제'),
        content: const Text('이 사이클 기록을 삭제할까요?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFF85149)),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await AppDatabase.deleteVrCycleRecord(id);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final isKr = widget.strategy.market == 'KR';
    final v1 = _v1Record;
    final v2 = _v2Record;
    final buyItems = _cycleOrdersFor('BUY');
    final sellItems = _cycleOrdersFor('SELL');
    final band = widget.strategy.vrEffectiveBand;

    return Column(children: [
      Container(
        color: const Color(0xFF161B22),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 22),
            onPressed: _cycleIdx > 0 ? () => setState(() { _cycleIdx--; }) : null,
            color: _cycleIdx > 0 ? const Color(0xFF8B949E) : const Color(0xFF30363D),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('C${_cycleIdx + 1}',
                style: TextStyle(
                    color: AppTheme.accent, fontSize: 13, fontWeight: FontWeight.w700)),
            Text(_cycleLabel(),
                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
          ]))),
          const SizedBox(width: 36),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 22),
            onPressed: _isCurrentCycle ? null : () => setState(() { _cycleIdx++; }),
            color: _isCurrentCycle ? const Color(0xFF30363D) : const Color(0xFF8B949E),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
        ]),
      ),
      const Divider(color: Color(0xFF21262D), height: 1),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: _VTable(
          isKr: isKr,
          band: band,
          v1Record: v1,
          v2Record: v2,
          v1PoolStart: _v1PoolStart,
          v1TradingAmount: _v1TradingAmount,
          v2PoolStart: _cyclePoolStart,
          v2TradingAmount: _cycleTradingAmount,
          isCurrentCycle: _isCurrentCycle,
          onDeleteV1: v1 != null ? () => _confirmDeleteRecord(v1['id'] as int) : null,
          onDeleteV2: v2 != null ? () => _confirmDeleteRecord(v2['id'] as int) : null,
        ),
      ),
      const Divider(color: Color(0xFF21262D), height: 1),
      Expanded(
        child: (buyItems.isEmpty && sellItems.isEmpty)
            ? const Center(child: Text('이 사이클에 주문 기록이 없습니다',
                style: TextStyle(color: Color(0xFF8B949E))))
            : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _VrOrderColumn(
                  title: '매수',
                  titleColor: const Color(0xFF2EA043),
                  items: buyItems,
                  isKr: isKr,
                )),
                Container(width: 1, color: const Color(0xFF21262D)),
                Expanded(child: _VrOrderColumn(
                  title: '매도',
                  titleColor: const Color(0xFFF85149),
                  items: sellItems,
                  isKr: isKr,
                )),
              ]),
      ),
    ]);
  }
}

class _VTable extends StatelessWidget {
  final bool isKr;
  final double band;
  final Map<String, dynamic>? v1Record;
  final Map<String, dynamic>? v2Record;
  final double v1PoolStart;
  final double v1TradingAmount;
  final double v2PoolStart;
  final double v2TradingAmount;
  final bool isCurrentCycle;
  final VoidCallback? onDeleteV1;
  final VoidCallback? onDeleteV2;

  const _VTable({
    required this.isKr,
    required this.band,
    required this.v1Record,
    required this.v2Record,
    required this.v1PoolStart,
    required this.v1TradingAmount,
    required this.v2PoolStart,
    required this.v2TradingAmount,
    required this.isCurrentCycle,
    this.onDeleteV1,
    this.onDeleteV2,
  });

  String _c(double v) {
    if (isKr) {
      if (v.abs() >= 100000000) return '${(v / 100000000).toStringAsFixed(1)}억';
      if (v.abs() >= 10000) return '${(v / 10000).toStringAsFixed(0)}만';
      return v.toStringAsFixed(0);
    }
    if (v.abs() >= 1000000) return '\$${(v / 1000000).toStringAsFixed(2)}M';
    if (v.abs() >= 1000) return '\$${(v / 1000).toStringAsFixed(1)}K';
    return '\$${v.toStringAsFixed(2)}';
  }

  Widget _hdr(String t) => Expanded(
        child: Text(t,
            style: const TextStyle(color: Color(0xFF6E7681), fontSize: 9),
            overflow: TextOverflow.ellipsis),
      );

  Widget _cell(String t, {Color? color, FontWeight? weight}) => Expanded(
        child: Text(t,
            style: TextStyle(
                color: color ?? const Color(0xFFE6EDF3),
                fontSize: 10,
                fontWeight: weight ?? FontWeight.normal),
            overflow: TextOverflow.ellipsis),
      );

  Widget _dataRow({
    required String label,
    required Color labelColor,
    required Map<String, dynamic>? record,
    required double poolStart,
    required double tradingAmount,
    required bool isOngoing,
    required VoidCallback? onDelete,
  }) {
    final v = record != null ? (record['v_value'] as num).toDouble() : null;
    final vMax = v != null ? v * (1 + band) : null;
    final vMin = v != null ? v * (1 - band) : null;
    final remaining = record != null && !isOngoing
        ? (record['pool'] as num).toDouble()
        : isOngoing
            ? poolStart - tradingAmount
            : null;
    final remainColor = (remaining ?? 0) >= 0
        ? const Color(0xFF2EA043)
        : const Color(0xFFF85149);

    return GestureDetector(
      onLongPress: onDelete,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(children: [
          SizedBox(
            width: 28,
            child: Text(label,
                style: TextStyle(
                    color: labelColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
          ),
          _cell(
            v != null ? _c(v) : '-',
            color: v != null ? const Color(0xFF58A6FF) : const Color(0xFF484F58),
            weight: FontWeight.w600,
          ),
          _cell(vMax != null ? _c(vMax) : '-',
              color: vMax != null ? const Color(0xFF8B949E) : const Color(0xFF484F58)),
          _cell(vMin != null ? _c(vMin) : '-',
              color: vMin != null ? const Color(0xFF8B949E) : const Color(0xFF484F58)),
          _cell(_c(poolStart), color: const Color(0xFFE6EDF3)),
          _cell(
            tradingAmount > 0 ? _c(tradingAmount) : '-',
            color: tradingAmount > 0 ? const Color(0xFFE6EDF3) : const Color(0xFF484F58),
          ),
          _cell(
            remaining != null ? _c(remaining) : '-',
            color: remaining != null ? remainColor : const Color(0xFF484F58),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      child: Column(children: [
        Row(children: [
          const SizedBox(width: 28),
          _hdr('V'),
          _hdr('Vmax'),
          _hdr('Vmin'),
          _hdr('Pool'),
          _hdr('거래액'),
          _hdr('잔여'),
        ]),
        const Divider(color: Color(0xFF30363D), height: 8),
        _dataRow(
          label: 'V₁',
          labelColor: const Color(0xFF8B949E),
          record: v1Record,
          poolStart: v1PoolStart,
          tradingAmount: v1TradingAmount,
          isOngoing: false,
          onDelete: onDeleteV1,
        ),
        const Divider(color: Color(0xFF21262D), height: 1),
        _dataRow(
          label: 'V₂',
          labelColor: AppTheme.accent,
          record: v2Record,
          poolStart: v2PoolStart,
          tradingAmount: v2TradingAmount,
          isOngoing: isCurrentCycle,
          onDelete: onDeleteV2,
        ),
      ]),
    );
  }
}

class _VrOrderColumn extends StatelessWidget {
  final String title;
  final Color titleColor;
  final List<Map<String, dynamic>> items;
  final bool isKr;
  const _VrOrderColumn({
    required this.title,
    required this.titleColor,
    required this.items,
    required this.isKr,
  });

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        color: const Color(0xFF161B22),
        width: double.infinity,
        child: Text(title,
            style: TextStyle(
                color: titleColor, fontSize: 11, fontWeight: FontWeight.w700)),
      ),
      const Divider(color: Color(0xFF21262D), height: 1),
      Expanded(
        child: items.isEmpty
            ? const Center(child: Text('없음',
                style: TextStyle(color: Color(0xFF484F58), fontSize: 11)))
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: items.length,
                itemBuilder: (_, i) => _VrGridItem(item: items[i], isKr: isKr),
              ),
      ),
    ]);
  }
}

class _VrGridItem extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool isKr;
  const _VrGridItem({required this.item, required this.isKr});

  @override
  Widget build(BuildContext context) {
    final date = (item['date'] as String? ?? '');
    final displayDate = date.length >= 10
        ? '${date.substring(2, 4)}.${date.substring(5, 7)}.${date.substring(8, 10)}'
        : date;
    final qty = (item['planned_qty'] as num? ?? 0).toInt();
    final price = (item['planned_price'] as num? ?? 0).toDouble();
    final status = item['status'] as String? ?? 'Scheduled';
    final day = item['day'] as String? ?? '';
    final label = item['label'] as String? ?? '';

    final statusColor = switch (status) {
      'Success' => const Color(0xFF2EA043),
      'Failed' => const Color(0xFFF85149),
      _ => AppTheme.accent,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFF21262D)))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(displayDate,
            style: TextStyle(
                color: statusColor, fontSize: 10, fontWeight: FontWeight.w600)),
        if (day.isNotEmpty || label.isNotEmpty)
          Text('$day $label'.trim(),
              style: const TextStyle(color: Color(0xFF6E7681), fontSize: 10),
              overflow: TextOverflow.ellipsis),
        Row(children: [
          Text('${qty}주',
              style: const TextStyle(
                  color: Color(0xFFE6EDF3), fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(width: 4),
          Expanded(
            child: Text(isKr ? Fmt.krw(price) : Fmt.usd(price),
                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10),
                overflow: TextOverflow.ellipsis),
          ),
        ]),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// QT 전략 세션 뷰
// ══════════════════════════════════════════════════════════════════

class _QtCycleLogView extends StatefulWidget {
  final Strategy strategy;
  const _QtCycleLogView({super.key, required this.strategy});
  @override
  State<_QtCycleLogView> createState() => _QtCycleLogViewState();
}

class _QtCycleLogViewState extends State<_QtCycleLogView> {
  List<Map<String, dynamic>> _sessions = [];
  Map<int, List<Map<String, dynamic>>> _items = {};
  int _sessionIdx = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sessions =
        await AppDatabase.getQtSessionsByStrategy(widget.strategy.strategyId);
    final asc = sessions.reversed.toList();
    final itemMap = <int, List<Map<String, dynamic>>>{};
    for (final s in asc) {
      final sid = s['id'] as int;
      itemMap[sid] = await AppDatabase.getQtOrderItems(sid);
    }
    if (mounted) setState(() {
      _sessions = asc;
      _items = itemMap;
      _sessionIdx = asc.isEmpty ? 0 : asc.length - 1;
      _loading = false;
    });
  }

  bool get _isLastSession =>
      _sessions.isEmpty || _sessionIdx == _sessions.length - 1;

  Map<String, dynamic>? get _currentSession =>
      _sessions.isEmpty ? null : _sessions[_sessionIdx];

  List<Map<String, dynamic>> get _currentItems {
    final s = _currentSession;
    if (s == null) return [];
    return _items[s['id'] as int] ?? [];
  }

  String _sessionDateLabel(Map<String, dynamic> s) {
    final c = (s['created_at'] as String? ?? '');
    final start = c.length >= 10 ? c.substring(0, 10) : c;
    final stoppedRaw = s['stopped_at'] as String?;
    if (stoppedRaw == null) return '$start ~ 진행중';
    final stop = stoppedRaw.length >= 10 ? stoppedRaw.substring(0, 10) : stoppedRaw;
    return '$start ~ $stop';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_sessions.isEmpty) {
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.history, color: Color(0xFF8B949E), size: 40),
        SizedBox(height: 10),
        Text('리밸런싱 기록이 없습니다',
            style: TextStyle(color: Color(0xFF8B949E), fontSize: 13)),
      ]));
    }

    final sess = _currentSession!;
    final isKr = widget.strategy.market == 'KR';
    final capital = (sess['total_capital'] as num? ?? 0).toDouble();
    final isActive = sess['stopped_at'] == null;
    final items = _currentItems;

    return Column(children: [
      Container(
        color: const Color(0xFF161B22),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 22),
            onPressed: _sessionIdx > 0 ? () => setState(() { _sessionIdx--; }) : null,
            color: _sessionIdx > 0 ? const Color(0xFF8B949E) : const Color(0xFF30363D),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('RV${_sessionIdx + 1}',
                style: TextStyle(
                    color: AppTheme.accent, fontSize: 13, fontWeight: FontWeight.w700)),
            Text(_sessionDateLabel(sess),
                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
          ]))),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 22),
            onPressed: _isLastSession ? null : () => setState(() { _sessionIdx++; }),
            color: _isLastSession ? const Color(0xFF30363D) : const Color(0xFF8B949E),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
        ]),
      ),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: const Color(0xFF0D1117),
        child: Row(children: [
          Text(isKr ? Fmt.krw(capital) : Fmt.usd(capital),
              style: const TextStyle(
                  color: Color(0xFFE6EDF3), fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: isActive
                  ? const Color(0xFF2EA043).withValues(alpha: 0.15)
                  : const Color(0xFF30363D),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(isActive ? 'Active' : 'Stopped',
                style: TextStyle(
                  color: isActive ? const Color(0xFF2EA043) : const Color(0xFF8B949E),
                  fontSize: 9,
                )),
          ),
          const Spacer(),
          Text('${items.length}종목',
              style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
        ]),
      ),
      const Divider(color: Color(0xFF21262D), height: 1),
      if (items.isEmpty)
        const Expanded(child: Center(child: Text('주문 항목이 없습니다',
            style: TextStyle(color: Color(0xFF8B949E)))))
      else ...[
        Container(
          color: const Color(0xFF161B22),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: const Row(children: [
            Expanded(child: Text('종목',
                style: TextStyle(
                    color: Color(0xFF6E7681), fontSize: 10, fontWeight: FontWeight.w600))),
            SizedBox(width: 50,
                child: Text('계획',
                    style: TextStyle(
                        color: Color(0xFF6E7681), fontSize: 10, fontWeight: FontWeight.w600),
                    textAlign: TextAlign.right)),
            SizedBox(width: 4),
            SizedBox(width: 50,
                child: Text('보유',
                    style: TextStyle(
                        color: Color(0xFF6E7681), fontSize: 10, fontWeight: FontWeight.w600),
                    textAlign: TextAlign.right)),
            SizedBox(width: 4),
            SizedBox(width: 60,
                child: Text('실행일',
                    style: TextStyle(
                        color: Color(0xFF6E7681), fontSize: 10, fontWeight: FontWeight.w600),
                    textAlign: TextAlign.center)),
          ]),
        ),
        const Divider(color: Color(0xFF21262D), height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 16),
            itemCount: items.length,
            itemBuilder: (_, i) => _QtLogRow(item: items[i], isKr: isKr),
          ),
        ),
      ],
    ]);
  }
}

class _QtLogRow extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool isKr;
  const _QtLogRow({required this.item, required this.isKr});

  @override
  Widget build(BuildContext context) {
    final ticker = item['ticker'] as String? ?? '';
    final name = item['name'] as String? ?? ticker;
    final side = item['side'] as String? ?? 'BUY';
    final status = item['status'] as String? ?? 'Scheduled';
    final plannedQty = (item['planned_qty'] as num? ?? 0).toInt();
    final actualQty = (item['actual_qty'] as num? ?? 0).toInt();
    final isBuy = side == 'BUY';
    final qtyColor = isBuy ? const Color(0xFF2EA043) : const Color(0xFFF85149);
    final sign = isBuy ? '+' : '-';

    final holdingColor = switch (status) {
      'Success' => const Color(0xFF2EA043),
      'Failed'  => const Color(0xFFF85149),
      _         => const Color(0xFF484F58),
    };
    final holdingText = (status == 'Success' || status == 'Failed')
        ? '${actualQty}주'
        : '-';

    final rawDate = item['created_at'] as String? ?? '';
    final displayDate = rawDate.length >= 10
        ? '${rawDate.substring(2, 4)}.${rawDate.substring(5, 7)}.${rawDate.substring(8, 10)}'
        : rawDate;
    final dateColor = switch (status) {
      'Success' => const Color(0xFF2EA043),
      'Failed'  => const Color(0xFFF85149),
      _         => AppTheme.accent,
    };

    return Container(
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFF21262D)))),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name,
              style: const TextStyle(
                  color: Color(0xFFE6EDF3), fontSize: 11, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis),
          Text(ticker,
              style: const TextStyle(color: Color(0xFF6E7681), fontSize: 10)),
        ])),
        SizedBox(
          width: 50,
          child: Text('$sign${plannedQty}주',
              style: TextStyle(
                  color: qtyColor, fontSize: 11, fontWeight: FontWeight.w700),
              textAlign: TextAlign.right),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 50,
          child: Text(holdingText,
              style: TextStyle(
                  color: holdingColor, fontSize: 11, fontWeight: FontWeight.w700),
              textAlign: TextAlign.right),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 60,
          child: Text(displayDate,
              style: TextStyle(
                  color: dateColor, fontSize: 10, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center),
        ),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// 공통 위젯
// ══════════════════════════════════════════════════════════════════

class _CycleRange {
  final int no;
  final DateTime start, end;
  const _CycleRange({required this.no, required this.start, required this.end});
}

class _OrderLogRow extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool isKr;
  const _OrderLogRow({required this.item, required this.isKr});

  @override
  Widget build(BuildContext context) {
    final side = item['side'] as String? ?? 'BUY';
    final day = item['day'] as String? ?? '';
    final label = item['label'] as String? ?? '';
    final qty = (item['planned_qty'] as num? ?? 0).toInt();
    final price = (item['planned_price'] as num? ?? 0).toDouble();
    final status = item['status'] as String? ?? 'Scheduled';

    final isBuy = side == 'BUY';
    final sideColor = isBuy ? const Color(0xFF2EA043) : const Color(0xFFF85149);
    final sideLabel = isBuy ? '매수' : '매도';

    final rawDate = item['date'] as String? ?? '';
    final dateDisplay = rawDate.length >= 10
        ? '${rawDate.substring(2, 4)}.${rawDate.substring(5, 7)}.${rawDate.substring(8, 10)}'
        : rawDate;

    final statusColor = switch (status) {
      'Success' => const Color(0xFF2EA043),
      'Failed' => const Color(0xFFF85149),
      _ => AppTheme.accent,
    };

    return Container(
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFF21262D)))),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        SizedBox(
          width: 36,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
                color: sideColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(3)),
            child: Text(sideLabel,
                style: TextStyle(
                    color: sideColor, fontSize: 9, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min, children: [
            if (day.isNotEmpty)
              Text(day,
                  style: TextStyle(
                      color: statusColor, fontSize: 11, fontWeight: FontWeight.w600)),
            if (label.isNotEmpty)
              Text(label,
                  style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10),
                  overflow: TextOverflow.ellipsis),
          ]),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 44,
          child: Text('${qty}주',
              style: const TextStyle(
                  color: Color(0xFFE6EDF3), fontSize: 11, fontWeight: FontWeight.w600),
              textAlign: TextAlign.right),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 80,
          child: Text(isKr ? Fmt.krw(price) : Fmt.usd(price),
              style: const TextStyle(color: Color(0xFF6E7681), fontSize: 10),
              textAlign: TextAlign.right),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 62,
          child: Text(dateDisplay,
              style: TextStyle(color: statusColor, fontSize: 9),
              textAlign: TextAlign.center),
        ),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// 휴지통
// ══════════════════════════════════════════════════════════════════

class _TrashSheet extends StatefulWidget {
  const _TrashSheet();
  @override
  State<_TrashSheet> createState() => _TrashSheetState();
}

class _TrashSheetState extends State<_TrashSheet> {
  List<Strategy> _deleted = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; });
    final list = await AppDatabase.getDeletedStrategies();
    if (mounted) setState(() { _deleted = list; _loading = false; });
  }

  Future<void> _permanentDelete(Strategy s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: Text('${s.strategyId} 영구 삭제'),
        content: const Text('이 전략을 완전히 삭제할까요? 복구가 불가능합니다.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFF85149)),
            child: const Text('영구 삭제'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await AppDatabase.deleteStrategy(s.id!);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (_, ctrl) => Column(children: [
        Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          width: 36, height: 4,
          decoration: BoxDecoration(
              color: const Color(0xFF30363D),
              borderRadius: BorderRadius.circular(2)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(children: [
            const Icon(Icons.delete_outline, size: 16, color: Color(0xFF8B949E)),
            const SizedBox(width: 6),
            const Text('휴지통',
                style: TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 14, color: Color(0xFFE6EDF3))),
            const Spacer(),
            if (_deleted.isNotEmpty)
              Text('${_deleted.length}개',
                  style: const TextStyle(color: Color(0xFF6E7681), fontSize: 11)),
          ]),
        ),
        const Divider(color: Color(0xFF30363D), height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _deleted.isEmpty
                  ? const Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.delete_outline, color: Color(0xFF8B949E), size: 40),
                        SizedBox(height: 10),
                        Text('삭제된 전략이 없습니다',
                            style: TextStyle(color: Color(0xFF8B949E))),
                      ]),
                    )
                  : ListView.builder(
                      controller: ctrl,
                      padding: const EdgeInsets.all(12),
                      itemCount: _deleted.length,
                      itemBuilder: (_, i) => _TrashCard(
                        strategy: _deleted[i],
                        onDelete: () => _permanentDelete(_deleted[i]),
                      ),
                    ),
        ),
      ]),
    );
  }
}

class _TrashCard extends StatefulWidget {
  final Strategy strategy;
  final VoidCallback onDelete;
  const _TrashCard({required this.strategy, required this.onDelete});
  @override
  State<_TrashCard> createState() => _TrashCardState();
}

class _TrashCardState extends State<_TrashCard> {
  final _ctrl = TextEditingController();
  double? _finalCap;
  bool _saving = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  double? get _returnPct {
    if (_finalCap == null) return null;
    final initial = widget.strategy.capital;
    if (initial <= 0) return null;
    return (_finalCap! - initial) / initial * 100;
  }

  Future<void> _saveRecord() async {
    if (_finalCap == null) return;
    setState(() { _saving = true; });
    final pnl = _returnPct ?? 0;
    final s = widget.strategy;
    await AppDatabase.insertLog({
      'strategy_id': s.strategyId,
      'date': DateTime.now().toIso8601String().substring(0, 10),
      'event': '전략 종료',
      'action': '전략종료',
      'quantity': 0.0,
      'price': _finalCap!,
      'pnl_pct': pnl,
      'created_at': DateTime.now().toIso8601String(),
    });
    if (mounted) {
      setState(() { _saving = false; });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('수익률이 기록되었습니다'),
            duration: Duration(seconds: 2)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.strategy;
    final pnl = _returnPct;
    final isKr = s.market == 'KR';
    final deletedAt = s.deletedAt != null
        ? (s.deletedAt!.length >= 16 ? s.deletedAt!.substring(0, 16) : s.deletedAt!)
        : '';
    final pnlColor = pnl != null
        ? (pnl >= 0 ? const Color(0xFF2EA043) : const Color(0xFFF85149))
        : const Color(0xFF8B949E);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1117),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (deletedAt.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('삭제: $deletedAt',
                style: const TextStyle(color: Color(0xFF6E7681), fontSize: 10)),
          ),
        Row(children: [
          Text(s.strategyId,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 13, color: Color(0xFFE6EDF3))),
          const SizedBox(width: 6),
          _Chip(s.typeLabel),
          const SizedBox(width: 4),
          _Chip(s.market,
              color: const Color(0x22388BFD), textColor: const Color(0xFF58A6FF)),
        ]),
        const SizedBox(height: 10),
        const Divider(color: Color(0xFF21262D), height: 1),
        const SizedBox(height: 8),
        Row(children: [
          const Text('초기 할당금액',
              style: TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
          const Spacer(),
          Text(isKr ? Fmt.krw(s.capital) : Fmt.usd(s.capital),
              style: const TextStyle(
                  color: Color(0xFFE6EDF3), fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          const Text('종료 금액',
              style: TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _ctrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 12),
              decoration: InputDecoration(
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                filled: true,
                fillColor: const Color(0xFF161B22),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: Color(0xFF30363D))),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: Color(0xFF30363D))),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: Color(0xFF58A6FF))),
                hintText: '입력',
                hintStyle: const TextStyle(color: Color(0xFF484F58), fontSize: 12),
                suffixText: isKr ? '원' : '\$',
                suffixStyle: const TextStyle(color: Color(0xFF8B949E), fontSize: 11),
              ),
              onChanged: (v) {
                setState(() {
                  _finalCap = double.tryParse(v.replaceAll(',', ''));
                });
              },
            ),
          ),
          if (pnl != null) ...[
            const SizedBox(width: 10),
            Text(
              '${pnl >= 0 ? '+' : ''}${pnl.toStringAsFixed(2)}%',
              style: TextStyle(
                  color: pnlColor, fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ],
        ]),
        const SizedBox(height: 10),
        Row(children: [
          if (_finalCap != null) ...[
            Expanded(
              child: GestureDetector(
                onTap: _saving ? null : _saveRecord,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1F6FEB).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: const Color(0xFF1F6FEB).withValues(alpha: 0.4)),
                  ),
                  child: Center(
                    child: _saving
                        ? const SizedBox(width: 12, height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('기록 저장',
                            style: TextStyle(
                                color: Color(0xFF58A6FF),
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: GestureDetector(
              onTap: widget.onDelete,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFF85149).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: const Color(0xFFF85149).withValues(alpha: 0.3)),
                ),
                child: const Center(
                  child: Text('영구 삭제',
                      style: TextStyle(
                          color: Color(0xFFF85149),
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ),
        ]),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color? color;
  final Color? textColor;
  const _Chip(this.label, {this.color, this.textColor});

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
