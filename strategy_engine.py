import math
from datetime import datetime, timezone, timedelta


# ── 시장 시간 ──────────────────────────────────────────────────
def _is_edt():
    utc = datetime.now(timezone.utc)
    y = utc.year
    md = 8
    while datetime(y, 3, md).weekday() != 6:  # Sunday
        md += 1
    nd = 1
    while datetime(y, 11, nd).weekday() != 6:
        nd += 1
    dst_start = datetime(y, 3, md, 7, tzinfo=timezone.utc)
    dst_end   = datetime(y, 11, nd, 6, tzinfo=timezone.utc)
    return dst_start < utc < dst_end


def is_kr_open():
    kst = datetime.now(timezone.utc) + timedelta(hours=9)
    if kst.weekday() >= 5:
        return False
    m = kst.hour * 60 + kst.minute
    return 540 <= m < 930  # 09:00~15:30


def is_us_open():
    offset = 4 if _is_edt() else 5
    et = datetime.now(timezone.utc) - timedelta(hours=offset)
    if et.weekday() >= 5:
        return False
    m = et.hour * 60 + et.minute
    return 570 <= m < 960  # 09:30~16:00


# ── VR 헬퍼 ───────────────────────────────────────────────────
def _calc_g(mode, week_no):
    if mode == '인출식':
        return 20
    if mode == '거치식':
        return 12
    return 10 + week_no // 52  # 적립식


def _calc_pool_limit(mode, week_no, override=None):
    if override is not None:
        return max(0.0, min(1.0, float(override)))
    if mode == '거치식':
        return 0.50
    if mode == '인출식':
        return 0.75
    # 적립식
    if week_no < 52:
        return 0.0
    half_years = (week_no - 52) // 26
    return max(0.0, min(1.0, 0.75 - half_years * 0.05))


def _build_buy_grid(v_min, current_shares, qty, pool_avail):
    orders = []
    if v_min <= 0 or qty <= 0 or pool_avail <= 0:
        return orders
    total_cost = 0.0
    for step in range(1, 501):
        new_shares = current_shares + step * qty
        price = v_min / new_shares
        if price <= 0:
            break
        cost = price * qty
        if total_cost + cost > pool_avail:
            break
        orders.append({'side': 'BUY', 'quantity': qty, 'price': price, 'level': step})
        total_cost += cost
    return orders


def _build_sell_grid(v_max, current_shares, qty):
    orders = []
    if v_max <= 0 or current_shares <= 0 or qty <= 0:
        return orders
    for step in range(1, 501):
        remain = current_shares - step * qty
        if remain <= 0:
            break
        price = v_max / remain
        if price <= 0:
            break
        orders.append({'side': 'SELL', 'quantity': qty, 'price': price, 'level': step})
    return orders


# ── MM V4 헬퍼 ────────────────────────────────────────────────
_COMMISSION = 0.0025


def _estimate_shares(budget: float, price: float) -> int:
    """커미션 반영 매수 가능 수량 (내림, 최소 1주)"""
    if budget <= 0 or price <= 0:
        return 0
    raw = budget * (1 - _COMMISSION) / price
    qty = int(math.floor(raw))
    return max(qty, 1) if raw > 0 else 0


def _required_cash(price: float, qty: int) -> float:
    """qty 주 매수에 필요한 현금 (커미션 포함)"""
    if price <= 0 or qty <= 0:
        return 0.0
    return price * qty / (1 - _COMMISSION)


def _floor2(v: float) -> float:
    return math.floor(v * 100) / 100


def _crash_orders(
    budget: float,
    base_price: float,
    base_qty: int,
    cash_remaining: float,
    max_drop_pct: float = 0.30,
    max_orders: int = 20,
) -> list:
    """
    폭락장 대비 추가 LOC 주문 목록.
    base_price 아래 0~30% 구간에 1주씩 분산 배치.
    반환: [(price, qty), ...]
    """
    if budget <= 0 or base_price <= 0 or base_qty <= 0:
        return []
    additional = []
    qty = base_qty + 1
    min_price = base_price * (1 - max_drop_pct)
    hard_limit = base_qty + max_orders * 5
    while len(additional) < max_orders and qty <= hard_limit:
        price = _floor2(budget * (1 - _COMMISSION) / qty)
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


