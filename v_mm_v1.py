"""
v_ip_v1.py — 무한매수법 V1 전략 로직

순수 계산 모듈. API 호출·파일 I/O 없음.
kis_api.py에서 snapshot을, 상태 파일에서 state를 받아 사용.

전략 흐름:
    40분할. 1포션 = 사이클자본/40 (최솟값: 평단가 1주 + 전일종가×1.10 1주)
    첫 매수: 현재가 기준 1포션 LOC (최소 2주)
    후속 매수:
        0.5포션 @ 평단가                        LOC
        0.5포션 @ min(전일종가×1.10, 평단가−0.01) LOC  ← 자전거래 방지
    매도(자본소진 전): 평단가×1.10 지정가 전량
    자본소진 후(살자법): 장중 +5% 익절 / −10% 손절 (상위 레이어 처리)

사용 예:
    from v_ip_v1 import build_v1_plan, StrategyState, PlannedOrder
"""

import math
from dataclasses import dataclass, field

# ─────────────────────────────────────────
# 전략 상수
# ─────────────────────────────────────────
N_SPLITS           = 40      # 총 분할 횟수
COMMISSION         = 0.0025  # 수수료율
TAKE_PROFIT_PCT    = 0.10    # 익절 목표 (+10%)
INTRADAY_TP_PCT    = 0.05    # 살자법 장중 익절 (+5%)
INTRADAY_SL_PCT    = 0.10    # 살자법 장중 손절 (−10%)
CLOSE_CAP_MULT     = 1.10    # 전일종가 매수 상한 배율


# ─────────────────────────────────────────
# 데이터 클래스
# ─────────────────────────────────────────

@dataclass
class PlannedOrder:
    side: str          # "BUY" | "SELL"
    quantity: int
    price: float
    amount: float
    reason: str
    ord_dvsn: str = "34"   # 34=LOC, 00=지정가, 32=MOC


@dataclass
class TradingPlan:
    current_price: float
    prev_close: float
    capital_depleted: bool
    orders: list[PlannedOrder] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)


@dataclass
class StrategyState:
    """전략 상태 (파일 저장·로드는 상위 레이어에서 처리)"""
    cycle_no: int = 1
    cycle_capital: float = 0.0
    buy_count: int = 0
    was_capital_depleted: bool = False   # sticky 플래그 — 사이클 종료 전까지 유지


# ─────────────────────────────────────────
# 수학 헬퍼
# ─────────────────────────────────────────

def _to_float(v, default: float = 0.0) -> float:
    if v in (None, "", " "):
        return default
    try:
        return float(str(v).replace(",", ""))
    except (TypeError, ValueError):
        return default


def _estimate_shares(budget: float, price: float) -> int:
    """예산·가격으로 매수 가능 수량 (수수료 차감, 내림). 최솟값 0."""
    if budget <= 0 or price <= 0:
        return 0
    return int(math.floor(budget * (1 - COMMISSION) / price))


def _required_cash(price: float, qty: int) -> float:
    """qty 주 매수에 필요한 현금 (수수료 포함)."""
    if price <= 0 or qty <= 0:
        return 0.0
    return price * qty / (1 - COMMISSION)


# ─────────────────────────────────────────
# 전략 계산
# ─────────────────────────────────────────

def portion_amount(
    cycle_capital: float,
    shares: float,
    avg_cost: float,
    prev_close: float,
    current_price: float,
) -> float:
    """1포션 = 사이클자본/40.
    최솟값: 보유 중이면 평단가 1주 + 전일종가×1.10 1주, 미보유면 현재가 2주."""
    base = cycle_capital / N_SPLITS
    if shares > 0 and avg_cost > 0 and prev_close > 0:
        min_portion = avg_cost + prev_close * CLOSE_CAP_MULT
    elif current_price > 0:
        min_portion = current_price * 2
    else:
        return base
    return max(base, min_portion)


def is_capital_depleted(
    cash: float,
    shares: float,
    avg_cost: float,
    prev_close: float,
    current_price: float,
    was_depleted: bool = False,
) -> bool:
    """1포션(최소 2주) 매수 불가 여부. was_depleted=True면 사이클 종료 전까지 True 유지."""
    if was_depleted:
        return True
    if shares > 0 and avg_cost > 0 and prev_close > 0:
        min_cash = _required_cash(avg_cost, 1) + _required_cash(prev_close * CLOSE_CAP_MULT, 1)
        return cash < min_cash
    elif current_price > 0:
        return cash < _required_cash(current_price, 2)
    return False


def take_profit_price(avg_cost: float) -> float:
    """익절 목표가 = 평단가 × 1.10 (지정가 매도 기준)."""
    return round(avg_cost * (1 + TAKE_PROFIT_PCT), 2)


