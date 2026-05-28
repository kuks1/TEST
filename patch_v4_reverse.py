"""
Flask 서버 V4 리버스모드 패치
1. strategy_engine.py  - compute_mm_v4_orders 리버스 모드 로직 추가
2. api_server.py       - 리버스 종료 조건 star_base 파라미터화
"""
import re
from pathlib import Path

BASE = Path('/home/ubuntu/trading-api')

# ─────────────────────────────────────────────────────────────
# 1. strategy_engine.py
# ─────────────────────────────────────────────────────────────
se_path = BASE / 'strategy_engine.py'
se = se_path.read_text(encoding='utf-8')

OLD_V4 = (
    '# ── MM V4 ─────────────────────────────────────────────────────\n'
    'def compute_mm_v4_orders(s, holding, price):\n'
    '    """\n'
    '    KR: ord_dvsn=\'kr_loc\' → 15:29:30에 예상종가 조건 체크 후 시장가\n'
    '    US: ord_dvsn=\'32\'     → 실제 LOC 주문\n'
    '    Returns list of {side, ticker, quantity, price, ord_dvsn}.\n'
    '    """\n'
    '    t_val      = float(s.get(\'t_value\') or 0)\n'
    '    calc_cap   = float(s.get(\'calc_capital\') or s.get(\'capital\', 0))\n'
    '    divisions  = int(s.get(\'divisions\') or 40)\n'
    '    star_base  = float(s.get(\'star_base\') or 20)\n'
    '    star_coeff = float(s.get(\'star_coeff\') or 2.0)\n'
    '    avg_price  = float(holding.get(\'avg_price\', 0) if holding else 0)\n'
    '    shares     = float(holding.get(\'shares\', 0) if holding else 0)\n'
    '    ticker     = s[\'symbol\']\n'
    '    is_kr      = s.get(\'market\', \'US\') == \'KR\'\n'
    '    tick       = 1.0 if is_kr else 0.01\n'
    '    loc_dvsn   = \'kr_loc\' if is_kr else \'32\'\n'
    '\n'
    '    if divisions <= 0 or calc_cap <= 0 or price <= 0:\n'
    '        return []\n'
    '\n'
    '    div_amt  = calc_cap / divisions\n'
    '    star_pct = (star_base - star_coeff * t_val) / 100.0\n'
    '    star_px  = avg_price * (1.0 + star_pct) if avg_price > 0 else 0.0\n'
    '    buy_pt   = star_px - tick if star_px > 0 else 0.0\n'
    '\n'
    '    is_reverse   = t_val >= star_base - 1\n'
    '    is_rear_half = (not is_reverse) and (t_val >= star_base * 0.5)\n'
    '    use_px       = buy_pt if buy_pt > 0 else price\n'
    '\n'
    '    orders = []\n'
    '\n'
    '    if not is_reverse:\n'
    '        if not is_rear_half:\n'
    '            # 전반전: 0.5포션 × buy_pt + 0.5포션 × avg\n'
    '            half = div_amt * 0.5\n'
    '            bq1  = max(int(half / use_px), 1) if use_px > 0 else 0\n'
    '            bq2  = max(int(half / avg_price), 1) if avg_price > 0 else 0\n'
    '            if bq1 > 0:\n'
    '                orders.append({\'side\': \'BUY\', \'ticker\': ticker,\n'
    '                                \'quantity\': bq1,\n'
    '                                \'price\': round(buy_pt) if is_kr else round(buy_pt, 2),\n'
    '                                \'ord_dvsn\': loc_dvsn})\n'
    '            if bq2 > 0 and avg_price > 0:\n'
    '                orders.append({\'side\': \'BUY\', \'ticker\': ticker,\n'
    '                                \'quantity\': bq2,\n'
    '                                \'price\': round(avg_price) if is_kr else round(avg_price, 2),\n'
    '                                \'ord_dvsn\': loc_dvsn})\n'
    '        else:\n'
    '            # 후반전: 1포션 × buy_pt\n'
    '            rq = max(int(div_amt / use_px), 1) if use_px > 0 else 0\n'
    '            if rq > 0:\n'
    '                orders.append({\'side\': \'BUY\', \'ticker\': ticker,\n'
    '                                \'quantity\': rq,\n'
    '                                \'price\': round(buy_pt) if is_kr else round(buy_pt, 2),\n'
    '                                \'ord_dvsn\': loc_dvsn})\n'
    '\n'
    '    # 매도 (보유 시)\n'
    '    if shares > 0 and avg_price > 0 and star_px > 0:\n'
    '        sell_q = max(int(shares * 0.25), 1)\n'
    '        rest_q = max(int(shares) - sell_q, 0)\n'
    '        orders.append({\'side\': \'SELL\', \'ticker\': ticker,\n'
    '                        \'quantity\': sell_q,\n'
    '                        \'price\': round(star_px) if is_kr else round(star_px, 2),\n'
    '                        \'ord_dvsn\': loc_dvsn})\n'
    '        if rest_q > 0:\n'
    '            final_px = avg_price * 1.20\n'
    '            orders.append({\'side\': \'SELL\', \'ticker\': ticker,\n'
    '                            \'quantity\': rest_q,\n'
    '                            \'price\': round(final_px) if is_kr else round(final_px, 2),\n'
    '                            \'ord_dvsn\': \'00\'})\n'
    '\n'
    '    return orders'
)

