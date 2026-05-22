"""
Trading API Server
Flutter trading_app ↔ 한국투자증권 OpenAPI 브릿지

엔드포인트
  GET  /api/account                        계좌 잔고 (KR + US)
  GET  /api/quote?ticker=&market=          현재가
  GET  /api/orders?market=KR|US            주문 내역 (미체결 + 최근 7일 체결)
  DELETE /api/orders/<id>?market=KR|US     주문 취소
  PUT  /api/orders/<id>                    주문 정정  body: {market, price, quantity}
  POST /api/order                          신규 주문  body: {market, ticker, side, qty, price, ord_dvsn, exchange}
  POST /api/rebalance                      전략 리밸런싱  body: {strategy_id}
"""

import os
import sys
import traceback
from datetime import datetime, timedelta
from functools import wraps

from dotenv import load_dotenv
from flask import Flask, jsonify, request
from flask_cors import CORS

load_dotenv()

# kis_api.py 와 같은 폴더
sys.path.insert(0, os.path.dirname(__file__))
import kis_api as kis

app = Flask(__name__)
CORS(app)

# Flutter Config.apiKey 와 일치
API_KEY = os.getenv("API_SECRET_KEY", "6495")


# ─────────────────────────────────────────────────────────────
# 인증 미들웨어
# ─────────────────────────────────────────────────────────────

def require_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        token = auth.removeprefix("Bearer ").strip()
        if token != API_KEY:
            return jsonify({"error": "unauthorized"}), 401
        return f(*args, **kwargs)
    return decorated


# ─────────────────────────────────────────────────────────────
# /api/account
# ─────────────────────────────────────────────────────────────

@app.route("/api/account")
@require_auth
def get_account():
    kr_accounts = []
    us_accounts = []

    for acc in kis.load_accounts():
        # ── 국내 잔고 ──
        try:
            d = kis.kr_balance(acc)
            out1 = d.get("output1") or []
            out2 = (d.get("output2") or [{}])
            out2 = out2[0] if isinstance(out2, list) else out2

            holdings = []
            for h in out1:
                qty = int(h.get("hldg_qty", 0) or 0)
                if qty <= 0:
                    continue
                holdings.append({
                    "ticker":        h.get("pdno", ""),
                    "name":          h.get("prdt_name", ""),
                    "shares":        qty,
                    "avg_price":     float(h.get("pchs_avg_pric", 0) or 0),
                    "current_price": float(h.get("prpr", 0) or 0),
                    "eval_profit":   float(h.get("evlu_pfls_amt", 0) or 0),
                    "return_pct":    float(h.get("evlu_erng_rt", 0) or 0),
                })

            kr_accounts.append({
                "label":          acc["label"],
                "cash_krw":       float(out2.get("dnca_tot_amt", 0) or 0),
                "orderable_krw":  float(out2.get("prvs_rcdv_amt", 0) or out2.get("dnca_tot_amt", 0) or 0),
                "stock_eval":     float(out2.get("scts_evlu_amt", 0) or 0),
                "total_eval":     float(out2.get("tot_evlu_amt", 0) or 0),
                "holdings":       holdings,
            })
        except Exception:
            pass

        # ── 해외 잔고 ──
        try:
            d = kis.us_balance("NASD", "USD", acc)
            out1 = d.get("output1") or []
            out2 = d.get("output2") or {}
            if isinstance(out2, list):
                out2 = out2[0] if out2 else {}

            holdings = []
            for h in out1:
                qty = float(h.get("ovrs_cblc_qty", 0) or 0)
                if qty <= 0:
                    continue
                holdings.append({
                    "ticker":        h.get("ovrs_pdno", ""),
                    "name":          h.get("ovrs_item_name", ""),
                    "shares":        qty,
                    "avg_price":     float(h.get("pchs_avg_pric", 0) or 0),
                    "current_price": float(h.get("now_pric2", 0) or 0),
                    "eval_profit":   float(h.get("frcr_evlu_pfls_amt", 0) or 0),
                    "return_pct":    float(h.get("evlu_pfls_rt", 0) or 0),
                })

            us_accounts.append({
                "label":      acc["label"],
                "cash_usd":   float(out2.get("frcr_dncl_amt_1", 0) or 0),
                "stock_eval": float(out2.get("frcr_pchs_amt1", 0) or 0),
                "holdings":   holdings,
            })
        except Exception:
            pass

    return jsonify({"kr": kr_accounts, "us": us_accounts})


