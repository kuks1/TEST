"""
v_ip_v4.py — 무한매수법 V4 전략 로직

순수 계산 모듈. API 호출·파일 I/O 없음.
kis_api.py에서 snapshot을, 상태 파일에서 tracker를 받아 사용.

전략 흐름:
    일반모드: 전반전(0<T<10) 0.5포션×2, 후반전(10≤T<20) 1포션 + 폭락대비 LOC
    리버스모드: T>19 진입, 5MA 기반 매도·매수, 종가≥평단×0.80 복귀
    최종 익절: 평단가×1.20 지정가 매도

사용 예:
    from v_ip_v4 import build_v4_plan, StrategyState, PlannedOrder
"""

import math
from dataclasses import dataclass, field

# ─────────────────────────────────────────
# 전략 상수
# ─────────────────────────────────────────
N_SPLITS               = 20      # 총 분할 횟수
COMMISSION             = 0.0025  # 수수료율
PROFIT_TARGET_PCT      = 0.20    # 최종 익절 목표 (+20%)
REVERSE_RECOVERY_PCT   = 0.80    # 리버스 복귀 조건 (종가 ≥ 평단×80%)
LOC_CAP_MULT           = 1.10    # 첫 매수 캡 (전일종가×110%)
CRASH_MAX_DROP_PCT     = 0.30    # 폭락대비 최대 하락폭 (30%)
CRASH_MAX_ORDERS       = 20      # 폭락대비 추가 주문 최대 개수


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
    mode: str
    T: float
    orders: list[PlannedOrder] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)


@dataclass
class StrategyState:
    """전략 상태 (파일 저장·로드는 상위 레이어에서 처리)"""
    T: float = 0.0
    mode: str = "normal"          # "normal" | "reverse"
    reverse_day: int = 0
    cycle_no: int = 1
    cycle_capital: float = 0.0    # 사이클 시작 자본
    close_history: list = field(default_factory=list)  # 최근 5거래일 종가


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


def _floor2(v: float) -> float:
    """소수점 2자리 내림"""
    return math.floor(v * 100) / 100


def _round_half_step(v: float) -> float:
    """0.5 단위 반올림"""
    return round(v * 2) / 2 if v > 0 else 0.0


def _estimate_shares(budget: float, price: float) -> int:
    """예산·가격으로 매수 가능 수량(내림, 최소 1주)"""
    if budget <= 0 or price <= 0:
        return 0
    raw = budget * (1 - COMMISSION) / price
    qty = int(math.floor(raw))
    return max(qty, 1) if raw > 0 else 0


def _required_cash(price: float, qty: int) -> float:
    """qty 주 매수에 필요한 현금 (수수료 포함)"""
    if price <= 0 or qty <= 0:
        return 0.0
    return price * qty / (1 - COMMISSION)


def _fractional_sell_qty(shares: int, ratio: float) -> int:
    """보유수량×비율 내림, 최소 1주"""
    if shares <= 0 or ratio <= 0:
        return 0
    return max(int(math.floor(shares * ratio)), 1)


def _cap_qty(qty: int, orderable: int) -> int:
    return min(max(int(qty), 0), max(int(orderable), 0))


# ─────────────────────────────────────────
# 전략 계산
# ─────────────────────────────────────────

def star_pct(T: float) -> float:
    """별% = (20 - 2T) / 100"""
    return (N_SPLITS - 2 * T) / 100.0


def star_price(avg_cost: float, T: float) -> float:
    """별지점 = 평단가 × (1 + 별%)"""
    return avg_cost * (1 + star_pct(T))


def buy_point(avg_cost: float, T: float) -> float:
    """매수점 = 별지점 - 0.01"""
    return round(star_price(avg_cost, T) - 0.01, 2)


def portion_amount(cash: float, T: float) -> float:
    """1회 매수금 = 현금 / (N - T)"""
    d = N_SPLITS - T
    return cash / d if d > 0 else 0.0


def calc_5ma(closes: list) -> float:
    if not closes:
        return 0.0
    return sum(closes[-5:]) / min(len(closes), 5)


def strategy_avg_cost(raw_avg: float) -> float:
    """API 반환 평단가 → 전략 기준 평단가 (수수료 환원)"""
    return raw_avg / (1 - COMMISSION) if raw_avg > 0 else 0.0


def t_after_quarter_sell(T: float) -> float:
    return T * 0.75


def t_after_final_sell(T: float) -> float:
    return T * 0.25


def t_after_reverse_sell(T: float) -> float:
    return T * 0.9


def t_after_reverse_buy(T: float) -> float:
    return T + (N_SPLITS - T) * 0.25


def should_enter_reverse(T: float) -> bool:
    return T > N_SPLITS - 1


def should_exit_reverse(close: float, avg_cost: float) -> bool:
    return close >= avg_cost * REVERSE_RECOVERY_PCT