def intraday_take_profit_price(avg_cost: float) -> float:
    """살자법 장중 익절가 = 평단가 × 1.05."""
    return round(avg_cost * (1 + INTRADAY_TP_PCT), 2)


def intraday_stop_loss_price(avg_cost: float) -> float:
    """살자법 장중 손절가 = 평단가 × 0.90."""
    return round(avg_cost * (1 - INTRADAY_SL_PCT), 2)


def buy_cap_price(prev_close: float, avg_cost: float) -> float:
    """후속 매수 2차 상한가 = min(전일종가×1.10, 평단가−0.01).

    전일종가×1.10 ≥ 평단가×1.10(익절가)이면 LOC 매수와 지정가 매도가
    같은 종가에서 동시 체결 → 자전거래 거부.
    평단가−0.01로 cap하면 매수 LOC가 항상 익절가보다 낮아 충돌 없음.
    """
    raw = round(prev_close * CLOSE_CAP_MULT, 2)
    cap = round(avg_cost - 0.01, 2)
    return min(raw, cap)


def capital_shortfall(cycle_capital: float, target_price: float) -> float:
    """target_price 기준 1포션(1주) 매수를 위한 추가 자본 부족분."""
    needed = _required_cash(target_price, 1) * N_SPLITS
    return max(needed - cycle_capital, 0.0)


# ─────────────────────────────────────────
# 핵심: V1 매매 플랜 생성
# ─────────────────────────────────────────

def build_v1_plan(
    current_price: float,
    prev_close: float,
    avg_cost: float,       # API 반환 평단가 (avg_unpr3 / pchs_avg_pric)
    shares: int,
    orderable_qty: int,
    cash: float,
    state: StrategyState,
) -> TradingPlan:
    """
    V1 전략으로 오늘의 주문 계획을 생성한다.

    Args:
        current_price : 현재가
        prev_close    : 전일 종가
        avg_cost      : API 반환 평단가
        shares        : 보유 수량
        orderable_qty : 매도 가능 수량
        cash          : 가용 현금
        state         : StrategyState

    Returns:
        TradingPlan (orders 리스트 + notes)
    """
    depleted = is_capital_depleted(
        cash, shares, avg_cost, prev_close, current_price, state.was_capital_depleted
    )
    portion = portion_amount(state.cycle_capital, shares, avg_cost, prev_close, current_price)

    plan = TradingPlan(
        current_price=current_price,
        prev_close=prev_close,
        capital_depleted=depleted,
    )

    # ══════════════════════════════════════
    # 매도 (자본소진 전: 지정가 / 소진 후: 살자법)
    # ══════════════════════════════════════
    if shares > 0 and avg_cost > 0:
        if depleted:
            tp = intraday_take_profit_price(avg_cost)
            sl = intraday_stop_loss_price(avg_cost)
            plan.notes.append(
                f"살자법: 자본소진. LOC 매수 없음. "
                f"장중 익절 ${tp:,.2f} / 손절 ${sl:,.2f} 모니터링."
            )
        else:
            tp = take_profit_price(avg_cost)
            sell_qty = int(max(orderable_qty, 0))
            if sell_qty > 0:
                plan.orders.append(PlannedOrder(
                    side="SELL", quantity=sell_qty, price=tp,
                    amount=round(sell_qty * tp, 2),
                    reason=f"평단가×1.10 익절 지정가 ${tp:,.2f} ({sell_qty}주)",
                    ord_dvsn="00",
                ))
            else:
                plan.notes.append("매도 가능 수량 없음 — 익절 지정가 생략.")

    if depleted:
        return plan

    # ══════════════════════════════════════
    # 현금 부족
    # ══════════════════════════════════════
    if cash <= 1:
        plan.notes.append("현금 부족 → 매수 생략.")
        return plan

    # ══════════════════════════════════════
    # 첫 매수 (미보유)
    # ══════════════════════════════════════
    if shares == 0:
        budget = min(portion, cash)
        qty = max(_estimate_shares(budget, current_price), 2)
        cost = _required_cash(current_price, qty)
        if cost <= cash:
            plan.orders.append(PlannedOrder(
                side="BUY", quantity=qty, price=round(current_price, 2),
                amount=round(qty * current_price, 2),
                reason=f"첫 진입 1포션 LOC 현재가 ${current_price:,.2f} ({qty}주)",
                ord_dvsn="34",
            ))
            plan.notes.append("첫 진입: 40분할 중 1포션 LOC.")
        else:
            shortfall = capital_shortfall(state.cycle_capital, current_price)
            plan.notes.append(
                f"첫 진입 최소 2주(${cost:,.2f}) 현금 부족. "
                f"추가 필요 자본: ${shortfall:,.2f}"
            )
        return plan

    # ══════════════════════════════════════
    # 후속 매수 (기보유)
    # ══════════════════════════════════════
    if avg_cost <= 0:
        plan.notes.append("평단가 없음 → 후속 매수 불가.")
        return plan

    price_avg  = round(avg_cost, 2)
    price_high = buy_cap_price(prev_close, avg_cost)

    # ── 1차: 0.5포션 @ 평단가 ────────────
    budget1 = min(portion * 0.5, cash)
    qty1    = max(_estimate_shares(budget1, price_avg), 1)
    cost1   = _required_cash(price_avg, qty1)
    if cost1 <= cash:
        plan.orders.append(PlannedOrder(
            side="BUY", quantity=qty1, price=price_avg,
            amount=round(qty1 * price_avg, 2),
            reason=f"평단가 LOC ${price_avg:,.2f} ({qty1}주, 0.5포션)",
            ord_dvsn="34",
        ))
    else:
        plan.notes.append(f"평단가 0.5포션 현금 부족(${cost1:,.2f}) — 생략.")
        cost1 = 0.0

    # ── 2차: 0.5포션 @ min(전일종가×1.10, 평단가−0.01) ────────────
    if prev_close <= 0:
        plan.notes.append("전일종가 없음 — 전일종가+10% 매수 생략.")
    else:
        cash2   = max(cash - cost1, 0.0)
        budget2 = min(portion * 0.5, cash2)
        qty2    = max(_estimate_shares(budget2, price_high), 1)
        cost2   = _required_cash(price_high, qty2)

        if cost2 <= cash2:
            raw_high   = round(prev_close * CLOSE_CAP_MULT, 2)
            cap_tag    = f" [cap 적용, 원래 ${raw_high:,.2f}]" if price_high < raw_high else ""
            plan.orders.append(PlannedOrder(
                side="BUY", quantity=qty2, price=price_high,
                amount=round(qty2 * price_high, 2),
                reason=f"전일종가+10% LOC ${price_high:,.2f} ({qty2}주, 0.5포션){cap_tag}",
                ord_dvsn="34",
            ))
        else:
            plan.notes.append(f"전일종가+10% 0.5포션 현금 부족(${cost2:,.2f}) — 생략.")

    plan.notes.append(
        f"포션=${portion:,.2f} | 평단가=${price_avg:,.2f} | "
        f"매수상한=${price_high:,.2f} | 익절가=${take_profit_price(avg_cost):,.2f}"
    )
    return plan