# ─────────────────────────────────────────────────────────────
# /api/quote
# ─────────────────────────────────────────────────────────────

@app.route("/api/quote")
@require_auth
def get_quote():
    ticker = request.args.get("ticker", "").strip()
    market = request.args.get("market", "KR").upper()

    if not ticker:
        return jsonify({"error": "ticker required"}), 400

    try:
        if market == "KR":
            d = kis.kr_price(ticker)
            out = d.get("output", {})
            return jsonify({
                "ticker": ticker,
                "market": market,
                "price":      float(out.get("stck_prpr", 0) or 0),
                "change_pct": float(out.get("prdy_ctrt", 0) or 0),
                "open":       float(out.get("stck_oprc", 0) or 0),
                "high":       float(out.get("stck_hgpr", 0) or 0),
                "low":        float(out.get("stck_lwpr", 0) or 0),
                "volume":     int(out.get("acml_vol", 0) or 0),
            })
        else:
            # 거래소 자동 감지: 숫자면 NYSE, 아니면 NASD 우선
            excg_map = {"SOXL": "AMS", "TQQQ": "NAS", "UPRO": "AMS", "SPXL": "AMS"}
            excg = excg_map.get(ticker.upper(), "NAS")
            d = kis.us_price(ticker, excg)
            out = d.get("output", {})
            return jsonify({
                "ticker": ticker,
                "market": market,
                "price":      float(out.get("last", 0) or 0),
                "change_pct": float(out.get("rate", 0) or 0),
                "open":       float(out.get("open", 0) or 0),
                "high":       float(out.get("high", 0) or 0),
                "low":        float(out.get("low", 0) or 0),
                "volume":     int(out.get("tvol", 0) or 0),
            })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ─────────────────────────────────────────────────────────────
# /api/orders  GET — 미체결 + 최근 7일 체결 내역
# ─────────────────────────────────────────────────────────────

def _today_str():
    return datetime.today().strftime("%Y%m%d")

def _week_ago_str():
    return (datetime.today() - timedelta(days=7)).strftime("%Y%m%d")

def _ordered_at(date_str: str, time_str: str) -> str:
    """KIS date(YYYYMMDD) + time(HHMMSS) → readable string"""
    d = date_str or _today_str()
    t = time_str or ""
    try:
        dt = datetime.strptime(d + t[:6].zfill(6), "%Y%m%d%H%M%S")
        return dt.strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return d


