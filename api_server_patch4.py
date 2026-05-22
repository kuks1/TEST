"""
Patch 4: MM V4 cash injection + reverse mode state management

변경 내용:
1. _get_holding() → cash_available, prev_close 포함
2. _execute_strategy() → V4 전용 상태 업데이트 (mm_mode, mm_reverse_day, mm_close_history)
3. _place_order_internal() → ord_dvsn='34' (US LOC) 지원

적용 방법:
  Oracle 서버의 /home/ubuntu/trading-api/ 에서 실행
  python api_server_patch4.py
"""
import re
from pathlib import Path

src = Path("api_server.py").read_text(encoding="utf-8")

# ══════════════════════════════════════════════════════════════
# 1. _get_holding() 교체 — cash_available + prev_close 추가
# ══════════════════════════════════════════════════════════════

OLD_GET_HOLDING = '''def _get_holding(accounts, market, ticker):
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
    return None'''

NEW_GET_HOLDING = '''def _get_holding(accounts, market, ticker):
    """보유 종목 조회. cash_available, prev_close 포함."""
    key = "KR" if market == "KR" else "US"
    for acc in accounts:
        if acc.get("market") == key:
            try:
                bal = fetch_kr_balance(acc) if key == "KR" else fetch_us_balance(acc)

                # 잔여 현금 추출
                out2 = bal.get("output2") or {}
                if isinstance(out2, list):
                    out2 = out2[0] if out2 else {}
                if key == "KR":
                    cash = float(out2.get("dnca_tot_amt", 0) or 0)
                else:
                    # USD 출금 가능 금액
                    cash = float(out2.get("frcr_drwg_psbl_amt_1", 0)
                                 or out2.get("frcr_dncl_amt_1", 0) or 0)

                # 전일 종가 조회 (US만)
                prev_close = 0.0
                if key == "US" and ticker:
                    try:
                        prev_close = _get_prev_close(acc, ticker)
                    except Exception:
                        pass

                # 보유 종목 탐색
                for h in bal.get("holdings", []):
                    if h["ticker"] == ticker:
                        h = dict(h)  # 복사본 수정
                        h["cash_available"] = cash
                        if prev_close > 0:
                            h["prev_close"] = prev_close
                        return h

                # 종목 미보유 → 빈 holding 반환 (현금만)
                return {
                    "ticker": ticker, "shares": 0, "avg_price": 0,
                    "cash_available": cash,
                    **({"prev_close": prev_close} if prev_close > 0 else {}),
                }
            except Exception:
                pass
    return None


def _get_prev_close(acct, ticker):
    """전일 종가 조회 (US 해외주식 일봉 API)."""
    _EXCG_MAP = {
        "SOXL": "AMS", "TQQQ": "NAS", "UPRO": "AMS", "SPXL": "AMS",
        "TECL": "AMS", "LABU": "AMS",
    }
    excd = _EXCG_MAP.get(ticker.upper(), "NAS")
    today = datetime.now().strftime("%Y%m%d")
    d = _get(acct,
             "/uapi/overseas-price/v1/quotations/dailyprice",
             "HHDFS76240000",
             {"AUTH": "", "EXCD": excd, "SYMB": ticker,
              "GUBN": "0", "BYMD": today, "MODP": "0"})
    rows = d.get("output2") or []
    for r in rows:
        c = float(r.get("clos") or 0)
        if c > 0:
            return c
    return 0.0'''

if OLD_GET_HOLDING in src:
    src = src.replace(OLD_GET_HOLDING, NEW_GET_HOLDING, 1)
    print("✅ _get_holding() 교체 완료")
else:
    print("⚠️  _get_holding() 원본 미발견 — 수동 확인 필요")

# ══════════════════════════════════════════════════════════════
# 2. _execute_strategy() 내부 V4 처리 블록 교체
#    — 실행 후 mm_mode / mm_reverse_day / mm_close_history 갱신
# ══════════════════════════════════════════════════════════════

OLD_V4_EXEC_BLOCK = '''    # 주문 계산
    if stype == "v4":
        orders = compute_mm_v4_orders(s, holding, price)'''

