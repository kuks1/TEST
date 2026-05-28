"""
패치:
1. strategy_engine.py - V1 익절 LOC(지정가) 복구
2. strategy_engine.py - QT US 지원 (is_kr에 따라 ord_dvsn / price 분기)
3. api_server.py      - V1 영혼법 5분 스케줄러 추가
4. api_server.py      - QT 전략 5분 재실행 스케줄러 추가
5. api_server.py      - _run_us_open 코멘트 정리
"""
from pathlib import Path
import re

BASE = Path('/home/ubuntu/trading-api')

# ═══════════════════════════════════════════════════════════
# 1. strategy_engine.py — V1 익절 LOC 복구
# ═══════════════════════════════════════════════════════════
se_path = BASE / 'strategy_engine.py'
se = se_path.read_text(encoding='utf-8')

OLD_V1_EXIT = (
    "        if price >= target_px:\n"
    "            # 익절: 장마감 시장가(MOC) 전량 매도\n"
    "            moc_dvsn = 'kr_loc' if is_kr else '33'\n"
    "            orders.append({'side': 'SELL', 'ticker': ticker,\n"
    "                            'quantity': int(shares), 'price': 0, 'ord_dvsn': moc_dvsn})"
)
NEW_V1_EXIT = (
    "        if price >= target_px:\n"
    "            # 익절: LOC 지정가 전량 매도 (익절 목표가 = target_px)\n"
    "            orders.append({'side': 'SELL', 'ticker': ticker,\n"
    "                            'quantity': int(shares),\n"
    "                            'price': round(target_px) if is_kr else round(target_px, 2),\n"
    "                            'ord_dvsn': loc_dvsn})"
)

if OLD_V1_EXIT in se:
    se = se.replace(OLD_V1_EXIT, NEW_V1_EXIT, 1)
    print('[1] V1 익절 LOC 복구 OK')
else:
    print('[1] ERROR: old V1 익절 block not found')
    idx = se.find('익절:')
    print(repr(se[max(0,idx-30):idx+180]))

# ═══════════════════════════════════════════════════════════
# 2. strategy_engine.py — QT US 지원
# ═══════════════════════════════════════════════════════════
OLD_QT = (
    "def compute_qt_orders(s, holdings_map, prices_map):\n"
    "    capital = float(s.get('capital', 0))\n"
    "    stocks  = s.get('stocks', [])\n"
    "    orders  = []\n"
    "    for st in stocks:\n"
    "        ticker = st['ticker']\n"
    "        weight = float(st.get('weight', 0))\n"
    "        if weight <= 0:\n"
    "            continue\n"
    "        price = float(prices_map.get(ticker, 0))\n"
    "        if price <= 0:\n"
    "            continue\n"
    "        target_q  = int(capital * weight / 100.0 / price)\n"
    "        current_q = int((holdings_map.get(ticker) or {}).get('shares', 0))\n"
    "        delta = target_q - current_q\n"
    "        if delta == 0:\n"
    "            continue\n"
    "        side = 'BUY' if delta > 0 else 'SELL'\n"
    "        orders.append({'side': side, 'ticker': ticker,\n"
    "                        'quantity': abs(delta), 'price': 0, 'ord_dvsn': '01'})\n"
    "    return orders"
)
NEW_QT = (
    "def compute_qt_orders(s, holdings_map, prices_map):\n"
    "    capital = float(s.get('capital', 0))\n"
    "    stocks  = s.get('stocks', [])\n"
    "    is_kr   = s.get('market', 'KR').upper() == 'KR'\n"
    "    orders  = []\n"
    "    for st in stocks:\n"
    "        ticker = st['ticker']\n"
    "        weight = float(st.get('weight', 0))\n"
    "        if weight <= 0:\n"
    "            continue\n"
    "        price = float(prices_map.get(ticker, 0))\n"
    "        if price <= 0:\n"
    "            continue\n"
    "        target_q  = int(capital * weight / 100.0 / price)\n"
    "        current_q = int((holdings_map.get(ticker) or {}).get('shares', 0))\n"
    "        delta = target_q - current_q\n"
    "        if delta == 0:\n"
    "            continue\n"
    "        side = 'BUY' if delta > 0 else 'SELL'\n"
    "        # KR: 시장가('01') price=0 / US: 지정가('00') price=현재가\n"
    "        if is_kr:\n"
    "            orders.append({'side': side, 'ticker': ticker,\n"
    "                            'quantity': abs(delta), 'price': 0, 'ord_dvsn': '01'})\n"
    "        else:\n"
    "            orders.append({'side': side, 'ticker': ticker,\n"
    "                            'quantity': abs(delta),\n"
    "                            'price': round(price, 2), 'ord_dvsn': '00'})\n"
    "    return orders"
)