def _crash_orders(
    budget: float,
    base_price: float,
    base_qty: int,
    cash_remaining: float,
) -> list[tuple[float, int]]:
    """폭락장 대비 추가 LOC 주문 목록 (price, 1주씩)"""
    if budget <= 0 or base_price <= 0 or base_qty <= 0:
        return []
    additional = []
    qty = base_qty + 1
    min_price = base_price * (1 - CRASH_MAX_DROP_PCT)
    hard_limit = base_qty + CRASH_MAX_ORDERS * 5

    while len(additional) < CRASH_MAX_ORDERS and qty <= hard_limit:
        price = _floor2(budget * (1 - COMMISSION) / qty)
        if price <= 0 or price < min_price:
            break
        if price >= base_price:
            qty += 1
            continue
        if _required_cash(price, qty) > cash_remaining:
            break
        additional.append((round(price, 2), 1))
        qty += 1
    return additional


# ─────────────────────────────────────────
# 핵심: V4 매매 플랜 생성
# ─────────────────────────────────────────

def build_v4_plan(
    current_price: float,
    prev_close: float,
    avg_price_raw: float,   # API가 반환한 평단가 (수수료 미반영)
    shares: int,
    orderable_qty: int,
    cash: float,
    state: StrategyState,
) -> TradingPlan:
    """
    V4.0 전략으로 오늘의 주문 계획을 생성한다.

    Args:
        current_price  : 현재가
        prev_close     : 전일 종가
        avg_price_raw  : API 잔고 조회 pchs_avg_pric (수수료 포함 전)
        shares         : 보유 수량
        orderable_qty  : 주문 가능 수량
        cash           : 가용 현금
        state          : StrategyState (T, mode, reverse_day, close_history)

    Returns:
        TradingPlan (orders 리스트 + notes)
    """
    T        = state.T
    mode     = state.mode
    avg_cost = strategy_avg_cost(_to_float(avg_price_raw))
    cap      = round(prev_close * LOC_CAP_MULT, 2)

    plan = TradingPlan(current_price=current_price, prev_close=prev_close, mode=mode, T=T)

    # ══════════════════════════════════════
    # 리버스모드
    # ══════════════════════════════════════
    if mode == "reverse":
        rday   = state.reverse_day
        five_ma = round(calc_5ma(state.close_history) or current_price, 2)
        plan.notes.append(f"리버스 Day {rday} | 5MA=${five_ma:,.2f} | T={T:.2f}")

        if rday == 1:
            qty = _cap_qty(_fractional_sell_qty(shares, 0.10), orderable_qty)
            if qty > 0:
                plan.orders.append(PlannedOrder(
                    side="SELL", quantity=qty, price=current_price,
                    amount=qty * current_price,
                    reason=f"리버스 1일차 MOC 매도 ({shares}×10%={qty}주)",
                    ord_dvsn="32",
                ))
            plan.notes.append("리버스 1일차: MOC 매도만, 매수 없음")
        else:
            # LOC 매도: 5MA
            sq = _cap_qty(_fractional_sell_qty(shares, 0.10), orderable_qty)
            if sq > 0:
                plan.orders.append(PlannedOrder(
                    side="SELL", quantity=sq, price=five_ma,
                    amount=sq * five_ma,
                    reason=f"리버스 LOC 매도 @5MA ${five_ma:.2f} ({sq}주)",
                    ord_dvsn="34",
                ))
            # LOC 매수: 잔금/4, 5MA-0.01
            buy_price = round(five_ma - 0.01, 2)
            bq = _estimate_shares(cash / 4, buy_price)
            if bq >= 1:
                plan.orders.append(PlannedOrder(
                    side="BUY", quantity=bq, price=buy_price,
                    amount=bq * buy_price,
                    reason=f"리버스 쿼터매수 @5MA-0.01 ${buy_price:.2f} ({bq}주)",
                    ord_dvsn="34",
                ))
        return plan

    # ══════════════════════════════════════
    # 일반모드
    # ══════════════════════════════════════
    if should_enter_reverse(T):
        plan.notes.append(f"⚠️  T={T:.2f} > {N_SPLITS-1} → 리버스모드 전환 예정")
        return plan

    portion = portion_amount(cash, T)

    # ── 첫 매수 (T=0, 보유 없음) ──────────
    if T == 0 and shares == 0:
        bq = _estimate_shares(min(portion, cash), cap)
        if bq >= 1:
            plan.orders.append(PlannedOrder(
                side="BUY", quantity=bq, price=cap,
                amount=round(bq * cap, 2),
                reason=f"첫 매수 LOC (전일종가×1.10=${cap:.2f}, 포션=${portion:.0f})",
                ord_dvsn="34",
            ))
            cash_after = cash - _required_cash(cap, bq)
            for cp, cq in _crash_orders(min(portion, cash), cap, bq, cash_after + _required_cash(cap, bq)):
                plan.orders.append(PlannedOrder(
                    side="BUY", quantity=cq, price=cp,
                    amount=round(cp * cq, 2),
                    reason=f"첫 매수 폭락대비 LOC (${cp:.2f})",
                    ord_dvsn="34",
                ))
        else:
            plan.notes.append(f"첫 매수 불가: 현금 ${cash:.2f}")
        return plan

    # ── 매도 (쿼터 LOC + 최종 지정가) ──────
    if shares > 0 and avg_cost > 0:
        sp         = round(star_price(avg_cost, T), 2)
        final_p    = round(avg_cost * (1 + PROFIT_TARGET_PCT), 2)
        quarter_q  = _cap_qty(_fractional_sell_qty(shares, 0.25), orderable_qty)
        final_q    = _cap_qty(shares - quarter_q, max(orderable_qty - quarter_q, 0))

        if quarter_q > 0:
            plan.orders.append(PlannedOrder(
                side="SELL", quantity=quarter_q, price=sp,
                amount=round(quarter_q * sp, 2),
                reason=f"쿼터매도 LOC @별지점 ${sp:.2f} ({quarter_q}주)",
                ord_dvsn="34",
            ))
        if final_q > 0:
            plan.orders.append(PlannedOrder(
                side="SELL", quantity=final_q, price=final_p,
                amount=round(final_q * final_p, 2),
                reason=f"최종매도 지정가 @평단×1.20 ${final_p:.2f} ({final_q}주)",
                ord_dvsn="00",
            ))

    # ── 매수 ─────────────────────────────
    if cash <= 1:
        plan.notes.append("현금 부족 → 매수 생략")
        return plan

    if avg_cost <= 0:
        plan.notes.append("평단가 없음 → 매수 불가")
        return plan

    bp = buy_point(avg_cost, T)

    if 0 < T < N_SPLITS / 2:
        # 전반전: 0.5포션×별지점 + 0.5포션×평단가
        sb_budget = min(portion * 0.5, cash)
        sbq = _estimate_shares(sb_budget, bp)
        if sbq >= 1:
            plan.orders.append(PlannedOrder(
                side="BUY", quantity=sbq, price=bp,
                amount=round(sbq * bp, 2),
                reason=f"전반전 별지점 LOC ${bp:.2f} ({sbq}주, T={T:.1f})",
                ord_dvsn="34",
            ))
            for cp, cq in _crash_orders(sb_budget, bp, sbq, sb_budget):
                plan.orders.append(PlannedOrder(
                    side="BUY", quantity=cq, price=cp,
                    amount=round(cp * cq, 2),
                    reason=f"전반전 별지점 폭락대비 LOC ${cp:.2f}",
                    ord_dvsn="34",
                ))

        rem = max(cash - _required_cash(bp, sbq), 0)
        ab_budget = min(portion * 0.5, rem)
        abq = _estimate_shares(ab_budget, avg_cost)
        if abq >= 1:
            plan.orders.append(PlannedOrder(
                side="BUY", quantity=abq, price=round(avg_cost, 2),
                amount=round(abq * avg_cost, 2),
                reason=f"전반전 평단가 LOC ${avg_cost:.2f} ({abq}주, T={T:.1f})",
                ord_dvsn="34",
            ))

    elif N_SPLITS / 2 <= T < N_SPLITS:
        # 후반전: 1포션 별지점 LOC
        budget = min(portion, cash)
        bq = _estimate_shares(budget, bp)
        if bq >= 1:
            plan.orders.append(PlannedOrder(
                side="BUY", quantity=bq, price=bp,
                amount=round(bq * bp, 2),
                reason=f"후반전 별지점 LOC ${bp:.2f} ({bq}주, T={T:.1f})",
                ord_dvsn="34",
            ))
            for cp, cq in _crash_orders(budget, bp, bq, budget):
                plan.orders.append(PlannedOrder(
                    side="BUY", quantity=cq, price=cp,
                    amount=round(cp * cq, 2),
                    reason=f"후반전 별지점 폭락대비 LOC ${cp:.2f}",
                    ord_dvsn="34",
                ))

    plan.notes.append(
        f"별%={(N_SPLITS - 2*T):.1f}% | 별지점=${star_price(avg_cost, T):.2f} "
        f"| 매수점=${bp:.2f} | T={T:.2f}"
    )
    return plan


# ─────────────────────────────────────────
# 빠른 확인용
# ─────────────────────────────────────────

if __name__ == "__main__":
    import sys
    sys.stdout.reconfigure(encoding="utf-8")

    state = StrategyState(T=5.0, mode="normal", cycle_capital=10000)
    plan = build_v4_plan(
        current_price=25.50,
        prev_close=25.00,
        avg_price_raw=20.00,
        shares=100,
        orderable_qty=100,
        cash=5000.0,
        state=state,
    )
    print(f"Mode: {plan.mode} | T={plan.T} | 주문 {len(plan.orders)}건")
    for o in plan.orders:
        tag = {"34": "LOC", "00": "지정가", "32": "MOC"}.get(o.ord_dvsn, o.ord_dvsn)
        print(f"  {'🟢' if o.side=='BUY' else '🔴'} {o.side} {o.quantity}주 @${o.price:.2f} | {tag} | {o.reason}")
    for n in plan.notes:
        print(f"  ℹ️  {n}")
