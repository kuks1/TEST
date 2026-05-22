import 'package:flutter/material.dart';
import '../core/app_theme.dart';
import '../core/database.dart';
import '../core/common.dart';
import '../models/strategy.dart';

class TradeLogScreen extends StatefulWidget {
  const TradeLogScreen({super.key});
  @override
  State<TradeLogScreen> createState() => _TradeLogScreenState();
}

class _TradeLogScreenState extends State<TradeLogScreen> {
  List<Strategy> _strategies = [];
  Strategy? _selected;
  List<Map<String, dynamic>> _logs = [];

  // QT 전략용
  List<Map<String, dynamic>> _qtSessions = [];
  Map<int, List<Map<String, dynamic>>> _qtItems = {};
  bool get _isQtMode => _selected?.type == 'kr_value';

  @override
  void initState() {
    super.initState();
    _loadStrategies();
  }

  Future<void> _loadStrategies() async {
    final list = await AppDatabase.getStrategies();
    setState(() {
      _strategies = list;
      if (list.isNotEmpty) _selected = list.first;
    });
    if (_selected != null) await _loadLogs(_selected!.strategyId);
  }

  Future<void> _loadLogs(String stratId) async {
    final strategy = _strategies.firstWhere(
      (s) => s.strategyId == stratId,
      orElse: () => _strategies.first,
    );
    if (strategy.type == 'kr_value') {
      final sessions = await AppDatabase.getQtSessionsByStrategy(stratId);
      final itemsBySession = <int, List<Map<String, dynamic>>>{};
      for (final sess in sessions) {
        final sid = sess['id'] as int;
        itemsBySession[sid] = await AppDatabase.getQtOrderItems(sid);
      }
      if (mounted) setState(() {
        _qtSessions = sessions;
        _qtItems = itemsBySession;
        _logs = [];
      });
    } else {
      final logs = await AppDatabase.getTradeLog(stratId);
      if (mounted) setState(() {
        _logs = logs;
        _qtSessions = [];
        _qtItems = {};
      });
    }
  }