@app.route("/api/orders")
@require_auth
def get_orders():
    market = request.args.get("market", "KR").upper()
    orders = []

    if market == "KR":
        # ── 미체결 ──
        try:
            raw = kis.kr_open_orders()
            for o in raw.get("output1") or []:
                total_qty = int(o.get("ord_qty", 0) or 0)
                ccld_qty  = int(o.get("ccld_qty", 0) or 0)
                if total_qty == 0:
                    continue
                status = "체결" if ccld_qty >= total_qty else ("부분체결" if ccld_qty > 0 else "미체결")
                org_no = o.get("krx_fwdg_ord_orgno", "").strip()
                ord_no = o.get("odno", "").strip()
                orders.append({
                    "order_id":    f"{org_no}_{ord_no}",
                    "ordered_at":  _ordered_at(o.get("ord_dt", ""), o.get("ord_tmd", "")),
                    "ticker":      o.get("pdno", ""),
                    "name":        o.get("prdt_name", ""),
                    "order_price": float(o.get("ord_unpr", 0) or 0),
                    "quantity":    total_qty,
                    "avg_price":   0.0,
                    "status":      status,
                    "side":        "BUY" if "매수" in (o.get("sll_buy_dvsn_cd_name") or "") else "SELL",
                    "org_no":      org_no,
                })
        except Exception:
            pass

        # ── 최근 7일 체결 ──
        try:
            raw = kis.kr_daily_ccld(_week_ago_str(), _today_str(), ccld_dvsn="01")
            for o in raw.get("output1") or []:
                if not o.get("pdno"):
                    continue
                orders.append({
                    "order_id":    f"ccld_{o.get('odno', '')}",
                    "ordered_at":  _ordered_at(o.get("ord_dt", ""), o.get("ord_tmd", "")),
                    "ticker":      o.get("pdno", ""),
                    "name":        o.get("prdt_name", ""),
                    "order_price": float(o.get("ord_unpr", 0) or 0),
                    "quantity":    int(o.get("tot_ccld_qty", 0) or 0),
                    "avg_price":   float(o.get("avg_prvs", 0) or 0),
                    "status":      "체결",
                    "side":        "BUY" if "매수" in (o.get("sll_buy_dvsn_cd_name") or "") else "SELL",
                })
        except Exception:
            pass

    else:  # US
        # ── 미체결 ──
        try:
            raw = kis.us_open_orders("NASD")
            for o in raw.get("output") or []:
                total_qty = int(float(o.get("ft_ord_qty", 0) or 0))
                nccs_qty  = int(float(o.get("nccs_qty",   0) or 0))
                ccld_qty  = total_qty - nccs_qty
                if total_qty == 0:
                    continue
                status = "체결" if ccld_qty >= total_qty else ("부분체결" if ccld_qty > 0 else "미체결")
                org_no   = o.get("krx_fwdg_ord_orgno", "").strip()
                ord_no   = o.get("odno", "").strip()
                exchange = o.get("ovrs_excg_cd", "NASD").strip()
                ticker   = o.get("ovrs_pdno", "").strip()
                sll_buy  = o.get("sll_buy_dvsn_cd", "")
                orders.append({
                    "order_id":    f"{exchange}_{ticker}_{org_no}_{ord_no}",
                    "ordered_at":  _ordered_at(o.get("ord_dt", ""), o.get("ord_tmd", "")),
                    "ticker":      ticker,
                    "name":        o.get("ovrs_item_name", ""),
                    "order_price": float(o.get("ft_ord_unpr3", 0) or 0),
                    "quantity":    total_qty,
                    "avg_price":   0.0,
                    "status":      status,
                    "side":        "BUY" if sll_buy == "02" else "SELL",
                    "org_no":      org_no,
                    "exchange":    exchange,
                })
        except Exception:
            pass

        # ── 최근 7일 체결 ──
        try:
            raw = kis.us_daily_ccnl(_week_ago_str(), _today_str(), ccld="01")
            for o in raw.get("output") or []:
                if not o.get("ovrs_pdno"):
                    continue
                sll_buy = o.get("sll_buy_dvsn_cd", "")
                orders.append({
                    "order_id":    f"ccld_{o.get('odno', '')}",
                    "ordered_at":  _ordered_at(o.get("ord_dt", ""), o.get("ord_tmd", "")),
                    "ticker":      o.get("ovrs_pdno", ""),
                    "name":        o.get("ovrs_item_name", ""),
                    "order_price": float(o.get("ft_ord_unpr3", 0) or 0),
                    "quantity":    int(float(o.get("ft_ccld_qty", 0) or 0)),
                    "avg_price":   float(o.get("ft_ccld_unpr3", 0) or 0),
                    "status":      "체결",
                    "side":        "BUY" if sll_buy == "02" else "SELL",
                })
        except Exception:
            pass

    # 미체결 먼저, 체결 나중으로 정렬
    orders.sort(key=lambda x: (0 if x["status"] != "체결" else 1, x["ordered_at"]), reverse=False)
    return jsonify({"orders": orders})


