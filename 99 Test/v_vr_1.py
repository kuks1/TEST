"""
v_vr_1.py — Value Rebalancing (VR) 전략 로직

순수 계산 모듈. API 호출·파일 I/O 없음.

전략 흐름:
    2주(1사이클)마다 목표가치 V₂를 갱신:
        V₂ = V₁ + Pool/G + (e − V₁) / (2√G) ± CashFlow

    밴드 V₂ ± 15% 그리드 리밸런싱:
        e < V₂×0.85  → Pool 한도×60% 자금으로 1.14% 간격 하방 그리드 매수
        e > V₂×1.15  → 1.14% 간격 상방 그리드 매도 (1주 또는 ~100주씩 분배)

단계 전환 (적립액 대비 총자산 배수):
    ~260배    : 적립식 (G=10+년차, $50/cycle 적립, Pool 한도 0%→75%→감소)
    260~4000  : 거치식 (G=10, Pool 한도 50%)
    4000배~   : 인출식 (G=20, Pool 한도 75%)

사용 예:
    from v_vr_1 import build_vr_plan, VrState, GridOrder
"""

import math
from dataclasses import dataclass, field

# ─────────────────────────────────────────
# 전략 상수
# ─────────────────────────────────────────
CYCLE_WEEKS                     = 2
BAND_PCT                        = 0.15      # ±15% 밴드
GRID_STEP_PCT                   = 0.0114    # 1.14% 그리드 간격
BUY_POOL_USE_RATE               = 0.60      # 매수 시 Pool 한도 × 60%
MAX_GRID_LEVELS                 = 200       # 안전 한도 (무한루프 방지)

# 단계 전환 기준 (적립액 대비 총자산 배수)
ACCUM_TO_LUMP_MULT              = 260
LUMP_TO_WD_MULT                 = 4000

# 단계별 G 값
G_ACCUM_BASE                    = 10        # 적립식: 매년 +1 증가
G_LUMP                          = 10
G_WD                            = 20

# 단계별 Pool 사용 한도
ACCUM_LIMIT_FIRST_YEAR          = 0.0       # 첫 52주: 사용 불가
ACCUM_LIMIT_AFTER_1Y            = 0.75      # 1년 후 시작
ACCUM_LIMIT_DECAY_PER_HALF_YEAR = 0.05      # 6개월마다 -0.05
LUMP_LIMIT                      = 0.50
WD_LIMIT                        = 0.75

# 적립 금액 (적립식)
ACCUM_DEPOSIT_PER_CYCLE         = 50.0

# 단계 라벨
STAGE_ACCUMULATION              = "accumulation"
STAGE_LUMPSUM                   = "lumpsum"
STAGE_WITHDRAWAL                = "withdrawal"


# ─────────────────────────────────────────
# 데이터 클래스
# ─────────────────────────────────────────

@dataclass
class GridOrder:
    side: str          # "BUY" | "SELL"
    quantity: int
    price: float
    amount: float
    level: int         # 그리드 호가 번호 (1부터)


@dataclass
class VrPlan:
    V1: float
    V2: float
    V_min: float
    V_max: float
    equity: float
    pool: float
    shares: int
    stage: str
    G: float
    cash_flow: float
    pool_usage_limit: float
    orders: list[GridOrder] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)


@dataclass
class VrState:
    """전략 상태 (파일 저장·로드는 상위 레이어에서 처리)"""
    cycle_no: int = 1
    week: int = 0                      # 누적 주차 (2주씩 +)
    V1: float = 0.0                    # 직전 사이클 V₂
    cumulative_deposit: float = 0.0    # 누적 적립액 (초기 원금 포함)


# ─────────────────────────────────────────
# 단계·변수 계산
# ─────────────────────────────────────────

def determine_stage(total_asset: float, cumulative_deposit: float) -> str:
    """총자산이 누적 적립액의 몇 배인지 보고 단계 결정."""
    if cumulative_deposit <= 0:
        return STAGE_ACCUMULATION
    ratio = total_asset / cumulative_deposit
    if ratio >= LUMP_TO_WD_MULT:
        return STAGE_WITHDRAWAL
    if ratio >= ACCUM_TO_LUMP_MULT:
        return STAGE_LUMPSUM
    return STAGE_ACCUMULATION


def gradient(stage: str, week: int) -> float:
    """단계별 G 값. 적립식은 매년 +1."""
    if stage == STAGE_WITHDRAWAL:
        return float(G_WD)
    if stage == STAGE_LUMPSUM:
        return float(G_LUMP)
    years = week // 52
    return float(G_ACCUM_BASE + years)


def pool_usage_limit(stage: str, week: int) -> float:
    """단계별 Pool 사용 가능 비율."""
    if stage == STAGE_LUMPSUM:
        return LUMP_LIMIT
    if stage == STAGE_WITHDRAWAL:
        return WD_LIMIT
    # 적립식
    if week < 52:
        return ACCUM_LIMIT_FIRST_YEAR
    half_years = (week - 52) // 26
    return max(0.0, ACCUM_LIMIT_AFTER_1Y - half_years * ACCUM_LIMIT_DECAY_PER_HALF_YEAR)