def _calc_5ma(closes: list) -> float:
    if not closes:
        return 0.0
    tail = closes[-5:]
    return sum(tail) / len(tail)


# ── MM V4 ─────────────────────────────────────────────────────
def compute_mm_v4_orders(s, holding, price):
    """
    V4 무한매수법 주문 계산.

    KR: ord_dvsn='kr_loc' → 15:29:30 예상종가 조건 체크 후 시장가
    US: ord_dvsn='34'     → 실제 LOC 주문 (v4_soxl.py 동일)
        ord_dvsn='32'     → MOC (리버스 1일차 매도)
        ord_dvsn='00'     → 지정가 (최종 익절 매도)

    포션 = 잔여현금 / (divisions - T)   ← v4_soxl.py 방식
    각 주문에 'reason', 'is_crash', 'is_reverse' 필드 포함.
    """
    t_val      = float(s.get('t_value') or 0)
    calc_cap   = float(s.get('calc_capital') or s.get('capital', 0))
    divisions  = int(s.get('divisions') or 20)
    star_base  = float(s.get('star_base') or 20)
    star_coeff = float(s.get('star_coeff') or 2.0)

    # 리버스모드 상태 (서버가 strategies.json에 저장)
    mm_mode       = s.get('mm_mode', 'normal')
    reverse_day   = int(s.get('mm_reverse_day', 0) or 0)
    close_history = list(s.get('mm_close_history', []) or [])

    avg_price_raw = float(holding.get('avg_price', 0) if holding else 0)
    shares        = int(float(holding.get('shares', 0) if holding else 0))

    # 잔여 현금: holding에 cash_available가 있으면 사용, 없으면 calc_cap으로 추정
    cash = float(holding.get('cash_available', 0) if holding else 0)
    if cash <= 0:
        cost_basis = shares * avg_price_raw
        cash = max(calc_cap - cost_basis, 0.0) if calc_cap > 0 else 0.0

    # 전일종가: holding에 prev_close가 있으면 사용, 없으면 현재가
    prev_close = float(holding.get('prev_close', price) if holding else price)

    ticker   = s['symbol']
    is_kr    = s.get('market', 'US') == 'KR'
    tick     = 1.0 if is_kr else 0.01
    loc_dvsn = 'kr_loc' if is_kr else '34'

    if divisions <= 0 or price <= 0:
        return []

    # 전략 평단가 (커미션 환원, v4_soxl.py 방식)
    avg_cost  = avg_price_raw / (1 - _COMMISSION) if avg_price_raw > 0 else 0.0
    cap_price = round(prev_close * 1.10, 2) if prev_close > 0 else round(price * 1.10, 2)

    orders = []

    # ══════════════════════════════════════════
    # 리버스 모드
    # ══════════════════════════════════════════
    if mm_mode == 'reverse':
        five_ma = round(_calc_5ma(close_history) or price, 2)

        if reverse_day == 1:
            # 1일차: MOC 매도 (보유×10%, 최소 1주)
            sell_qty = max(int(math.floor(shares * 0.10)), 1) if shares > 0 else 0
            if sell_qty > 0:
                orders.append({
                    'side': 'SELL', 'ticker': ticker,
                    'quantity': sell_qty,
                    'price': round(price) if is_kr else round(price, 2),
                    'ord_dvsn': '32',
                    'reason': f'리버스 1일차 MOC 매도 ({shares}×10%={sell_qty}주)',
                    'is_crash': False, 'is_reverse': True,
                })
        else:
            # 2일차~: LOC 매도 @5MA (10%), LOC 매수 @5MA-0.01 (잔금/4)
            sell_qty = max(int(math.floor(shares * 0.10)), 1) if shares > 0 else 0
            if sell_qty > 0:
                sell_price = round(five_ma) if is_kr else round(five_ma, 2)
                orders.append({
                    'side': 'SELL', 'ticker': ticker,
                    'quantity': sell_qty,
                    'price': sell_price,
                    'ord_dvsn': loc_dvsn,
                    'reason': f'리버스 LOC 매도 @5MA ${five_ma:.2f} ({sell_qty}주)',
                    'is_crash': False, 'is_reverse': True,
                })

            buy_price = round(five_ma - tick, 2) if not is_kr else int(five_ma - tick)
            buy_qty = _estimate_shares(cash / 4, buy_price) if (cash > 0 and not is_kr) else (
                max(int(cash / 4 / buy_price), 0) if (buy_price > 0 and cash > 0) else 0
            )
            if buy_qty >= 1:
                orders.append({
                    'side': 'BUY', 'ticker': ticker,
                    'quantity': buy_qty,
                    'price': buy_price,
                    'ord_dvsn': loc_dvsn,
                    'reason': f'리버스 쿼터매수 @5MA-{tick} ${buy_price:.2f} ({buy_qty}주)',
                    'is_crash': False, 'is_reverse': True,
                })

        return orders

    # ══════════════════════════════════════════
    # 일반 모드
    # ══════════════════════════════════════════

    # T > divisions-1 이면 리버스 진입 대기 (서버가 상태 전환)
    if t_val > divisions - 1:
        return []

    # 포션 = 잔여현금 / (divisions - T)  ← v4_soxl.py 방식
    divisor = divisions - t_val
    if divisor > 0 and cash > 0:
        portion = cash / divisor
    elif calc_cap > 0 and divisions > 0:
        portion = calc_cap / divisions  # 현금 정보 없을 때 폴백
    else:
        return []

    star_pct = (star_base - star_coeff * t_val) / 100.0
    star_px  = avg_cost * (1.0 + star_pct) if avg_cost > 0 else 0.0
    buy_pt   = round(star_px - tick, 2) if star_px > 0 else 0.0

    is_rear_half = (t_val >= divisions * 0.5) and (t_val < divisions)

    # ── 첫 매수 (T=0, 미보유) ─────────────────
    if t_val == 0 and shares == 0 and calc_cap > 0:
        budget = min(portion, cash) if cash > 0 else portion
        if is_kr:
            bq = max(int(budget / cap_price), 0) if cap_price > 0 else 0
        else:
            bq = _estimate_shares(budget, cap_price)
        if bq >= 1:
            orders.append({
                'side': 'BUY', 'ticker': ticker,
                'quantity': bq,
                'price': round(cap_price) if is_kr else round(cap_price, 2),
                'ord_dvsn': loc_dvsn,
                'reason': f'첫 매수 LOC (전일종가×1.10=${cap_price:.2f})',
                'is_crash': False, 'is_reverse': False,
            })
            if not is_kr:
                cash_after = cash - _required_cash(cap_price, bq)
                for cp, cq in _crash_orders(budget, cap_price, bq, cash_after + _required_cash(cap_price, bq)):
                    orders.append({
                        'side': 'BUY', 'ticker': ticker,
                        'quantity': cq, 'price': cp,
                        'ord_dvsn': loc_dvsn,
                        'reason': f'첫 매수 폭락대비 LOC (${cp:.2f})',
                        'is_crash': True, 'is_reverse': False,
                    })
        return orders

    # ── 매도 (쿼터 LOC + 최종 지정가) ──────────
    if shares > 0 and avg_cost > 0 and star_px > 0:
        quarter_q = max(int(math.floor(shares * 0.25)), 1)
        final_q   = max(shares - quarter_q, 0)

        orders.append({
            'side': 'SELL', 'ticker': ticker,
            'quantity': quarter_q,
            'price': round(star_px) if is_kr else round(star_px, 2),
            'ord_dvsn': loc_dvsn,
            'reason': f'쿼터매도 LOC @별지점 ${star_px:.2f} ({quarter_q}주)',
            'is_crash': False, 'is_reverse': False,
        })
        if final_q > 0:
            final_px = avg_cost * 1.20
            orders.append({
                'side': 'SELL', 'ticker': ticker,
                'quantity': final_q,
                'price': round(final_px) if is_kr else round(final_px, 2),
                'ord_dvsn': '00',
                'reason': f'최종매도 지정가 @평단×1.20 ${final_px:.2f} ({final_q}주)',
                'is_crash': False, 'is_reverse': False,
            })

    # ── 매수 ─────────────────────────────────
    if cash <= 1 or avg_cost <= 0 or buy_pt <= 0:
        return orders

    if not is_rear_half:
        # 전반전: 0.5포션×별지점 LOC + 0.5포션×평단가 LOC
        sb_budget = min(portion * 0.5, cash)
        sbq = _estimate_shares(sb_budget, buy_pt) if not is_kr else max(int(sb_budget / buy_pt), 0)
        if sbq >= 1:
            orders.append({
                'side': 'BUY', 'ticker': ticker,
                'quantity': sbq,
                'price': round(buy_pt) if is_kr else buy_pt,
                'ord_dvsn': loc_dvsn,
                'reason': f'전반전 별지점 LOC ${buy_pt:.2f} ({sbq}주, T={t_val:.1f})',
                'is_crash': False, 'is_reverse': False,
            })
            if not is_kr:
                for cp, cq in _crash_orders(sb_budget, buy_pt, sbq, sb_budget):
                    orders.append({
                        'side': 'BUY', 'ticker': ticker,
                        'quantity': cq, 'price': cp,
                        'ord_dvsn': loc_dvsn,
                        'reason': f'전반전 별지점 폭락대비 LOC ${cp:.2f}',
                        'is_crash': True, 'is_reverse': False,
                    })

        rem = max(cash - _required_cash(buy_pt, sbq if sbq >= 1 else 0), 0.0)
        ab_budget = min(portion * 0.5, rem)
        abq = _estimate_shares(ab_budget, avg_cost) if not is_kr else max(int(ab_budget / avg_cost), 0)
        if abq >= 1:
            orders.append({
                'side': 'BUY', 'ticker': ticker,
                'quantity': abq,
                'price': round(avg_cost) if is_kr else round(avg_cost, 2),
                'ord_dvsn': loc_dvsn,
                'reason': f'전반전 평단가 LOC ${avg_cost:.2f} ({abq}주, T={t_val:.1f})',
                'is_crash': False, 'is_reverse': False,
            })

    else:
        # 후반전: 1포션×별지점 LOC
        budget = min(portion, cash)
        bq = _estimate_shares(budget, buy_pt) if not is_kr else max(int(budget / buy_pt), 0)
        if bq >= 1:
            orders.append({
                'side': 'BUY', 'ticker': ticker,
                'quantity': bq,
                'price': round(buy_pt) if is_kr else buy_pt,
                'ord_dvsn': loc_dvsn,
                'reason': f'후반전 별지점 LOC ${buy_pt:.2f} ({bq}주, T={t_val:.1f})',
                'is_crash': False, 'is_reverse': False,
            })
            if not is_kr:
                for cp, cq in _crash_orders(budget, buy_pt, bq, budget):
                    orders.append({
                        'side': 'BUY', 'ticker': ticker,
                        'quantity': cq, 'price': cp,
                        'ord_dvsn': loc_dvsn,
                        'reason': f'후반전 별지점 폭락대비 LOC ${cp:.2f}',
                        'is_crash': True, 'is_reverse': False,
                    })

    return orders


