"""
ord_dvsn 코드 수정 패치
- loc_dvsn: '32'(LOO) → '34'(LOC)
- 리버스 1일차 MOC SELL: '01' → '33'(US MOC) / 'kr_loc'(KR)
"""
from pathlib import Path

se_path = Path('/home/ubuntu/trading-api/strategy_engine.py')
se = se_path.read_text(encoding='utf-8')

# ── Fix 1: LOO('32') → LOC('34') ─────────────────────────────
OLD1 = "    loc_dvsn    = 'kr_loc' if is_kr else '32'"
NEW1 = "    loc_dvsn    = 'kr_loc' if is_kr else '34'  # LOC(장마감지정가)"

if OLD1 in se:
    se = se.replace(OLD1, NEW1, 1)
    print('[1] loc_dvsn 32→34 OK')
else:
    print('[1] ERROR: old loc_dvsn line not found')
    idx = se.find("loc_dvsn")
    print(repr(se[idx:idx+80]))

# ── Fix 2: MOC 리버스 1일차 ord_dvsn ─────────────────────────
OLD2 = (
    "        if reverse_day <= 1:\n"
    "            # 1일차: MOC 시장가 매도만\n"
    "            if sell_qty > 0:\n"
    "                orders.append({'side': 'SELL', 'ticker': ticker,\n"
    "                                'quantity': sell_qty, 'price': 0, 'ord_dvsn': '01'})"
)
NEW2 = (
    "        if reverse_day <= 1:\n"
    "            # 1일차: 장마감 시장가 매도 (US: MOC='33', KR: kr_loc price=0)\n"
    "            if sell_qty > 0:\n"
    "                moc_dvsn = 'kr_loc' if is_kr else '33'\n"
    "                orders.append({'side': 'SELL', 'ticker': ticker,\n"
    "                                'quantity': sell_qty, 'price': 0, 'ord_dvsn': moc_dvsn})"
)

if OLD2 in se:
    se = se.replace(OLD2, NEW2, 1)
    print('[2] MOC ord_dvsn fix OK')
else:
    print('[2] ERROR: old MOC block not found')
    idx = se.find("reverse_day <= 1")
    print(repr(se[idx:idx+200]))

se_path.write_text(se, encoding='utf-8')

# ── 검증 ─────────────────────────────────────────────────────
import ast
ast.parse(se)
print('syntax OK')

# ── 동작 확인 ─────────────────────────────────────────────────
import sys
sys.path.insert(0, '/home/ubuntu/trading-api')
import importlib
import strategy_engine as eng
importlib.reload(eng)

base = {'symbol':'SOXL','market':'US','t_value':5,'calc_capital':10000,'divisions':20,
        'star_base':20,'star_coeff':2.0,'mm_mode':'normal','mm_reverse_day':0,'mm_close_history':[]}
h = {'avg_price':25.0,'shares':100,'cash_available':5000}

# 일반 모드 → loc_dvsn이 '34'인지
orders = eng.compute_mm_v4_orders(base, h, 22.0)
loc_dvsns = {o['ord_dvsn'] for o in orders if o['ord_dvsn'] not in ('00','kr_loc')}
print(f'일반모드 US loc_dvsn = {loc_dvsns}  (expect {{\"34\"}})')

# 리버스 1일차 → ord_dvsn '33'
s_r1 = dict(base, mm_mode='reverse', mm_reverse_day=1, mm_close_history=[22,23,21,22,23])
o1 = eng.compute_mm_v4_orders(s_r1, h, 22.0)
print(f'리버스 1일차 = {[(o["side"],o["price"],o["ord_dvsn"]) for o in o1]}  (expect SELL/0/33)')

# 리버스 2일차 → ord_dvsn '34'
s_r2 = dict(base, mm_mode='reverse', mm_reverse_day=2, mm_close_history=[22,23,21,22,23])
o2 = eng.compute_mm_v4_orders(s_r2, h, 22.0)
print(f'리버스 2일차 = {[(o["side"],o["price"],o["ord_dvsn"]) for o in o2]}  (expect SELL/ma5/34 + BUY/ma5-/34)')

# KR 리버스 1일차 → kr_loc
s_kr = dict(base, market='KR', mm_mode='reverse', mm_reverse_day=1, mm_close_history=[22000])
o_kr = eng.compute_mm_v4_orders(s_kr, h, 22000.0)
print(f'KR 리버스 1일차 = {[(o["side"],o["price"],o["ord_dvsn"]) for o in o_kr]}  (expect SELL/0/kr_loc)')