NEW_V4_EXEC_BLOCK = '''    # 주문 계산
    if stype == "v4":
        orders = compute_mm_v4_orders(s, holding, price)

        # ── V4 리버스모드 상태 업데이트 ──────────────────────
        mm_mode     = s.get("mm_mode", "normal")
        reverse_day = int(s.get("mm_reverse_day", 0) or 0)
        close_hist  = list(s.get("mm_close_history", []) or [])
        t_val       = float(s.get("t_value") or 0)
        divisions   = int(s.get("divisions") or 20)
        avg_price   = float((holding or {}).get("avg_price", 0))

        state_changed = False

        # 종가 히스토리 갱신 (US 장 마감 후 호출 시)
        if market == "US" and price > 0:
            if not close_hist or close_hist[-1] != price:
                close_hist.append(price)
                if len(close_hist) > 10:
                    close_hist = close_hist[-10:]
                state_changed = True

        # 리버스 진입 체크 (T > divisions-1)
        if mm_mode == "normal" and t_val > divisions - 1:
            mm_mode = "reverse"
            reverse_day = 1
            state_changed = True

        # 리버스 복귀 체크 (종가 >= 평단 × 0.80)
        elif mm_mode == "reverse":
            reverse_day = max(reverse_day + 1, 1)
            avg_cost_adj = avg_price / (1 - 0.0025) if avg_price > 0 else 0
            if avg_cost_adj > 0 and price >= avg_cost_adj * 0.80:
                mm_mode = "normal"
                reverse_day = 0
            state_changed = True

        if state_changed:
            all_strats = _load_strategies()
            for st in all_strats:
                if st.get("strategy_id") == strategy_id:
                    st["mm_mode"]         = mm_mode
                    st["mm_reverse_day"]  = reverse_day
                    st["mm_close_history"] = close_hist
                    break
            _save_strategies(all_strats)'''

if OLD_V4_EXEC_BLOCK in src:
    src = src.replace(OLD_V4_EXEC_BLOCK, NEW_V4_EXEC_BLOCK, 1)
    print("✅ _execute_strategy() V4 블록 교체 완료")
else:
    print("⚠️  _execute_strategy() V4 블록 미발견 — 수동 확인 필요")

# ══════════════════════════════════════════════════════════════
# 3. _place_order_internal() — US LOC ord_dvsn='34' 지원
#    기존 else 브랜치의 OVRS_EXCG_CD를 ticker별로 분기
# ══════════════════════════════════════════════════════════════

OLD_PLACE_US = '''            res = _post(acct, "/uapi/overseas-stock/v1/trading/order", tr_id,
                {"CANO": acct["cano"], "ACNT_PRDT_CD": acct["prdt_cd"],
                 "OVRS_EXCG_CD": "NASD", "PDNO": ticker,
                 "ORD_DVSN": ord_dvsn, "ORD_QTY": str(qty),
                 "OVRS_ORD_UNPR": f"{price:.2f}", "ORD_SVR_DVSN_CD": "0"})'''

NEW_PLACE_US = '''            _EXCG_MAP = {
                "SOXL": "AMEX", "UPRO": "AMEX", "SPXL": "AMEX",
                "TECL": "AMEX", "LABU": "AMEX",
                "TQQQ": "NASD", "QQQ": "NASD",
            }
            excg = _EXCG_MAP.get(ticker.upper(), "NASD")
            res = _post(acct, "/uapi/overseas-stock/v1/trading/order", tr_id,
                {"CANO": acct["cano"], "ACNT_PRDT_CD": acct["prdt_cd"],
                 "OVRS_EXCG_CD": excg, "PDNO": ticker,
                 "ORD_DVSN": ord_dvsn, "ORD_QTY": str(qty),
                 "OVRS_ORD_UNPR": f"{price:.2f}", "ORD_SVR_DVSN_CD": "0"})'''

if OLD_PLACE_US in src:
    src = src.replace(OLD_PLACE_US, NEW_PLACE_US, 1)
    print("✅ _place_order_internal() US 거래소코드 분기 완료")
else:
    print("⚠️  _place_order_internal() 원본 미발견 — 수동 확인 필요")

# ══════════════════════════════════════════════════════════════
# 저장
# ══════════════════════════════════════════════════════════════

Path("api_server.py").write_text(src, encoding="utf-8")
print("\n✅ api_server.py patch4 적용 완료")
print("   변경사항:")
print("   - _get_holding(): cash_available, prev_close 포함")
print("   - _execute_strategy(): V4 mm_mode/reverse_day/close_history 자동 갱신")
print("   - _place_order_internal(): AMEX/NASD 거래소코드 자동 선택")