NEW_V4 = (
    '# ── MM V4 ─────────────────────────────────────────────────────\n'
    'def compute_mm_v4_orders(s, holding, price):\n'
    '    """\n'
    '    KR: ord_dvsn=\'kr_loc\' → 15:29:30에 예상종가 조건 체크 후 시장가\n'
    '    US: ord_dvsn=\'32\'     → 실제 LOC 주문\n'
    '    리버스 모드: mm_mode=\'reverse\', mm_reverse_day, mm_close_history 사용\n'
    '    Returns list of {side, ticker, quantity, price, ord_dvsn}.\n'
    '    """\n'
    '    t_val       = float(s.get(\'t_value\') or 0)\n'
    '    calc_cap    = float(s.get(\'calc_capital\') or s.get(\'capital\', 0))\n'
    '    divisions   = int(s.get(\'divisions\') or 40)\n'
    '    star_base   = float(s.get(\'star_base\') or 20)\n'
    '    star_coeff  = float(s.get(\'star_coeff\') or 2.0)\n'
    '    avg_price   = float(holding.get(\'avg_price\', 0) if holding else 0)\n'
    '    shares      = float(holding.get(\'shares\', 0) if holding else 0)\n'
    '    cash        = float(holding.get(\'cash_available\', 0) if holding else 0)\n'
    '    ticker      = s[\'symbol\']\n'
    '    is_kr       = s.get(\'market\', \'US\') == \'KR\'\n'
    '    tick        = 1.0 if is_kr else 0.01\n'
    '    loc_dvsn    = \'kr_loc\' if is_kr else \'32\'\n'
    '\n'
    '    mm_mode     = s.get(\'mm_mode\', \'normal\')\n'
    '    reverse_day = int(s.get(\'mm_reverse_day\', 0) or 0)\n'
    '    close_hist  = list(s.get(\'mm_close_history\', []) or [])\n'
    '\n'
    '    if divisions <= 0 or calc_cap <= 0 or price <= 0:\n'
    '        return []\n'
    '\n'
    '    div_amt  = calc_cap / divisions\n'
    '    star_pct = (star_base - star_coeff * t_val) / 100.0\n'
    '    star_px  = avg_price * (1.0 + star_pct) if avg_price > 0 else 0.0\n'
    '    buy_pt   = star_px - tick if star_px > 0 else 0.0\n'
    '\n'
    '    is_reverse   = mm_mode == \'reverse\'\n'
    '    is_rear_half = (not is_reverse) and (t_val >= star_base * 0.5)\n'
    '    use_px       = buy_pt if buy_pt > 0 else price\n'
    '\n'
    '    orders = []\n'
    '\n'
    '    if is_reverse:\n'
    '        # ── 리버스 모드 ──────────────────────────────────────────\n'
    '        sell_qty = max(int(shares * 2.0 / divisions), 1) if shares > 0 else 0\n'
    '        recent   = close_hist[-5:] if close_hist else [price]\n'
    '        ma5      = sum(recent) / len(recent)\n'
    '\n'
    '        if reverse_day <= 1:\n'
    '            # 1일차: MOC 시장가 매도만\n'
    '            if sell_qty > 0:\n'
    '                orders.append({\'side\': \'SELL\', \'ticker\': ticker,\n'
    '                                \'quantity\': sell_qty, \'price\': 0, \'ord_dvsn\': \'01\'})\n'
    '        else:\n'
    '            # 2일차+: LOC 매도 @5MA + LOC 매수 @(5MA-tick)\n'
    '            if sell_qty > 0:\n'
    '                orders.append({\'side\': \'SELL\', \'ticker\': ticker,\n'
    '                                \'quantity\': sell_qty,\n'
    '                                \'price\': round(ma5) if is_kr else round(ma5, 2),\n'
    '                                \'ord_dvsn\': loc_dvsn})\n'
    '            buy_px   = ma5 - tick\n'
    '            buy_cash = cash / 4.0\n'
    '            if buy_px > 0 and buy_cash > 0:\n'
    '                buy_qty = max(int(buy_cash / buy_px), 1)\n'
    '                orders.append({\'side\': \'BUY\', \'ticker\': ticker,\n'
    '                                \'quantity\': buy_qty,\n'
    '                                \'price\': round(buy_px) if is_kr else round(buy_px, 2),\n'
    '                                \'ord_dvsn\': loc_dvsn})\n'
    '    else:\n'
    '        # ── 일반 모드 ────────────────────────────────────────────\n'
    '        if not is_rear_half:\n'
    '            # 전반전: 0.5포션 × buy_pt + 0.5포션 × avg\n'
    '            half = div_amt * 0.5\n'
    '            bq1  = max(int(half / use_px), 1) if use_px > 0 else 0\n'
    '            bq2  = max(int(half / avg_price), 1) if avg_price > 0 else 0\n'
    '            if bq1 > 0:\n'
    '                orders.append({\'side\': \'BUY\', \'ticker\': ticker,\n'
    '                                \'quantity\': bq1,\n'
    '                                \'price\': round(buy_pt) if is_kr else round(buy_pt, 2),\n'
    '                                \'ord_dvsn\': loc_dvsn})\n'
    '            if bq2 > 0 and avg_price > 0:\n'
    '                orders.append({\'side\': \'BUY\', \'ticker\': ticker,\n'
    '                                \'quantity\': bq2,\n'
    '                                \'price\': round(avg_price) if is_kr else round(avg_price, 2),\n'
    '                                \'ord_dvsn\': loc_dvsn})\n'
    '        else:\n'
    '            # 후반전: 1포션 × buy_pt\n'
    '            rq = max(int(div_amt / use_px), 1) if use_px > 0 else 0\n'
    '            if rq > 0:\n'
    '                orders.append({\'side\': \'BUY\', \'ticker\': ticker,\n'
    '                                \'quantity\': rq,\n'
    '                                \'price\': round(buy_pt) if is_kr else round(buy_pt, 2),\n'
    '                                \'ord_dvsn\': loc_dvsn})\n'
    '\n'
    '        # 매도 (보유 시)\n'
    '        if shares > 0 and avg_price > 0 and star_px > 0:\n'
    '            sell_q = max(int(shares * 0.25), 1)\n'
    '            rest_q = max(int(shares) - sell_q, 0)\n'
    '            orders.append({\'side\': \'SELL\', \'ticker\': ticker,\n'
    '                            \'quantity\': sell_q,\n'
    '                            \'price\': round(star_px) if is_kr else round(star_px, 2),\n'
    '                            \'ord_dvsn\': loc_dvsn})\n'
    '            if rest_q > 0:\n'
    '                final_px = avg_price * 1.20\n'
    '                orders.append({\'side\': \'SELL\', \'ticker\': ticker,\n'
    '                                \'quantity\': rest_q,\n'
    '                                \'price\': round(final_px) if is_kr else round(final_px, 2),\n'
    '                                \'ord_dvsn\': \'00\'})\n'
    '\n'
    '    return orders'
)