# ─────────────────────────────────────────────────────────────
# /api/orders/<id>  DELETE — 주문 취소
# ─────────────────────────────────────────────────────────────

@app.route("/api/orders/<path:order_id>", methods=["DELETE"])
@require_auth
def cancel_order(order_id):
    market = request.args.get("market", "KR").upper()

    if order_id.startswith("ccld_"):
        return jsonify({"error": "체결 완료된 주문은 취소할 수 없습니다"}), 400

    try:
        if market == "KR":
            # order_id = "{org_no}_{ord_no}"
            idx = order_id.index("_")
            org_no = order_id[:idx]
            ord_no = order_id[idx+1:]

            # 잔여수량 조회
            qty = 1
            raw = kis.kr_open_orders()
            for o in raw.get("output1") or []:
                if o.get("odno", "").strip() == ord_no:
                    qty = int(o.get("rmn_qty", 0) or o.get("ord_qty", 1) or 1)
                    break

            result = kis.kr_cancel_order(org_no, ord_no, qty)
        else:
            # order_id = "{exchange}_{ticker}_{org_no}_{ord_no}"
            parts = order_id.split("_", 3)
            if len(parts) != 4:
                return jsonify({"error": "잘못된 order_id 형식"}), 400
            exchange, ticker, org_no, ord_no = parts

            qty = 1
            raw = kis.us_open_orders(exchange)
            for o in raw.get("output") or []:
                if o.get("odno", "").strip() == ord_no:
                    qty = int(float(o.get("nccs_qty", 0) or o.get("ft_ord_qty", 1) or 1))
                    break

            result = kis.us_cancel_order(org_no, ord_no, ticker, exchange, qty)

        if result.get("rt_cd") == "0":
            return jsonify({"success": True,
                            "order_no": result.get("output", {}).get("ODNO", "")})
        return jsonify({"error": result.get("msg1", "주문 취소 실패"),
                        "code":  result.get("msg_cd", "")}), 400

    except Exception as e:
        traceback.print_exc()
        return jsonify({"error": str(e)}), 500


# ─────────────────────────────────────────────────────────────
# /api/orders/<id>  PUT — 주문 정정
# ─────────────────────────────────────────────────────────────

@app.route("/api/orders/<path:order_id>", methods=["PUT"])
@require_auth
def modify_order(order_id):
    body     = request.get_json() or {}
    market   = body.get("market", "KR").upper()
    price    = float(body.get("price", 0))
    quantity = int(body.get("quantity", 0))

    if order_id.startswith("ccld_"):
        return jsonify({"error": "체결 완료된 주문은 정정할 수 없습니다"}), 400
    if price <= 0 or quantity <= 0:
        return jsonify({"error": "price와 quantity는 0보다 커야 합니다"}), 400

    try:
        if market == "KR":
            idx    = order_id.index("_")
            org_no = order_id[:idx]
            ord_no = order_id[idx+1:]

            result = kis._post(
                "/uapi/domestic-stock/v1/trading/order-rvsecncl",
                "TTTC0803U" if kis.ENV == "real" else "VTTC0803U",
                {
                    "CANO":                 kis.CANO,
                    "ACNT_PRDT_CD":         kis.ACNT_CD,
                    "KRX_FWDG_ORD_ORGNO":   org_no,
                    "ORGN_ODNO":            ord_no,
                    "ORD_DVSN":             "00",
                    "RVSE_CNCL_DVSN_CD":    "01",   # 01 = 정정
                    "ORD_QTY":              str(quantity),
                    "ORD_UNPR":             str(int(price)),
                    "QTY_ALL_ORD_YN":       "N",
                },
            )
        else:
            parts = order_id.split("_", 3)
            if len(parts) != 4:
                return jsonify({"error": "잘못된 order_id 형식"}), 400
            exchange, ticker, org_no, ord_no = parts

            result = kis._post(
                "/uapi/overseas-stock/v1/trading/order-rvsecncl",
                "TTTS0309U" if kis.ENV == "real" else "VTTS0309U",
                {
                    "CANO":               kis.CANO,
                    "ACNT_PRDT_CD":       kis.ACNT_CD,
                    "OVRS_EXCG_CD":       exchange,
                    "PDNO":               ticker,
                    "ORGN_ODNO":          ord_no,
                    "ORD_SVR_DVSN_CD":    "0",
                    "RVSE_CNCL_DVSN_CD":  "01",
                    "ORD_QTY":            str(quantity),
                    "OVRS_ORD_UNPR":      f"{price:.2f}",
                    "QTY_ALL_ORD_YN":     "N",
                },
            )

        if result.get("rt_cd") == "0":
            return jsonify({"success": True,
                            "order_no": result.get("output", {}).get("ODNO", "")})
        return jsonify({"error": result.get("msg1", "주문 정정 실패"),
                        "code":  result.get("msg_cd", "")}), 400

    except Exception as e:
        traceback.print_exc()
        return jsonify({"error": str(e)}), 500


