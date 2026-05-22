"""
Patch script: modifies api_server.py in-place.
Run once from /home/ubuntu/trading-api/
"""
import re
from pathlib import Path

src = Path("api_server.py").read_text(encoding="utf-8")

# ── 1. 새 import 삽입 (기존 import 뒤) ────────────────────────
NEW_IMPORTS = """import threading
from apscheduler.schedulers.background import BackgroundScheduler
from strategy_engine import (
    compute_mm_v4_orders, compute_mm_v1_orders,
    compute_vr_orders, compute_qt_orders,
    is_kr_open, is_us_open,
)
"""
src = src.replace(
    "from flask_cors import CORS\n",
    "from flask_cors import CORS\n" + NEW_IMPORTS,
)

# ── 2. 전략 저장소 코드 삽입 (CORS 설정 직후) ─────────────────
STRATEGY_STORE = '''
# ─────────────────────────────────────────────────────────────
# 전략 저장소  strategies.json
# ─────────────────────────────────────────────────────────────
_STRAT_FILE = _BASE / "strategies.json"
_LOG_FILE   = _BASE / "execution_logs.json"
_strat_lock = threading.Lock()
_log_lock   = threading.Lock()


def _load_strategies():
    with _strat_lock:
        if not _STRAT_FILE.exists():
            return []
        try:
            return json.loads(_STRAT_FILE.read_text(encoding="utf-8"))
        except Exception:
            return []


def _save_strategies(strategies):
    with _strat_lock:
        _STRAT_FILE.write_text(
            json.dumps(strategies, ensure_ascii=False, indent=2), encoding="utf-8"
        )


def _append_log(entry):
    with _log_lock:
        logs = []
        if _LOG_FILE.exists():
            try:
                logs = json.loads(_LOG_FILE.read_text(encoding="utf-8"))
            except Exception:
                logs = []
        logs.insert(0, entry)
        _LOG_FILE.write_text(
            json.dumps(logs[:500], ensure_ascii=False, indent=2), encoding="utf-8"
        )

'''

src = src.replace(
    'CORS(app, origins=["https://mybotcontrol.duckdns.org"])\n',
    'CORS(app, origins=["https://mybotcontrol.duckdns.org"])\n' + STRATEGY_STORE,
)

# ── 3. 구식 /api/rebalance 대체 ───────────────────────────────
OLD_REBALANCE_START = '@app.route("/api/rebalance", methods=["POST"])'
OLD_REBALANCE_END   = '        return jsonify({"error": str(e)}), 500\n\n\n# ─────────────────────────────────────────────────────────────\n# POST 헬퍼 + 날짜 헬퍼'