  void _openAddSheet() {
    if (_selected == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _LogAddSheet(
        strategyId: _selected!.strategyId,
        market: _selected!.market,
        onSaved: () => _loadLogs(_selected!.strategyId),
      ),
    );
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

  Future<void> _confirmDelete(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('기록 삭제'),
        content: const Text('이 매매 기록을 삭제할까요?'),
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
      await AppDatabase.deleteLog(id);
      if (_selected != null) await _loadLogs(_selected!.strategyId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        title: const Text('기록'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: '휴지통',
            onPressed: _openTrash,
          ),
        ],
      ),
      body: Column(children: [
        if (_strategies.isNotEmpty) ...[
          Container(
            height: 42,
            color: const Color(0xFF161B22),
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: _strategies.map((s) {
                final sel = _selected?.id == s.id;
                return GestureDetector(
                  onTap: () {
                    setState(() { _selected = s; });
                    _loadLogs(s.strategyId);
                  },
                  child: Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: sel ? AppTheme.accent : const Color(0xFF21262D),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    alignment: Alignment.center,
                    child: Text(s.strategyId,
                        style: TextStyle(
                          fontSize: 12,
                          color: sel ? Colors.white : const Color(0xFF8B949E),
                        )),
                  ),
                );
              }).toList(),
            ),
          ),
          Row(children: [
            const Spacer(),
            if (_selected != null)
              Padding(
                padding: const EdgeInsets.only(right: 8, top: 4),
                child: GestureDetector(
                  onTap: _openAddSheet,
                  child: Row(children: [
                    Icon(Icons.add, size: 14, color: AppTheme.accent),
                    const SizedBox(width: 2),
                    Text('기록 추가',
                        style: TextStyle(color: AppTheme.accent, fontSize: 11)),
                  ]),
                ),
              ),
          ]),
        ],
        const Divider(color: Color(0xFF21262D), height: 1),
        Expanded(
          child: _isQtMode
              ? (_qtSessions.isEmpty
                  ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.receipt_long, color: Color(0xFF8B949E), size: 48),
                      SizedBox(height: 12),
                      Text('주문 기록이 없습니다', style: TextStyle(color: Color(0xFF8B949E))),
                    ]))
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _qtSessions.length,
                      itemBuilder: (_, i) {
                        final sess = _qtSessions[i];
                        final sid = sess['id'] as int;
                        final items = _qtItems[sid] ?? [];
                        return _QtSessionCard(
                          session: sess,
                          items: items,
                          market: _selected?.market ?? 'KR',
                        );
                      },
                    ))
              : (_logs.isEmpty
                  ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.receipt_long, color: Color(0xFF8B949E), size: 48),
                      SizedBox(height: 12),
                      Text('매매 기록이 없습니다', style: TextStyle(color: Color(0xFF8B949E))),
                    ]))
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _logs.length,
                      itemBuilder: (_, i) {
                        final log = _logs[i];
                        final pnl = (log['pnl_pct'] as num? ?? 0).toDouble();
                        final action = log['action'] as String? ?? '';
                        final event = log['event'] as String? ?? '';
                        final qty = (log['quantity'] as num? ?? 0).toDouble();
                        final price = (log['price'] as num? ?? 0).toDouble();

                        Color actionColor = const Color(0xFF8B949E);
                        if (action == '매수') actionColor = const Color(0xFF2EA043);
                        else if (action == '매도') actionColor = const Color(0xFFF85149);
                        else if (action == '리밸런싱') actionColor = AppTheme.accent;

                        final hasPnl = pnl != 0;
                        final pnlColor = pnl >= 0 ? const Color(0xFF2EA043) : const Color(0xFFF85149);
                        final isKr = _selected?.market == 'KR';

                        return GestureDetector(
                          onLongPress: () => _confirmDelete(log['id'] as int),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF161B22),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: const Color(0xFF30363D)),
                            ),
                            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(log['date'] as String? ?? '',
                                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                                if (event.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(event, style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
                                  ),
                                if (qty > 0 && price > 0)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      '${qty % 1 == 0 ? qty.toInt() : qty}주 · ${isKr ? Fmt.krw(price) : Fmt.usd(price)}',
                                      style: const TextStyle(color: Color(0xFF6E7681), fontSize: 11),
                                    ),
                                  ),
                              ])),
                              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                                if (action.isNotEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: actionColor.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(action, style: TextStyle(color: actionColor, fontSize: 11)),
                                  ),
                                if (hasPnl)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      '${pnl >= 0 ? '+' : ''}${pnl.toStringAsFixed(2)}%',
                                      style: TextStyle(color: pnlColor, fontWeight: FontWeight.w600, fontSize: 13),
                                    ),
                                  ),
                              ]),
                            ]),
                          ),
                        );
                      },
                    )),
        ),
      ]),
    );
  }
}

// ── QT 세션 카드 ────────────────────────────────────────────────────

class _QtSessionCard extends StatefulWidget {
  final Map<String, dynamic> session;
  final List<Map<String, dynamic>> items;
  final String market;
  const _QtSessionCard({
    required this.session,
    required this.items,
    required this.market,
  });
  @override
  State<_QtSessionCard> createState() => _QtSessionCardState();
}

class _QtSessionCardState extends State<_QtSessionCard> {
  bool _expanded = false;
  static const _preview = 2;