if OLD_V4 in se:
    se2 = se.replace(OLD_V4, NEW_V4, 1)
    se_path.write_text(se2, encoding='utf-8')
    print('[1] strategy_engine.py patched OK')
else:
    print('[1] ERROR: old V4 block not found - checking snippet...')
    idx = se.find('def compute_mm_v4_orders')
    print(repr(se[idx:idx+300]))

# ─────────────────────────────────────────────────────────────
# 2. api_server.py - 리버스 종료 조건 star_base 파라미터화
# ─────────────────────────────────────────────────────────────
as_path = BASE / 'api_server.py'
asc = as_path.read_text(encoding='utf-8')

OLD_EXIT = (
    '            avg_cost_adj = avg_price / (1 - 0.0025) if avg_price > 0 else 0\n'
    '            if avg_cost_adj > 0 and price >= avg_cost_adj * 0.80:'
)
NEW_EXIT = (
    '            star_base_r  = float(s.get("star_base") or 20)\n'
    '            avg_cost_adj = avg_price / (1 - 0.0025) if avg_price > 0 else 0\n'
    '            recovery_pct = 1.0 - star_base_r / 100.0\n'
    '            if avg_cost_adj > 0 and price >= avg_cost_adj * recovery_pct:'
)

if OLD_EXIT in asc:
    asc2 = asc.replace(OLD_EXIT, NEW_EXIT, 1)
    as_path.write_text(asc2, encoding='utf-8')
    print('[2] api_server.py exit condition patched OK')
else:
    print('[2] ERROR: old exit condition not found')
    idx = asc.find('avg_cost_adj * 0.80')
    print(repr(asc[max(0,idx-100):idx+60]))

print('Done.')