NEW_REBALANCE = '''@app.route("/api/rebalance", methods=["POST"])
def rebalance():
    err = check_auth()
    if err:
        return err
    data        = request.json or {}
    strategy_id = data.get("strategy_id", "").strip()
    dry_run     = bool(data.get("dry_run", False))

    if strategy_id:
        result = _execute_strategy(strategy_id, dry_run=dry_run)
        if "error" in result:
            return jsonify(result), 400
        return jsonify(result)

    # 하위 호환: stocks + total_capital 직접 전달 (QT 수동 호출)
    stocks        = data.get("stocks", [])
    total_capital = float(data.get("total_capital", 0))
    if not stocks or total_capital <= 0:
        return jsonify({"error": "strategy_id 또는 stocks/total_capital 필요"}), 400

    try:
        accounts = load_accounts()
        acct = next((a for a in accounts if a["market"] == "KR"), accounts[0])
        token = get_token(acct)
        orders_executed = 0
        results = []
        for s in stocks:
            ticker   = s.get("ticker", "")
            weight   = float(s.get("weight", 0))
            cur_shares = int(s.get("shares", 0))
            if not ticker or weight <= 0:
                continue
            url = f"{BASE_URL}/uapi/domestic-stock/v1/quotations/inquire-price"
            headers = {"Authorization": f"Bearer {token}", "appkey": acct["app_key"],
                       "appsecret": acct["app_secret"], "tr_id": "FHKST01010100"}
            params = {"FID_COND_MRKT_DIV_CODE": "J", "FID_INPUT_ISCD": ticker}
            r = requests.get(url, headers=headers, params=params, timeout=5)
            price = float(r.json().get("output", {}).get("stck_prpr", 0) or 0)
            if price <= 0:
                results.append({"ticker": ticker, "error": "가격 조회 실패"})
                continue
            target_shares = int((total_capital * weight) / price)
            delta = target_shares - cur_shares
            if delta == 0:
                results.append({"ticker": ticker, "action": "no_change"})
                continue
            side = "BUY" if delta > 0 else "SELL"
            qty  = abs(delta)
            if not dry_run:
                tr_id = "TTTC0802U" if side == "BUY" else "TTTC0801U"
                or_ = _post(acct, "/uapi/domestic-stock/v1/trading/order-cash", tr_id,
                    {"CANO": acct["cano"], "ACNT_PRDT_CD": acct["prdt_cd"],
                     "PDNO": ticker, "ORD_DVSN": "01", "ORD_QTY": str(qty), "ORD_UNPR": "0"})
                results.append({"ticker": ticker, "action": side, "qty": qty,
                                 "status": or_.get("rt_cd")})
            else:
                results.append({"ticker": ticker, "action": side, "qty": qty, "dry_run": True})
            orders_executed += 1
        return jsonify({"orders_executed": orders_executed, "results": results})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ─────────────────────────────────────────────────────────────
# POST 헬퍼 + 날짜 헬퍼'''

src = src.replace(
    OLD_REBALANCE_START + "\ndef rebalance():",
    NEW_REBALANCE.split("\n# ─────────────────────────────────────────────────────────────\n# POST 헬퍼 + 날짜 헬퍼")[0],
)
# 더 안전하게: 전체 구간 대체
import re as _re
pattern = r'@app\.route\("/api/rebalance".*?(?=\n# ─{20,}\n# POST 헬퍼)'
replacement = NEW_REBALANCE.split("\n# ─────────────────────────────────────────────────────────────\n# POST 헬퍼 + 날짜 헬퍼")[0]
src = _re.sub(pattern, replacement, src, flags=_re.DOTALL)