  String get _typeLabel {
    switch (widget.session['session_type'] as String? ?? '') {
      case 'create': return '전략 생성';
      case 'rebalance': return '재밸런싱';
      case 'modify': return '비중 조절';
      default: return widget.session['session_type'] as String? ?? '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final items = widget.items;
    final market = widget.market;

    final createdAt = session['created_at'] as String? ?? '';
    final dateStr = createdAt.length >= 16 ? createdAt.substring(0, 16) : createdAt;
    final capital = (session['total_capital'] as num? ?? 0).toDouble();
    final isActive = session['stopped_at'] == null;
    final isKr = market == 'KR';
    final pnlPct = session['pnl_pct'] != null
        ? (session['pnl_pct'] as num).toDouble()
        : null;

    final hasPeek = items.length > _preview;
    final visibleItems = _expanded ? items : items.take(_preview).toList();
    final peekItem = (!_expanded && hasPeek) ? items[_preview] : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.accent.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _typeLabel,
                style: TextStyle(
                    color: AppTheme.accent,
                    fontSize: 10,
                    fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(dateStr,
                  style: const TextStyle(
                      color: Color(0xFF8B949E), fontSize: 11)),
            ),
            Text(
              isKr ? Fmt.krw(capital) : Fmt.usd(capital),
              style: const TextStyle(
                  color: Color(0xFFE6EDF3),
                  fontSize: 11,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: isActive
                    ? const Color(0xFF2EA043).withValues(alpha: 0.15)
                    : const Color(0xFF30363D),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                isActive ? 'Active' : 'Stopped',
                style: TextStyle(
                  color: isActive
                      ? const Color(0xFF2EA043)
                      : const Color(0xFF8B949E),
                  fontSize: 9,
                ),
              ),
            ),
            if (pnlPct != null) ...[
              const SizedBox(width: 8),
              Text(
                '${pnlPct >= 0 ? '+' : ''}${pnlPct.toStringAsFixed(2)}%',
                style: TextStyle(
                  color: pnlPct >= 0
                      ? const Color(0xFF2EA043)
                      : const Color(0xFFF85149),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ]),
        ),
        if (items.isNotEmpty) ...[
          const Divider(color: Color(0xFF21262D), height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
            child: Row(children: const [
              SizedBox(
                  width: 130,
                  child: Text('수량  종목',
                      style: TextStyle(color: Color(0xFF6E7681), fontSize: 9))),
              Expanded(
                  child: Text('가격 / 상태',
                      style: TextStyle(color: Color(0xFF6E7681), fontSize: 9),
                      textAlign: TextAlign.right)),
            ]),
          ),
          ...visibleItems.map((item) => _QtItemRow(item: item, market: market)),
          if (peekItem != null)
            ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.white, Colors.transparent],
                stops: [0.15, 1.0],
              ).createShader(bounds),
              blendMode: BlendMode.dstIn,
              child: _QtItemRow(item: peekItem, market: market),
            ),
          if (hasPeek)
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 2, 0, 4),
                child: Center(
                  child: Icon(
                    _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 14,
                    color: const Color(0xFF484F58),
                  ),
                ),
              ),
            )
          else
            const SizedBox(height: 6),
        ],
      ]),
    );
  }
}

class _QtItemRow extends StatelessWidget {
  final Map<String, dynamic> item;
  final String market;
  const _QtItemRow({required this.item, required this.market});