if OLD_QT in se:
    se = se.replace(OLD_QT, NEW_QT, 1)
    print('[2] QT US 지원 OK')
else:
    print('[2] ERROR: old QT block not found')
    idx = se.find('compute_qt_orders')
    print(repr(se[idx:idx+400]))

se_path.write_text(se, encoding='utf-8')
import ast; ast.parse(se); print('strategy_engine.py syntax OK')

# ═══════════════════════════════════════════════════════════
# 3+4+5. api_server.py — V1 영혼법 + QT 5분 스케줄러
# ═══════════════════════════════════════════════════════════
as_path = BASE / 'api_server.py'
asc = as_path.read_text(encoding='utf-8')

# ── 3. V1 영혼법 함수 + QT 5분 재실행 함수 삽입 ─────────────
# _run_us_open 함수 뒤에 삽입
INSERT_AFTER = 'scheduler = BackgroundScheduler(timezone="Asia/Seoul")'
NEW_FUNCS = '''
def _run_v1_soul():
    """매 5분: V1 영혼법 — 원금 소진 전략 현재가 모니터링 후 시장가 매도"""
    from datetime import time as dt_time
    now = datetime.now()
    if now.weekday() >= 5:
        return  # 주말 제외
    t = now.time()
    kr_open = dt_time(9, 0) <= t <= dt_time(15, 30)
    us_open = t >= dt_time(22, 30) or t <= dt_time(5, 0)
    if not (kr_open or us_open):
        return

    strategies = _load_strategies()
    for s in strategies:
        if not s.get("active", True):
            continue
        if s.get("type") != "v1":
            continue

        market     = s.get("market", "KR").upper()
        if market == "KR" and not kr_open:
            continue
        if market == "US" and not us_open:
            continue

        ticker     = s.get("symbol", "")
        calc_cap   = float(s.get("calc_capital") or s.get("capital", 0))
        profit_pct = float(s.get("v1_value") or 5.0)
        stop_pct   = float(s.get("v1_salsa_sl_pct") or 0)

        accounts = load_accounts()
        acct     = next((a for a in accounts if a["market"] == market), None)
        if not acct:
            continue

        holding   = _get_holding(accounts, market, ticker)
        if not holding:
            continue
        shares    = float(holding.get("shares", 0))
        avg_price = float(holding.get("avg_price", 0))
        if shares <= 0 or avg_price <= 0:
            continue

        # 원금 소진 확인 (보유 매입원가 >= 전략자본 95%)
        invested = shares * avg_price
        if invested < calc_cap * 0.95:
            continue  # 아직 소진 안됨 → 영혼법 대상 아님

        price = _get_price(acct, ticker, market)
        if price <= 0:
            continue

        target_px = avg_price * (1.0 + profit_pct / 100.0)
        sid       = s.get("strategy_id", "?")

        # 익절 조건
        if price >= target_px:
            # KR: 시장가('01') / US: 현재가 지정가('00')
            dvsn = "01" if market == "KR" else "00"
            sell_px = 0 if market == "KR" else price
            res = _place_order_internal(acct, market, "SELL",
                                        ticker, int(shares), sell_px, dvsn)
            print(f"[V1 영혼법 익절] {sid}: {int(shares)}주 @{price:.2f} → {res}")
            continue

        # 손절 조건 (v1_salsa_sl_pct > 0 일 때만)
        if stop_pct > 0:
            stop_px = avg_price * (1.0 - stop_pct / 100.0)
            if price <= stop_px:
                dvsn = "01" if market == "KR" else "00"
                sell_px = 0 if market == "KR" else price
                res = _place_order_internal(acct, market, "SELL",
                                            ticker, int(shares), sell_px, dvsn)
                print(f"[V1 영혼법 손절] {sid}: {int(shares)}주 @{price:.2f} → {res}")


def _run_qt_recheck():
    """매 5분: QT 전략 계획수량 재확인 — 미체결 주문 후 보유량 갱신에 따른 재주문"""
    from datetime import time as dt_time
    now = datetime.now()
    if now.weekday() >= 5:
        return
    t = now.time()
    kr_open = dt_time(9, 0) <= t <= dt_time(15, 30)
    us_open = t >= dt_time(22, 30) or t <= dt_time(5, 0)
    if not (kr_open or us_open):
        return

    strategies = _load_strategies()
    targets = [s for s in strategies
               if s.get("active", True) and s.get("type") == "kr_value"]
    for s in targets:
        market = s.get("market", "KR").upper()
        if market == "KR" and not kr_open:
            continue
        if market == "US" and not us_open:
            continue
        sid = s.get("strategy_id", "?")
        try:
            result = _execute_strategy(sid, kr_loc_mode=False)
            cnt = result.get("orders_count", 0)
            if cnt > 0:
                print(f"[QT 재확인] {sid}: {cnt}건 추가 주문")
        except Exception as e:
            print(f"[QT 재확인] {sid} 오류: {e}")


''' + INSERT_AFTER