def cash_flow(stage: str, withdrawal: float = 0.0) -> float:
    """단계별 현금 흐름: 적립(+) / 거치(0) / 인출(-)."""
    if stage == STAGE_ACCUMULATION:
        return ACCUM_DEPOSIT_PER_CYCLE
    if stage == STAGE_WITHDRAWAL:
        return -abs(withdrawal)
    return 0.0


def calc_V2(V1: float, pool: float, G: float, equity: float, cf: float) -> float:
    """V₂ = V₁ + Pool/G + (e − V₁) / (2√G) + cash_flow"""
    if G <= 0:
        return V1
    return V1 + (pool / G) + (equity - V1) / (2.0 * math.sqrt(G)) + cf


# ─────────────────────────────────────────
# 그리드 주문 생성
# ─────────────────────────────────────────

def _buy_start_price(V_min: float, shares: int, current_price: float) -> float:
    """매수 그리드 시작가 = V_min / shares.
    미보유 시 current_price × 0.85 (V_min은 평가금 단위라 직접 매핑 불가)."""
    if shares > 0:
        return V_min / shares
    return current_price * (1 - BAND_PCT)


def _sell_start_price(V_max: float, shares: int) -> float:
    """매도 그리드 시작가 = V_max / shares."""
    if shares <= 0:
        return 0.0
    return V_max / shares


def grid_buy_orders(P_start: float, pool_to_use: float, current_price: float) -> list[GridOrder]:
    """1.14%씩 하락 그리드, 1주씩, 할당된 자금 소진까지.
    현재가보다 높은 호가는 건너뛰고 다음 레벨로."""
    orders: list[GridOrder] = []
    if P_start <= 0 or pool_to_use <= 0:
        return orders
    spent = 0.0
    price = P_start
    for level in range(1, MAX_GRID_LEVELS + 1):
        if price <= 0:
            break
        if price > current_price:
            price *= (1 - GRID_STEP_PCT)
            continue
        if spent + price > pool_to_use:
            break
        rp = round(price, 2)
        orders.append(GridOrder(
            side="BUY", quantity=1, price=rp, amount=rp, level=level,
        ))
        spent += rp
        price *= (1 - GRID_STEP_PCT)
    return orders


def grid_sell_orders(P_start: float, shares: int) -> list[GridOrder]:
    """1.14%씩 상승 그리드.
    - shares < 100   : 1주씩 shares 호가
    - shares ≥ 100   : 100호가에 균등 분배 (나머지는 앞쪽 호가에 +1주)
    """
    orders: list[GridOrder] = []
    if shares <= 0 or P_start <= 0:
        return orders

    if shares < 100:
        n_levels = shares
        for i in range(n_levels):
            price = round(P_start * ((1 + GRID_STEP_PCT) ** i), 2)
            orders.append(GridOrder(
                side="SELL", quantity=1, price=price, amount=price, level=i + 1,
            ))
    else:
        n_levels = min(100, MAX_GRID_LEVELS)
        per_level = shares // n_levels
        remainder = shares - per_level * n_levels
        for i in range(n_levels):
            qty = per_level + (1 if i < remainder else 0)
            price = round(P_start * ((1 + GRID_STEP_PCT) ** i), 2)
            orders.append(GridOrder(
                side="SELL", quantity=qty, price=price,
                amount=round(qty * price, 2), level=i + 1,
            ))
    return orders


# ─────────────────────────────────────────
# 핵심: VR 매매 플랜 생성
# ─────────────────────────────────────────