  @override
  Widget build(BuildContext context) {
    final ticker = item['ticker'] as String? ?? '';
    final name = item['name'] as String? ?? ticker;
    final side = item['side'] as String? ?? 'BUY';
    final status = item['status'] as String? ?? 'Scheduled';
    final weight = (item['weight'] as num? ?? 0).toDouble();
    final isSuccess = status == 'Success';
    final isKr = market == 'KR';

    final qty = isSuccess
        ? (item['actual_qty'] as num? ?? 0).toDouble()
        : (item['planned_qty'] as num? ?? 0).toDouble();
    final price = isSuccess
        ? (item['actual_price'] as num? ?? 0).toDouble()
        : (item['planned_price'] as num? ?? 0).toDouble();

    final isBuy = side == 'BUY';
    final qtySign = isBuy ? '+' : '-';
    final qtyColor = isBuy ? const Color(0xFF2EA043) : const Color(0xFFF85149);

    final (statusColor, statusBg) = switch (status) {
      'Success' => (const Color(0xFF2EA043), const Color(0xFF2EA043)),
      'Failed' => (const Color(0xFFF85149), const Color(0xFFF85149)),
      'Stopped' => (const Color(0xFF8B949E), const Color(0xFF8B949E)),
      _ => (AppTheme.accent, AppTheme.accent),
    };

    return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          // ── 고정 왼쪽: ±qty(bold) + 회사명 + 티커 ──
          SizedBox(
            width: 130,
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Text(
                '$qtySign${qty.toInt()}주',
                style: TextStyle(
                    color: qtyColor, fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name,
                      style: const TextStyle(
                          color: Color(0xFFE6EDF3),
                          fontSize: 10,
                          fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis),
                  Text(
                    '${weight.toStringAsFixed(0)}% · $ticker',
                    style: const TextStyle(color: Color(0xFF6E7681), fontSize: 9),
                    overflow: TextOverflow.ellipsis,
                  ),
                ]),
              ),
            ]),
          ),
          // ── 오른쪽: 2열 표시 + 3열 그라데이션 ──
          Expanded(
            child: ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Colors.white, Colors.white, Colors.transparent],
                stops: [0.0, 0.55, 1.0],
              ).createShader(bounds),
              blendMode: BlendMode.dstIn,
              child: Row(children: [
                // 열 1: 가격 (완전 표시)
                Expanded(
                  child: Text(
                    isKr ? Fmt.krw(price) : Fmt.usd(price),
                    style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 10),
                    textAlign: TextAlign.right,
                  ),
                ),
                const SizedBox(width: 8),
                // 열 2: 상태 뱃지 (그라데이션으로 fade)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusBg.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(color: statusColor, fontSize: 9),
                  ),
                ),
                const SizedBox(width: 12),
              ]),
            ),
          ),
        ]),
    );
  }
}

