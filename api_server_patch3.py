"""
Patch 3: GET/PUT /api/accounts 엔드포인트 추가
앱에서 KIS app_key / app_secret / account_no 를 원격으로 교체할 수 있게 함.
"""
from pathlib import Path

src = Path("api_server.py").read_text(encoding="utf-8")

NEW_ENDPOINTS = '''
# ── 계좌 설정 조회/수정 ─────────────────────────────────────────

@app.route('/api/accounts', methods=['GET'])
@require_auth
def get_accounts_api():
    accounts = load_accounts()
    masked = []
    for a in accounts:
        m = dict(a)
        s = m.get('app_secret', '')
        m['app_secret'] = (s[:4] + '****' + s[-4:]) if len(s) > 8 else '****'
        masked.append(m)
    return jsonify({'accounts': masked})


@app.route('/api/accounts', methods=['PUT'])
@require_auth
def update_accounts_api():
    data     = request.get_json() or {}
    updates  = data.get('accounts', [])
    accounts = load_accounts()

    for upd in updates:
        market   = upd.get('market', '').upper()
        existing = next((a for a in accounts
                         if a.get('market', '').upper() == market), None)
        if existing:
            if upd.get('app_key'):    existing['app_key']    = upd['app_key']
            if upd.get('app_secret'): existing['app_secret'] = upd['app_secret']
            if upd.get('account_no'): existing['account_no'] = upd['account_no']
        else:
            accounts.append({
                'market':     market,
                'app_key':    upd.get('app_key', ''),
                'app_secret': upd.get('app_secret', ''),
                'account_no': upd.get('account_no', ''),
            })

    import json as _json
    _ACCT_FILE.write_text(
        _json.dumps(accounts, ensure_ascii=False, indent=2), encoding='utf-8')
    return jsonify({'ok': True, 'updated': len(updates)})

'''

# /api/rebalance 앞에 삽입
ANCHOR = "@app.route('/api/rebalance'"
if ANCHOR not in src:
    ANCHOR = "if __name__ == '__main__'"

src = src.replace(ANCHOR, NEW_ENDPOINTS + ANCHOR, 1)
Path("api_server.py").write_text(src, encoding="utf-8")
print("patch3 applied")
print("accounts endpoints:", src.count("/api/accounts"))
