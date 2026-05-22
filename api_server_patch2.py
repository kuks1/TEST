"""
Patch 2: KR LOC logic + scheduler rework
"""
import re
from pathlib import Path

src = Path("api_server.py").read_text(encoding="utf-8")

# ── 1. _execute_strategy 교체 ─────────────────────────────────
OLD_EXEC = '''def _execute_strategy(strategy_id, dry_run=False):
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
            "orders": results, "dry_run": dry_run}'''

NEW_EXEC = '''def _execute_strategy(strategy_id, dry_run=False, kr_loc_mode=False):
    """
    kr_loc_mode=True  → 15:29:30 KST 실행: ord_dvsn='kr_loc' 주문만 처리
                         BUY  조건: 현재가 <= 지정가 → 시장가 송신
                         SELL 조건: 현재가 >= 지정가 → 시장가 송신
    kr_loc_mode=False → 09:00 KST 또는 US 실행: 일반 주문만 처리 (kr_loc 스킵)
    dry_run=True      → 모든 주문 내역 표시만, 실제 송신 없음
    """
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

    results = []
    for o in orders:
        dvsn = o.get("ord_dvsn", "")

        if dvsn == "kr_loc":
            # ── KR LOC 주문 처리 ──────────────────────────────
            if dry_run:
                results.append({**o, "result": {
                    "dry_run": True,
                    "note": "15:29:30 조건 체크: BUY→종가≤지정가, SELL→종가≥지정가 시 시장가"
                }})
            elif kr_loc_mode:
                cur = _get_price(acct, o["ticker"], market)
                if o["side"] == "BUY" and cur <= o["price"]:
                    res = _place_order_internal(acct, market, "BUY",
                          o["ticker"], o["quantity"], 0, "01")
                    res["condition"] = f"종가({cur}) <= 지정가({o['price']}) → 시장가 실행"
                    results.append({**o, "result": res})
                elif o["side"] == "SELL" and cur >= o["price"]:
                    res = _place_order_internal(acct, market, "SELL",
                          o["ticker"], o["quantity"], 0, "01")
                    res["condition"] = f"종가({cur}) >= 지정가({o['price']}) → 시장가 실행"
                    results.append({**o, "result": res})
                else:
                    results.append({**o, "result": {
                        "skipped": True, "reason": "조건 미충족",
                        "current_price": cur, "target_price": o["price"],
                    }})
            else:
                # 09:00 일반 실행 시 kr_loc 주문은 건너뜀
                results.append({**o, "result": {
                    "skipped": True, "reason": "kr_loc는 15:29:30에만 실행"
                }})
        else:
            # ── 일반 주문 (지정가/시장가/US LOC) ──────────────
            result = _place_order_internal(
                acct, market,
                o["side"], o["ticker"], o["quantity"], o["price"], o["ord_dvsn"],
                dry_run=dry_run,
            )
            results.append({**o, "result": result})

    log_entry = {
        "strategy_id": strategy_id, "type": stype,
        "executed_at": datetime.now().isoformat(),
        "kr_loc_mode": kr_loc_mode,
        "orders": results, "dry_run": dry_run,
    }
    _append_log(log_entry)
    executed = sum(1 for r in results if not r.get("result", {}).get("skipped"))
    return {"strategy_id": strategy_id, "orders_count": executed,
            "orders": results, "dry_run": dry_run}'''

src = src.replace(OLD_EXEC, NEW_EXEC, 1)

# ── 2. 스케줄러 섹션 교체 ─────────────────────────────────────
OLD_SCHED = '''# ─────────────────────────────────────────────────────────────
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
                  id="us_daily")'''

NEW_SCHED = '''# ─────────────────────────────────────────────────────────────
# APScheduler — 자동 실행
# ─────────────────────────────────────────────────────────────
#  KR 09:00        → VR / QT  (지정가·시장가 장시작 주문)
#  KR 15:29:30     → MM V4/V1 (예상 종가 조건 체크 → 시장가)
#  US 22:30 KST    → 모든 US 전략 (LOC ord_dvsn='32' 포함)
# ─────────────────────────────────────────────────────────────

def _run_kr_open():
    """09:00 KST: KR VR + QT — 장시작 지정가/시장가"""
    strategies = _load_strategies()
    targets = [s for s in strategies
               if s.get("active", True)
               and s.get("market", "").upper() == "KR"
               and s.get("type") in ("vr", "kr_value")]
    print(f"[scheduler] KR 09:00 대상: {len(targets)}개")
    for s in targets:
        sid = s.get("strategy_id", "?")
        try:
            result = _execute_strategy(sid, kr_loc_mode=False)
            print(f"[scheduler] {sid}: {result.get('orders_count', 0)}건")
        except Exception as e:
            print(f"[scheduler] {sid} 오류: {e}")


def _run_kr_close_loc():
    """15:29:30 KST: KR MM V4/V1 — 예상 종가 조건 체크 후 시장가"""
    strategies = _load_strategies()
    targets = [s for s in strategies
               if s.get("active", True)
               and s.get("market", "").upper() == "KR"
               and s.get("type") in ("v4", "v1")]
    print(f"[scheduler] KR 15:29:30 LOC 대상: {len(targets)}개")
    for s in targets:
        sid = s.get("strategy_id", "?")
        try:
            result = _execute_strategy(sid, kr_loc_mode=True)
            print(f"[scheduler] {sid}: {result.get('orders_count', 0)}건")
        except Exception as e:
            print(f"[scheduler] {sid} 오류: {e}")


def _run_us_open():
    """22:30 KST: 모든 US 전략"""
    strategies = _load_strategies()
    targets = [s for s in strategies
               if s.get("active", True)
               and s.get("market", "").upper() == "US"]
    print(f"[scheduler] US 22:30 대상: {len(targets)}개")
    for s in targets:
        sid = s.get("strategy_id", "?")
        try:
            result = _execute_strategy(sid, kr_loc_mode=False)
            print(f"[scheduler] {sid}: {result.get('orders_count', 0)}건")
        except Exception as e:
            print(f"[scheduler] {sid} 오류: {e}")


scheduler = BackgroundScheduler(timezone="Asia/Seoul")
# KR 장시작: VR + QT
scheduler.add_job(_run_kr_open, "cron",
                  day_of_week="mon-fri", hour=9, minute=0, second=0,
                  id="kr_open")
# KR 장마감 30초 전: MM V4/V1 LOC 체크
scheduler.add_job(_run_kr_close_loc, "cron",
                  day_of_week="mon-fri", hour=15, minute=29, second=30,
                  id="kr_close_loc")
# US 장시작 30분 전 (22:30 KST = 08:30 ET)
scheduler.add_job(_run_us_open, "cron",
                  day_of_week="mon-fri", hour=22, minute=30, second=0,
                  id="us_open")'''

src = src.replace(OLD_SCHED, NEW_SCHED, 1)

Path("api_server.py").write_text(src, encoding="utf-8")
print("patch2 applied")
print("kr_loc count:", src.count("kr_loc_mode"))
print("scheduler jobs:", src.count("scheduler.add_job"))