# ── 4. 새 엔드포인트 + 스케줄러 삽입 (/api/orders 이전) ────────
NEW_ENDPOINTS = '''

# ─────────────────────────────────────────────────────────────
# 전략 실행 엔진 (내부)
# ─────────────────────────────────────────────────────────────

def _get_holding(accounts, market, ticker):
    key = "KR" if market == "KR" else "US"
    for acc in accounts:
        if acc.get("market") == key:
            try:
                bal = fetch_kr_balance(acc) if key == "KR" else fetch_us_balance(acc)
                for h in bal.get("holdings", []):
                    if h["ticker"] == ticker:
                        return h
            except Exception:
                pass
    return None


def _get_price(acct, ticker, market):
    try:
        if market == "KR":
            d = _get(acct, "/uapi/domestic-stock/v1/quotations/inquire-price",
                     "FHKST01010100",
                     {"FID_COND_MRKT_DIV_CODE": "J", "FID_INPUT_ISCD": ticker})
            return float(d.get("output", {}).get("stck_prpr", 0) or 0)
        else:
            d = _get(acct, "/uapi/overseas-price/v1/quotations/price",
                     "HHDFS00000300",
                     {"AUTH": "", "EXCD": "NAS", "SYMB": ticker})
            return float(d.get("output", {}).get("last", 0) or 0)
    except Exception:
        return 0.0


def _place_order_internal(acct, market, side, ticker, qty, price, ord_dvsn, dry_run=False):
    if dry_run:
        return {"dry_run": True, "side": side, "ticker": ticker,
                "qty": qty, "price": price, "ord_dvsn": ord_dvsn}
    try:
        if market == "KR":
            tr_id = "TTTC0802U" if side == "BUY" and KIS_ENV == "real" else \\
                    "VTTC0802U" if side == "BUY" else \\
                    "TTTC0801U" if KIS_ENV == "real" else "VTTC0801U"
            res = _post(acct, "/uapi/domestic-stock/v1/trading/order-cash", tr_id,
                {"CANO": acct["cano"], "ACNT_PRDT_CD": acct["prdt_cd"],
                 "PDNO": ticker, "ORD_DVSN": ord_dvsn,
                 "ORD_QTY": str(qty), "ORD_UNPR": str(int(price))})
        else:
            tr_id = "TTTS0308U" if side == "BUY" and KIS_ENV == "real" else \\
                    "VTTS0308U" if side == "BUY" else \\
                    "TTTS0307U" if KIS_ENV == "real" else "VTTS0307U"
            res = _post(acct, "/uapi/overseas-stock/v1/trading/order", tr_id,
                {"CANO": acct["cano"], "ACNT_PRDT_CD": acct["prdt_cd"],
                 "OVRS_EXCG_CD": "NASD", "PDNO": ticker,
                 "ORD_DVSN": ord_dvsn, "ORD_QTY": str(qty),
                 "OVRS_ORD_UNPR": f"{price:.2f}", "ORD_SVR_DVSN_CD": "0"})
        rt = res.get("rt_cd", "")
        return {"ok": rt == "0", "rt_cd": rt, "msg": res.get("msg1", "")}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def _execute_strategy(strategy_id, dry_run=False):
    strategies = _load_strategies()
    s = next((x for x in strategies if x.get("strategy_id") == strategy_id), None)
    if not s:
        return {"error": f"전략 없음: {strategy_id}"}

    market   = s.get("market", "KR").upper()
    stype    = s.get("type", "")
    ticker   = s.get("symbol", "")
    accounts = load_accounts()
    acct     = next((a for a in accounts if a["market"] == market), None)
    if not acct:
        return {"error": f"{market} 계좌 없음"}

    # 보유/가격 조회
    holding = _get_holding(accounts, market, ticker) if ticker else None
    price   = _get_price(acct, ticker, market) if ticker else 0.0

    # 주문 계산
    if stype == "v4":
        orders = compute_mm_v4_orders(s, holding, price)
    elif stype == "v1":
        orders = compute_mm_v1_orders(s, holding, price)
    elif stype == "vr":
        orders = compute_vr_orders(s, holding, price)
    elif stype == "kr_value":
        bal = fetch_kr_balance(acct) if market == "KR" else fetch_us_balance(acct)
        holdings_map = {h["ticker"]: h for h in bal.get("holdings", [])}
        prices_map   = {}
        for st in s.get("stocks", []):
            tk = st["ticker"]
            prices_map[tk] = _get_price(acct, tk, market)
        orders = compute_qt_orders(s, holdings_map, prices_map)
    else:
        return {"error": f"알 수 없는 전략 타입: {stype}"}

    if not orders:
        log_entry = {
            "strategy_id": strategy_id, "type": stype,
            "executed_at": datetime.now().isoformat(),
            "orders": [], "message": "주문 없음", "dry_run": dry_run,
        }
        _append_log(log_entry)
        return {"strategy_id": strategy_id, "orders": [], "message": "주문 없음"}

    # 주문 실행
    results = []
    for o in orders:
        result = _place_order_internal(
            acct, market,
            o["side"], o["ticker"], o["quantity"], o["price"], o["ord_dvsn"],
            dry_run=dry_run,
        )
        results.append({**o, "result": result})

    log_entry = {
        "strategy_id": strategy_id, "type": stype,
        "executed_at": datetime.now().isoformat(),
        "orders": results, "dry_run": dry_run,
    }
    _append_log(log_entry)
    return {"strategy_id": strategy_id, "orders_count": len(results),
            "orders": results, "dry_run": dry_run}


# ─────────────────────────────────────────────────────────────
# /api/strategies  GET / POST
# ─────────────────────────────────────────────────────────────

@app.route("/api/strategies", methods=["GET"])
def get_strategies():
    err = check_auth()
    if err:
        return err
    return jsonify({"strategies": _load_strategies()})


@app.route("/api/strategies", methods=["POST"])
def save_strategies():
    err = check_auth()
    if err:
        return err
    data       = request.json or {}
    strategies = data.get("strategies", [])
    if not isinstance(strategies, list):
        return jsonify({"error": "strategies 배열 필요"}), 400
    _save_strategies(strategies)
    return jsonify({"saved": len(strategies)})


# ─────────────────────────────────────────────────────────────
# /api/execute  POST — 수동 즉시 실행
# ─────────────────────────────────────────────────────────────

@app.route("/api/execute", methods=["POST"])
def execute():
    err = check_auth()
    if err:
        return err
    data        = request.json or {}
    strategy_id = data.get("strategy_id", "").strip()
    dry_run     = bool(data.get("dry_run", False))
    if not strategy_id:
        return jsonify({"error": "strategy_id 필요"}), 400
    result = _execute_strategy(strategy_id, dry_run=dry_run)
    if "error" in result:
        return jsonify(result), 400
    return jsonify(result)


# ─────────────────────────────────────────────────────────────
# /api/logs  GET — 실행 로그
# ─────────────────────────────────────────────────────────────

@app.route("/api/logs")
def get_logs():
    err = check_auth()
    if err:
        return err
    limit = int(request.args.get("limit", 50))
    strategy_id = request.args.get("strategy_id", "").strip()
    with _log_lock:
        if not _LOG_FILE.exists():
            return jsonify({"logs": []})
        try:
            logs = json.loads(_LOG_FILE.read_text(encoding="utf-8"))
        except Exception:
            return jsonify({"logs": []})
    if strategy_id:
        logs = [l for l in logs if l.get("strategy_id") == strategy_id]
    return jsonify({"logs": logs[:limit]})


# ─────────────────────────────────────────────────────────────
# APScheduler — 자동 실행
# ─────────────────────────────────────────────────────────────

def _run_active_strategies(market_filter):
    """market_filter: 'KR' or 'US'"""
    strategies = _load_strategies()
    active = [s for s in strategies
              if s.get("active", True)
              and s.get("market", "").upper() == market_filter]
    print(f"[scheduler] {market_filter} 전략 {len(active)}개 실행 시작")
    for s in active:
        sid = s.get("strategy_id", "?")
        try:
            result = _execute_strategy(sid)
            cnt = result.get("orders_count", 0)
            print(f"[scheduler] {sid}: {cnt}건 주문")
        except Exception as e:
            print(f"[scheduler] {sid}: 오류 - {e}")


scheduler = BackgroundScheduler(timezone="Asia/Seoul")
# KR: 평일 09:00 KST
scheduler.add_job(_run_active_strategies, "cron",
                  args=["KR"],
                  day_of_week="mon-fri", hour=9, minute=0,
                  id="kr_daily")
# US: 평일 22:30 KST (NYSE 오픈 30분 전 기준)
scheduler.add_job(_run_active_strategies, "cron",
                  args=["US"],
                  day_of_week="mon-fri", hour=22, minute=30,
                  id="us_daily")

'''

# 기존 /api/orders 라우트 앞에 삽입
ORDERS_MARKER = '\n@app.route("/api/orders")\ndef get_orders():'
if ORDERS_MARKER in src:
    src = src.replace(ORDERS_MARKER, NEW_ENDPOINTS + ORDERS_MARKER, 1)

# ── 5. __main__ 블록 대체 ─────────────────────────────────────
OLD_MAIN = 'if __name__ == "__main__":'
NEW_MAIN = '''if __name__ == "__main__":
    scheduler.start()
    print("[startup] APScheduler started (KR 09:00 / US 22:30 KST)")
    print("[startup] issuing tokens...")'''

src = src.replace(OLD_MAIN, NEW_MAIN, 1)

Path("api_server.py").write_text(src, encoding="utf-8")
print("api_server.py patched successfully")