# ─────────────────────────────────────────────────────────────
# /api/order  POST — 신규 주문 실행
# ─────────────────────────────────────────────────────────────

@app.route("/api/order", methods=["POST"])
@require_auth
def place_order():
    body      = request.get_json() or {}
    market    = body.get("market", "KR").upper()
    ticker    = body.get("ticker", "").strip()
    side      = body.get("side", "BUY").upper()
    quantity  = int(body.get("quantity", 0))
    price     = float(body.get("price", 0))
    ord_dvsn  = str(body.get("ord_dvsn", "01"))  # 01=시장가
    exchange  = body.get("exchange", "NASD")

    if not ticker or quantity <= 0:
        return jsonify({"error": "ticker와 quantity가 필요합니다"}), 400

    try:
        if market == "KR":
            result = kis.kr_order(ticker, side, quantity, int(price), ord_dvsn)
        else:
            result = kis.us_order(ticker, exchange, side, quantity, price, ord_dvsn)

        if result.get("rt_cd") == "0":
            out = result.get("output", {})
            return jsonify({
                "success":    True,
                "order_no":   out.get("ODNO", ""),
                "order_time": out.get("ORD_TMD", ""),
            })
        return jsonify({"error":  result.get("msg1", "주문 실패"),
                        "code":   result.get("msg_cd", "")}), 400

    except Exception as e:
        traceback.print_exc()
        return jsonify({"error": str(e)}), 500


# ─────────────────────────────────────────────────────────────
# /api/rebalance  POST — 전략 실행 트리거
# ─────────────────────────────────────────────────────────────

@app.route("/api/rebalance", methods=["POST"])
@require_auth
def rebalance():
    body        = request.get_json() or {}
    strategy_id = body.get("strategy_id", "")
    # 전략 실행은 별도 프로세스 (v_mm_v4.py, v_vr_1.py 등) 에서 담당
    # 여기서는 트리거 신호만 반환 — 필요 시 subprocess 호출로 교체
    return jsonify({"strategy_id": strategy_id, "status": "triggered",
                    "message": "전략 실행 요청이 접수되었습니다"})


# ─────────────────────────────────────────────────────────────
# 실행
# ─────────────────────────────────────────────────────────────

if __name__ == "__main__":
    port = int(os.getenv("PORT", 5000))
    debug = os.getenv("DEBUG", "0") == "1"
    print(f"Trading API Server starting on port {port} (debug={debug})")
    app.run(host="0.0.0.0", port=port, debug=debug)