// ── 휴지통 바텀시트 ────────────────────────────────────────────────

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
          width: 36,
          height: 4,
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
      'event': '전략 종료: ${_constants(s)}',
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

  String _constants(Strategy s) {
    final parts = <String>[];
    switch (s.type) {
      case 'v4':
        parts.add('분할 ${s.divisions ?? 20}');
        parts.add('별기준 ${s.starBase ?? 20}');
        if (s.starCoeff != null) parts.add('별계수 ${s.starCoeff}');
      case 'v1':
        parts.add('분할 ${s.divisions ?? 10}');
        if (s.v1Value != null) parts.add('익절 +${s.v1Value!.toStringAsFixed(1)}%');
      case 'vr':
        parts.add(s.vrMode ?? '적립식');
        if (s.vrBand != null)
          parts.add('밴드 ${(s.vrBand! * 100).toStringAsFixed(0)}%');
        if (s.vrDeposit != null) parts.add('입금 ${Fmt.krw(s.vrDeposit!)}');
        if (s.vrG != null) parts.add('G ${s.vrG}');
      case 'kr_value':
        parts.add('QT');
    }
    return parts.join(' · ');
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
        if (_constants(s).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(_constants(s),
                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
          ),
        const SizedBox(height: 10),
        const Divider(color: Color(0xFF21262D), height: 1),
        const SizedBox(height: 8),
        // 초기 할당금액
        Row(children: [
          const Text('초기 할당금액',
              style: TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
          const Spacer(),
          Text(isKr ? Fmt.krw(s.capital) : Fmt.usd(s.capital),
              style: const TextStyle(
                  color: Color(0xFFE6EDF3), fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 6),
        // 종료 금액 입력
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
                hintStyle:
                    const TextStyle(color: Color(0xFF484F58), fontSize: 12),
                suffixText: isKr ? '원' : '\$',
                suffixStyle:
                    const TextStyle(color: Color(0xFF8B949E), fontSize: 11),
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
                        ? const SizedBox(
                            width: 12,
                            height: 12,
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

// ── 기록 추가 시트 ─────────────────────────────────────────────────

class _LogAddSheet extends StatefulWidget {
  final String strategyId;
  final String market;
  final VoidCallback onSaved;
  const _LogAddSheet({
    required this.strategyId,
    required this.market,
    required this.onSaved,
  });
  @override
  State<_LogAddSheet> createState() => _LogAddSheetState();
}

class _LogAddSheetState extends State<_LogAddSheet> {
  final _dateCtrl = TextEditingController();
  final _eventCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _pnlCtrl = TextEditingController();
  String _action = '매수';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _dateCtrl.text = DateTime.now().toIso8601String().substring(0, 10);
  }

  @override
  void dispose() {
    _dateCtrl.dispose();
    _eventCtrl.dispose();
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    _pnlCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_dateCtrl.text) ?? DateTime.now(),
      firstDate: DateTime(2020),
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
    if (picked != null && mounted) {
      setState(() {
        _dateCtrl.text = picked.toIso8601String().substring(0, 10);
      });
    }
  }

  Future<void> _save() async {
    setState(() { _saving = true; });
    await AppDatabase.insertLog({
      'strategy_id': widget.strategyId,
      'date': _dateCtrl.text,
      'event': _eventCtrl.text.trim(),
      'action': _action,
      'quantity': double.tryParse(_qtyCtrl.text) ?? 0,
      'price': double.tryParse(_priceCtrl.text) ?? 0,
      'pnl_pct': double.tryParse(_pnlCtrl.text) ?? 0,
      'created_at': DateTime.now().toIso8601String(),
    });
    if (mounted) Navigator.pop(context);
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                  color: const Color(0xFF30363D),
                  borderRadius: BorderRadius.circular(2))),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text('매매 기록 추가',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          ),
          const Divider(color: Color(0xFF30363D), height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const _Lbl('날짜'),
                  Row(children: [
                    Expanded(
                        child: _Inp(
                            controller: _dateCtrl,
                            hint: 'YYYY-MM-DD',
                            readOnly: true)),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: _pickDate,
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF21262D),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(Icons.calendar_today,
                            size: 16, color: AppTheme.accent),
                      ),
                    ),
                  ]),
                ])),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const _Lbl('구분'),
                  DropdownButtonFormField<String>(
                    value: _action,
                    dropdownColor: const Color(0xFF161B22),
                    style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 13),
                    decoration: const InputDecoration(
                      filled: true,
                      fillColor: Color(0xFF0D1117),
                      border: OutlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFF30363D))),
                      enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFF30363D))),
                      focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFF58A6FF))),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    items: const [
                      DropdownMenuItem(value: '매수', child: Text('매수')),
                      DropdownMenuItem(value: '매도', child: Text('매도')),
                      DropdownMenuItem(value: '리밸런싱', child: Text('리밸런싱')),
                      DropdownMenuItem(value: '기타', child: Text('기타')),
                    ],
                    onChanged: (v) => setState(() { _action = v!; }),
                  ),
                ])),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const _Lbl('수량'),
                  _Inp(controller: _qtyCtrl, hint: '0', keyboardType: TextInputType.number),
                ])),
                const SizedBox(width: 8),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _Lbl(widget.market == 'KR' ? '가격 (원)' : '가격 (USD)'),
                  _Inp(controller: _priceCtrl, hint: '0', keyboardType: TextInputType.number),
                ])),
                const SizedBox(width: 8),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const _Lbl('수익률 (%)'),
                  _Inp(
                      controller: _pnlCtrl,
                      hint: '0.00',
                      keyboardType: const TextInputType.numberWithOptions(
                          signed: true, decimal: true)),
                ])),
              ]),
              const SizedBox(height: 12),
              const _Lbl('메모'),
              _Inp(controller: _eventCtrl, hint: '매매 내용 메모'),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
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
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('저장'),
              )),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Lbl extends StatelessWidget {
  final String text;
  const _Lbl(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text, style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
      );
}

class _Inp extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool readOnly;
  final TextInputType? keyboardType;
  const _Inp({required this.controller, required this.hint,
      this.readOnly = false, this.keyboardType});
  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        readOnly: readOnly,
        keyboardType: keyboardType,
        style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 13),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: Color(0xFF57606A), fontSize: 13),
          filled: true,
          fillColor: const Color(0xFF0D1117),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: Color(0xFF30363D))),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: Color(0xFF30363D))),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: Color(0xFF58A6FF))),
        ),
      );
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
