import sys, os, json, requests
from pathlib import Path
from datetime import datetime, timedelta
from dotenv import load_dotenv

load_dotenv('/home/ubuntu/trading-api/.env')
KIS_ENV = os.getenv('KIS_ENV', 'real')
BASE_URL = 'https://openapi.koreainvestment.com:9443'

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

acct = next(a for a in accounts if a['market'] == 'US')
token = json.loads(Path(f'/home/ubuntu/trading-api/token_{acct["label"]}.json').read_text())['access_token']
hdr = {'authorization': f'Bearer {token}', 'appkey': acct['app_key'],
       'appsecret': acct['app_secret'], 'tr_id': 'TTTS3035R',
       'content-type': 'application/json; charset=utf-8'}
today = datetime.today().strftime('%Y%m%d')
week_ago = (datetime.today() - timedelta(days=7)).strftime('%Y%m%d')

r = requests.get(f'{BASE_URL}/uapi/overseas-stock/v1/trading/inquire-ccnl',
    headers=hdr,
    params={'CANO': acct['cano'], 'ACNT_PRDT_CD': acct['prdt_cd'],
            'PDNO': '%', 'ORD_STRT_DT': week_ago, 'ORD_END_DT': today,
            'SLL_BUY_DVSN': '00', 'CCLD_NCCS_DVSN': '01',
            'OVRS_EXCG_CD': 'NASD', 'SORT_SQN': 'DS',
            'ORD_DT': '', 'ORD_GNO_BRNO': '', 'ODNO': '',
            'CTX_AREA_NK200': '', 'CTX_AREA_FK200': ''},
    timeout=10)
d = r.json()
print('rt_cd:', d.get('rt_cd'), 'msg:', d.get('msg1', '')[:60])
if d.get('output'):
    first = d['output'][0]
    print('ALL KEYS:', list(first.keys()))
    print('SAMPLE:')
    for k, v in first.items():
        if v and v != '0' and v != '':
            print(f'  {k}: {v}')