# ─────────────────────────────────────────
# 빠른 확인용
# ─────────────────────────────────────────

def _print_plan(plan: TradingPlan) -> None:
    tag = {"34": "LOC", "00": "지정가", "32": "MOC"}
    print(f"  capital_depleted={plan.capital_depleted} | 주문 {len(plan.orders)}건")
    for o in plan.orders:
        icon = "🟢" if o.side == "BUY" else "🔴"
        print(f"  {icon} {o.side} {o.quantity}주 @${o.price:.2f} | {tag.get(o.ord_dvsn, o.ord_dvsn)} | {o.reason}")
    for n in plan.notes:
        print(f"  ℹ️  {n}")


if __name__ == "__main__":
    import sys
    sys.stdout.reconfigure(encoding="utf-8")

    # 시나리오 1: 전일종가 > 평단가 → cap 적용
    print("=== 시나리오 1: 전일종가($110) > 평단가($100) — cap 적용 ===")
    plan1 = build_v1_plan(
        current_price=108.0, prev_close=110.0,
        avg_cost=100.0, shares=5, orderable_qty=5, cash=3000.0,
        state=StrategyState(cycle_capital=10000.0, buy_count=3),
    )
    _print_plan(plan1)

    # 시나리오 2: 전일종가 < 평단가 → 정상
    print("\n=== 시나리오 2: 전일종가($80) < 평단가($100) — 정상 ===")
    plan2 = build_v1_plan(
        current_price=82.0, prev_close=80.0,
        avg_cost=100.0, shares=3, orderable_qty=3, cash=5000.0,
        state=StrategyState(cycle_capital=10000.0, buy_count=2),
    )
    _print_plan(plan2)

    # 시나리오 3: 첫 진입
    print("\n=== 시나리오 3: 첫 진입 ===")
    plan3 = build_v1_plan(
        current_price=150.0, prev_close=145.0,
        avg_cost=0.0, shares=0, orderable_qty=0, cash=8000.0,
        state=StrategyState(cycle_capital=8000.0),
    )
    _print_plan(plan3)

    # 시나리오 4: 자본소진 (살자법)
    print("\n=== 시나리오 4: 자본소진 (살자법) ===")
    plan4 = build_v1_plan(
        current_price=90.0, prev_close=92.0,
        avg_cost=100.0, shares=10, orderable_qty=10, cash=50.0,
        state=StrategyState(cycle_capital=10000.0, was_capital_depleted=True),
    )
    _print_plan(plan4)