def build_vr_plan(
    state: VrState,
    equity: float,
    pool: float,
    shares: int,
    current_price: float,
    withdrawal: float = 0.0,
) -> VrPlan:
    """VR 전략으로 이번 사이클의 주문 계획을 생성한다.

    Args:
        state          : VrState (cycle_no, week, V1, cumulative_deposit)
        equity         : 현재 주식 평가금 (shares × current_price)
        pool           : 현재 가용 현금
        shares         : 보유 수량
        current_price  : 현재가
        withdrawal     : 인출식 단계에서만 사용 (양수 = 인출액)

    Returns:
        VrPlan (orders 리스트 + notes + V₁/V₂/밴드/단계/G 등 부가정보)
    """
    total_asset = equity + pool
    stage = determine_stage(total_asset, state.cumulative_deposit)
    G = gradient(stage, state.week)
    limit = pool_usage_limit(stage, state.week)
    cf = cash_flow(stage, withdrawal)

    V2 = calc_V2(state.V1, pool, G, equity, cf)
    V_min = V2 * (1 - BAND_PCT)
    V_max = V2 * (1 + BAND_PCT)

    plan = VrPlan(
        V1=state.V1, V2=V2, V_min=V_min, V_max=V_max,
        equity=equity, pool=pool, shares=shares,
        stage=stage, G=G, cash_flow=cf, pool_usage_limit=limit,
    )

    pool_available = pool * limit
    plan.notes.append(
        f"Stage={stage} | G={G:.0f} | Pool 한도={limit*100:.0f}% "
        f"(${pool_available:,.2f} 사용가능) | CashFlow={cf:+,.2f}"
    )
    plan.notes.append(
        f"V₁=${state.V1:,.2f} → V₂=${V2:,.2f} | "
        f"밴드 [${V_min:,.2f}, ${V_max:,.2f}] | equity=${equity:,.2f}"
    )

    if equity < V_min:
        pool_to_use = pool_available * BUY_POOL_USE_RATE
        P_start = _buy_start_price(V_min, shares, current_price)
        plan.orders = grid_buy_orders(P_start, pool_to_use, current_price)
        plan.notes.append(
            f"📥 매수 영역 (e < V_min). P_start=${P_start:,.2f}, "
            f"할당=${pool_to_use:,.2f} (Pool 한도×60%)"
        )
    elif equity > V_max:
        P_start = _sell_start_price(V_max, shares)
        plan.orders = grid_sell_orders(P_start, shares)
        plan.notes.append(
            f"📤 매도 영역 (e > V_max). P_start=${P_start:,.2f}, "
            f"보유 {shares}주 분산"
        )
    else:
        plan.notes.append("⏸️  홀드 영역 (밴드 내) — 주문 없음")

    return plan


# ─────────────────────────────────────────
# 빠른 확인용
# ─────────────────────────────────────────

def _print_plan(plan: VrPlan) -> None:
    print(f"  {plan.stage} | G={plan.G:.0f} | 주문 {len(plan.orders)}건")
    for n in plan.notes:
        print(f"  ℹ️  {n}")
    if plan.orders:
        head = plan.orders[:5]
        tail = plan.orders[-2:] if len(plan.orders) > 7 else []
        for o in head:
            icon = "🟢" if o.side == "BUY" else "🔴"
            print(f"    {icon} L{o.level:3d} {o.side} {o.quantity}주 @${o.price:,.4f}")
        if tail:
            print(f"    ... ({len(plan.orders) - 7}건 생략) ...")
            for o in tail:
                icon = "🟢" if o.side == "BUY" else "🔴"
                print(f"    {icon} L{o.level:3d} {o.side} {o.quantity}주 @${o.price:,.4f}")
        total_qty = sum(o.quantity for o in plan.orders)
        total_amt = sum(o.amount for o in plan.orders)
        print(f"  💼 합계: {total_qty}주, ${total_amt:,.2f}")


if __name__ == "__main__":
    import sys
    sys.stdout.reconfigure(encoding="utf-8")

    # 시나리오 1: 적립식 1년차 — Pool 사용 불가 (주문 불가)
    print("=== 시나리오 1: 적립식 1년차 (week=26, Pool 한도 0%) ===")
    plan1 = build_vr_plan(
        state=VrState(cycle_no=13, week=26, V1=5500.0, cumulative_deposit=5450.0),
        equity=4500.0, pool=1000.0, shares=200, current_price=22.50,
    )
    _print_plan(plan1)

    # 시나리오 2: 적립식 2년차 — equity < V_min → 그리드 매수
    print("\n=== 시나리오 2: 적립식 2년차 — 매수 영역 ===")
    plan2 = build_vr_plan(
        state=VrState(cycle_no=50, week=98, V1=10000.0, cumulative_deposit=17500.0),
        equity=7500.0, pool=2000.0, shares=350, current_price=21.43,
    )
    _print_plan(plan2)

    # 시나리오 3: 거치식 — equity > V_max → 그리드 매도 (1주씩, < 100주)
    print("\n=== 시나리오 3: 거치식 — 매도 영역 (50주 보유) ===")
    plan3 = build_vr_plan(
        state=VrState(cycle_no=100, week=200, V1=3500.0, cumulative_deposit=200.0),
        equity=5000.0, pool=2000.0, shares=50, current_price=100.0,
    )
    _print_plan(plan3)

    # 시나리오 4: 거치식 — equity > V_max → 그리드 매도 (100호가 균등 분배)
    print("\n=== 시나리오 4: 거치식 — 매도 영역 (900주 보유, 100호가 분배) ===")
    plan4 = build_vr_plan(
        state=VrState(cycle_no=100, week=200, V1=50000.0, cumulative_deposit=200.0),
        equity=70000.0, pool=10000.0, shares=900, current_price=77.78,
    )
    _print_plan(plan4)

    # 시나리오 5: 인출식 — 홀드 영역, $200 인출
    print("\n=== 시나리오 5: 인출식 — 홀드 + $200 인출 ===")
    plan5 = build_vr_plan(
        state=VrState(cycle_no=400, week=800, V1=900000.0, cumulative_deposit=200.0),
        equity=895000.0, pool=50000.0, shares=8000, current_price=111.88,
        withdrawal=200.0,
    )
    _print_plan(plan5)