# ── MM V1 ─────────────────────────────────────────────────────
def compute_mm_v1_orders(s, holding, price):
    profit_pct = float(s.get('v1_value') or 5.0)
    calc_cap   = float(s.get('calc_capital') or s.get('capital', 0))
    divisions  = int(s.get('divisions') or 10)
    avg_price  = float(holding.get('avg_price', 0) if holding else 0)
    shares     = float(holding.get('shares', 0) if holding else 0)
    ticker     = s['symbol']
    is_kr      = s.get('market', 'US') == 'KR'
    tick       = 1.0 if is_kr else 0.01
    loc_dvsn   = 'kr_loc' if is_kr else '32'

    if divisions <= 0 or calc_cap <= 0 or price <= 0:
        return []

    div_amt = calc_cap / divisions
    orders  = []

    if shares > 0 and avg_price > 0:
        target_px = avg_price * (1.0 + profit_pct / 100.0)
        if price >= target_px:
            # 익절: 시장가 전량 매도
            orders.append({'side': 'SELL', 'ticker': ticker,
                            'quantity': int(shares), 'price': 0, 'ord_dvsn': '01'})
        else:
            # 후속 분할매수 LOC
            half   = div_amt * 0.5
            bq1    = max(int(half / avg_price), 1) if avg_price > 0 else 0
            cap_px = avg_price - tick
            bq2    = max(int(half / cap_px), 1) if cap_px > 0 else 0
            if bq1 > 0:
                orders.append({'side': 'BUY', 'ticker': ticker,
                                'quantity': bq1,
                                'price': round(avg_price) if is_kr else round(avg_price, 2),
                                'ord_dvsn': loc_dvsn})
            if bq2 > 0:
                orders.append({'side': 'BUY', 'ticker': ticker,
                                'quantity': bq2,
                                'price': round(cap_px) if is_kr else round(cap_px, 2),
                                'ord_dvsn': loc_dvsn})
    else:
        # 미보유: 신규 매수
        qty = max(int(div_amt / price), 1)
        orders.append({'side': 'BUY', 'ticker': ticker,
                        'quantity': qty,
                        'price': round(price) if is_kr else round(price, 2),
                        'ord_dvsn': loc_dvsn})

    return orders


