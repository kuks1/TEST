class Strategy {
  final int? id;
  final String strategyId;
  final String type; // v4, v1, vr, kr_value
  final String symbol;
  final String market; // KR, US
  final double capital;
  final bool active;
  final double? tValue;
  final double? v1Value;
  final int? cycleNo;
  final int? weekNo;
  final double? cumDeposit;
  final DateTime createdAt;
  // V4 전용 상수
  final int? divisions;
  final int? starBase;
  final double? starCoeff;
  // VR 운용 방식
  final String? vrMode;  // '적립식' | '거치식' | '인출식'
  // MM 전용: 주문 계산에 사용하는 별도 원금
  final double? calcCapital;
  // VR 전용 파라미터
  final double? vrBand;       // 밴드 % (null → 0.15)
  final double? vrDeposit;    // 사이클당 입금액 (null → 250.0, 적립식)
  final double? vrWithdrawal; // 사이클당 인출액 (null → 0.0, 인출식)
  final double? vrPoolPct;    // Pool 사용 한도 override (null → 자동)
  final int? vrG;             // G값 override (null → 자동)
  final int? vrQtyPerStep;    // 호가당 수량 (null → 1)
  final int? cyclePeriod;     // 사이클 주기 주 수 (null → 4주)
  final double? v1SalsaTpPct; // 살자법 장중 익절 % (null → 5.0)
  final double? v1SalsaSlPct; // 살자법 장중 손절 % (null → 10.0)
  final String? deletedAt;    // soft delete timestamp

  const Strategy({
    this.id,
    required this.strategyId,
    required this.type,
    required this.symbol,
    required this.market,
    required this.capital,
    this.active = true,
    this.tValue,
    this.v1Value,
    this.cycleNo,
    this.weekNo,
    this.cumDeposit,
    required this.createdAt,
    this.divisions,
    this.starBase,
    this.starCoeff,
    this.vrMode,
    this.calcCapital,
    this.vrBand,
    this.vrDeposit,
    this.vrWithdrawal,
    this.vrPoolPct,
    this.vrG,
    this.vrQtyPerStep,
    this.v1SalsaTpPct,
    this.v1SalsaSlPct,
    this.cyclePeriod,
    this.deletedAt,
  });

  double get vrEffectiveBand => vrBand ?? 0.15;
  double get vrEffectiveDeposit => vrDeposit ?? 250.0;
  double get vrEffectiveWithdrawal => vrWithdrawal ?? 0.0;

  factory Strategy.fromMap(Map<String, dynamic> m) => Strategy(
        id: m['id'],
        strategyId: m['strategy_id'],
        type: m['type'],
        symbol: m['symbol'] ?? '',
        market: m['market'] ?? 'KR',
        capital: (m['capital'] as num).toDouble(),
        active: m['active'] == 1,
        tValue: m['t_value'] != null ? (m['t_value'] as num).toDouble() : null,
        v1Value: m['v1_value'] != null ? (m['v1_value'] as num).toDouble() : null,
        cycleNo: m['cycle_no'],
        weekNo: m['week_no'],
        cumDeposit: m['cum_deposit'] != null ? (m['cum_deposit'] as num).toDouble() : null,
        createdAt: DateTime.parse(m['created_at']),
        divisions: m['divisions'] as int?,
        starBase: m['star_base'] as int?,
        starCoeff: m['star_coeff'] != null ? (m['star_coeff'] as num).toDouble() : null,
        vrMode: m['vr_mode'] as String?,
        calcCapital: m['calc_capital'] != null ? (m['calc_capital'] as num).toDouble() : null,
        vrBand: m['vr_band'] != null ? (m['vr_band'] as num).toDouble() : null,
        vrDeposit: m['vr_deposit'] != null ? (m['vr_deposit'] as num).toDouble() : null,
        vrWithdrawal: m['vr_withdrawal'] != null ? (m['vr_withdrawal'] as num).toDouble() : null,
        vrPoolPct: m['vr_pool_pct'] != null ? (m['vr_pool_pct'] as num).toDouble() : null,
        vrG: m['vr_g'] as int?,
        vrQtyPerStep: m['vr_qty_per_step'] as int?,
        v1SalsaTpPct: m['v1_salsa_tp_pct'] != null ? (m['v1_salsa_tp_pct'] as num).toDouble() : null,
        v1SalsaSlPct: m['v1_salsa_sl_pct'] != null ? (m['v1_salsa_sl_pct'] as num).toDouble() : null,
        cyclePeriod: m['cycle_period'] as int?,
        deletedAt: m['deleted_at'] as String?,
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'strategy_id': strategyId,
        'type': type,
        'symbol': symbol,
        'market': market,
        'capital': capital,
        'active': active ? 1 : 0,
        't_value': tValue,
        'v1_value': v1Value,
        'cycle_no': cycleNo,
        'week_no': weekNo,
        'cum_deposit': cumDeposit,
        'created_at': createdAt.toIso8601String(),
        'divisions': divisions,
        'star_base': starBase,
        'star_coeff': starCoeff,
        'vr_mode': vrMode,
        'calc_capital': calcCapital,
        'vr_band': vrBand,
        'vr_deposit': vrDeposit,
        'vr_withdrawal': vrWithdrawal,
        'vr_pool_pct': vrPoolPct,
        'vr_g': vrG,
        'vr_qty_per_step': vrQtyPerStep,
        'v1_salsa_tp_pct': v1SalsaTpPct,
        'v1_salsa_sl_pct': v1SalsaSlPct,
        'cycle_period': cyclePeriod,
      };

  static const _keep = Object();

  Strategy copyWith({
    String? strategyId,
    String? type,
    String? symbol,
    String? market,
    double? capital,
    bool? active,
    double? tValue,
    double? v1Value,
    int? cycleNo,
    int? weekNo,
    double? cumDeposit,
    int? divisions,
    int? starBase,
    double? starCoeff,
    String? vrMode,
    Object? calcCapital = _keep,
    Object? vrBand = _keep,
    Object? vrDeposit = _keep,
    Object? vrWithdrawal = _keep,
    Object? vrPoolPct = _keep,
    Object? vrG = _keep,
    Object? vrQtyPerStep = _keep,
    Object? v1SalsaTpPct = _keep,
    Object? v1SalsaSlPct = _keep,
    Object? cyclePeriod = _keep,
  }) =>
      Strategy(
        id: id,
        strategyId: strategyId ?? this.strategyId,
        type: type ?? this.type,
        symbol: symbol ?? this.symbol,
        market: market ?? this.market,
        capital: capital ?? this.capital,
        active: active ?? this.active,
        tValue: tValue ?? this.tValue,
        v1Value: v1Value ?? this.v1Value,
        cycleNo: cycleNo ?? this.cycleNo,
        weekNo: weekNo ?? this.weekNo,
        cumDeposit: cumDeposit ?? this.cumDeposit,
        createdAt: createdAt,
        divisions: divisions ?? this.divisions,
        starBase: starBase ?? this.starBase,
        starCoeff: starCoeff ?? this.starCoeff,
        vrMode: vrMode ?? this.vrMode,
        calcCapital: identical(calcCapital, _keep) ? this.calcCapital : calcCapital as double?,
        vrBand: identical(vrBand, _keep) ? this.vrBand : vrBand as double?,
        vrDeposit: identical(vrDeposit, _keep) ? this.vrDeposit : vrDeposit as double?,
        vrWithdrawal: identical(vrWithdrawal, _keep) ? this.vrWithdrawal : vrWithdrawal as double?,
        vrPoolPct: identical(vrPoolPct, _keep) ? this.vrPoolPct : vrPoolPct as double?,
        vrG: identical(vrG, _keep) ? this.vrG : vrG as int?,
        vrQtyPerStep: identical(vrQtyPerStep, _keep) ? this.vrQtyPerStep : vrQtyPerStep as int?,
        v1SalsaTpPct: identical(v1SalsaTpPct, _keep) ? this.v1SalsaTpPct : v1SalsaTpPct as double?,
        v1SalsaSlPct: identical(v1SalsaSlPct, _keep) ? this.v1SalsaSlPct : v1SalsaSlPct as double?,
        cyclePeriod: identical(cyclePeriod, _keep) ? this.cyclePeriod : cyclePeriod as int?,
      );

  String get typeLabel {
    switch (type) {
      case 'v4': return 'MM V4';
      case 'v1': return 'MM V1';
      case 'vr': return 'VR';
      case 'kr_value': return 'QT KR';
      default: return type.toUpperCase();
    }
  }
}
