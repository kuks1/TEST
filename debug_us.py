import sys, os, json, requests
from pathlib import Path
from datetime import datetime, timedelta
from dotenv import load_dotenv

load_dotenv('/home/ubuntu/trading-api/.env')
KIS_ENV = os.getenv('KIS_ENV', 'real')
BASE_URL = ('https://openapi.koreainvestment.com:9443' if KIS_ENV == 'real'
            else 'https://openapivts.koreainvestment.com:29443')

accounts = []
n = 1
while True:
    cano = os.getenv(f'KIS_ACCOUNT_{n}_CANO', '').strip()
    if not cano: break
    accounts.append({'label': os.getenv(f'KIS_ACCOUNT_{n}_LABEL'),
                     'cano': cano, 'prdt_cd': os.getenv(f'KIS_ACCOUNT_{n}_PRDT_CD', '01'),
                     'market': os.getenv(f'KIS_ACCOUNT_{n}_MARKET', 'KR'),
                     'app_key': os.getenv(f'KIS_ACCOUNT_{n}_APP_KEY', ''),
                     'app_secret': os.getenv(f'KIS_ACCOUNT_{n}_APP_SECRET', '')})
    n += 1

acct = next((a for a in accounts if a['market'] == 'US'), None)
print('US acct:', acct['label'] if acct else 'NONE')

tf = Path(f'/home/ubuntu/trading-api/token_{acct["label"]}.json')
token = json.loads(tf.read_text())['access_token']

def hdr(tr_id):
    return {'authorization': f'Bearer {token}', 'appkey': acct['app_key'],
            'appsecret': acct['app_secret'], 'tr_id': tr_id,
            'content-type': 'application/json; charset=utf-8'}

today = datetime.today().strftime('%Y%m%d')
week_ago = (datetime.today() - timedelta(days=7)).strftime('%Y%m%d')

# Test 1: 미체결
print('\n--- US 미체결 (inquire-nccs) ---')
r = requests.get(f'{BASE_URL}/uapi/overseas-stock/v1/trading/inquire-nccs',
    headers=hdr('TTTS3018R'),
    params={'CANO': acct['cano'], 'ACNT_PRDT_CD': acct['prdt_cd'],
            'OVRS_EXCG_CD': 'NASD', 'SORT_SQN': 'DS',
            'CTX_AREA_FK200': '', 'CTX_AREA_NK200': ''}, timeout=10)
d = r.json()
print(f'status={r.status_code} rt_cd={d.get("rt_cd")} msg={d.get("msg1","")[:80]}')
print(f'output count={len(d.get("output",[]))}')

# Test 2: 체결내역
print('\n--- US 체결 (inquire-ccnl) ---')
r2 = requests.get(f'{BASE_URL}/uapi/overseas-stock/v1/trading/inquire-ccnl',
    headers=hdr('TTTS3035R'),
    params={'CANO': acct['cano'], 'ACNT_PRDT_CD': acct['prdt_cd'],
            'PDNO': '%', 'ORD_STRT_DT': week_ago, 'ORD_END_DT': today,
            'SLL_BUY_DVSN': '00', 'CCLD_NCCS_DVSN': '01',
            'OVRS_EXCG_CD': 'NASD', 'SORT_SQN': 'DS',
            'ORD_DT': '', 'ORD_GNO_BRNO': '', 'ODNO': '',
            'CTX_AREA_NK200': '', 'CTX_AREA_FK200': ''}, timeout=10)
d2 = r2.json()
print(f'status={r2.status_code} rt_cd={d2.get("rt_cd")} msg={d2.get("msg1","")[:80]}')
print(f'output count={len(d2.get("output",[]))}')
if d2.get('output'):
    for o in d2['output'][:3]:
        print(f'  {o.get("ovrs_pdno")} {o.get("sll_buy_dvsn_cd")} qty={o.get("ft_ccld_qty")} price={o.get("ft_ccld_unpr3")} dt={o.get("ord_dt")}')