if INSERT_AFTER in asc:
    asc = asc.replace(INSERT_AFTER, NEW_FUNCS, 1)
    print('[3+4] V1 영혼법 + QT 재확인 함수 삽입 OK')
else:
    print('[3+4] ERROR: scheduler 기준점 not found')

# ── 5. 스케줄러 잡 추가 ────────────────────────────────────
OLD_SCHED = (
    '# US 장시작 30분 전 (22:30 KST = 08:30 ET)\n'
    'scheduler.add_job(_run_us_open, "cron",\n'
    '                  day_of_week="mon-fri", hour=22, minute=30, second=0,\n'
    '                  id="us_open")'
)
NEW_SCHED = (
    '# US 장시작 (22:30 KST = 09:30 ET)\n'
    'scheduler.add_job(_run_us_open, "cron",\n'
    '                  day_of_week="mon-fri", hour=22, minute=30, second=0,\n'
    '                  id="us_open")\n'
    '# V1 영혼법: 5분마다 (함수 내부에서 장시간 체크)\n'
    'scheduler.add_job(_run_v1_soul, "interval", minutes=5,\n'
    '                  id="v1_soul", misfire_grace_time=60)\n'
    '# QT 계획수량 재확인: 5분마다 (함수 내부에서 장시간 체크)\n'
    'scheduler.add_job(_run_qt_recheck, "interval", minutes=5,\n'
    '                  id="qt_recheck", misfire_grace_time=60)'
)

if OLD_SCHED in asc:
    asc = asc.replace(OLD_SCHED, NEW_SCHED, 1)
    print('[5] 스케줄러 잡 추가 OK')
else:
    print('[5] ERROR: old scheduler block not found')
    idx = asc.find('us_open')
    print(repr(asc[max(0,idx-50):idx+150]))

as_path.write_text(asc, encoding='utf-8')
import py_compile; py_compile.compile(str(as_path), doraise=True); print('api_server.py syntax OK')
print('Done.')