# ── VR ────────────────────────────────────────────────────────
def compute_vr_orders(s, holding, price):
    t_val       = float(s.get('t_value') or 0)
    capital     = float(s.get('capital', 0))
    mode        = s.get('vr_mode') or '적립식'
    band        = float(s.get('vr_band') or 0.15)
    vr_g        = s.get('vr_g')
    vr_pool_pct = s.get('vr_pool_pct')
    deposit     = float(s.get('vr_deposit') or 250.0)
    withdrawal  = float(s.get('vr_withdrawal') or 0.0)
    qty_step    = int(s.get('vr_qty_per_step') or 1)
    created_str = s.get('created_at', '')
    ticker      = s['symbol']
    is_kr       = s.get('market', 'US') == 'KR'

    avg_price = float(holding.get('avg_price', 0) if holding else 0)
    shares    = int(holding.get('shares', 0) if holding else 0)

    if price <= 0 or capital <= 0:
        return []

    # 첫 사이클
    if t_val == 0:
        qty = int(capital / price)
        if qty <= 0:
            return []
        return [{'side': 'BUY', 'ticker': ticker,
                  'quantity': qty, 'price': 0, 'ord_dvsn': '01'}]

    # 이후 사이클
    try:
        created = datetime.fromisoformat(created_str.replace(' ', 'T'))
    except Exception:
        created = datetime.now()
    week_no = (datetime.now() - created).days // 7

    equity     = shares * price
    pool       = max(0.0, capital - shares * avg_price)
    g_val      = float(vr_g) if vr_g and int(vr_g) > 0 else float(_calc_g(mode, week_no))
    pool_limit = _calc_pool_limit(mode, week_no, vr_pool_pct)

    cf = deposit if mode == '적립식' else (-abs(withdrawal) if mode == '인출식' else 0.0)
    v2 = t_val + (pool / g_val) + (equity - t_val) / (2.0 * math.sqrt(g_val)) + cf

    v_min      = v2 * (1.0 - band)
    v_max      = v2 * (1.0 + band)
    pool_avail = pool * pool_limit

    buy_raw  = _build_buy_grid(v_min, shares, qty_step, pool_avail)
    sell_raw = _build_sell_grid(v_max, shares, qty_step)

    def fmt_px(p):
        return round(p) if is_kr else round(p, 2)

    orders = []
    for o in buy_raw:
        px = fmt_px(o['price'])
        if px > 0:
            orders.append({'side': 'BUY', 'ticker': ticker,
                            'quantity': o['quantity'], 'price': px, 'ord_dvsn': '00'})
    for o in sell_raw:
        px = fmt_px(o['price'])
        if px > 0:
            orders.append({'side': 'SELL', 'ticker': ticker,
                            'quantity': o['quantity'], 'price': px, 'ord_dvsn': '00'})
    return orders


# ── QT KR ─────────────────────────────────────────────────────
def compute_qt_orders(s, holdings_map, prices_map):
    capital = float(s.get('capital', 0))
    stocks  = s.get('stocks', [])
    orders  = []
    for st in stocks:
        ticker = st['ticker']
        weight = float(st.get('weight', 0))
        if weight <= 0:
            continue
        price = float(prices_map.get(ticker, 0))
        if price <= 0:
            continue
        target_q  = int(capital * weight / 100.0 / price)
        current_q = int((holdings_map.get(ticker) or {}).get('shares', 0))
        delta = target_q - current_q
        if delta == 0:
            continue
        side = 'BUY' if delta > 0 else 'SELL'
        orders.append({'side': side, 'ticker': ticker,
                        'quantity': abs(delta), 'price': 0, 'ord_dvsn': '01'})
    return orders
