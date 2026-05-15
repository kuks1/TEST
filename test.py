import os
import sys
import requests
from dotenv import load_dotenv

sys.stdout.reconfigure(encoding="utf-8")

load_dotenv()

APP_KEY    = os.getenv("KIS_APP_KEY")
APP_SECRET = os.getenv("KIS_APP_SECRET")
CANO       = os.getenv("KIS_CANO")
ACNT_CD    = os.getenv("KIS_ACNT_PRDT_CD", "01")
ENV        = os.getenv("KIS_ENV", "real")

BASE_URL = (
    "https://openapi.koreainvestment.com:9443"
    if ENV == "real"
    else "https://openapivts.koreainvestment.com:29443"
)


def get_token() -> str:
    res = requests.post(
        f"{BASE_URL}/oauth2/tokenP",
        json={
            "grant_type": "client_credentials",
            "appkey": APP_KEY,
            "appsecret": APP_SECRET,
        },
    )
    res.raise_for_status()
    return res.json()["access_token"]


def _headers(token: str, tr_id: str) -> dict:
    return {
        "authorization": f"Bearer {token}",
        "appkey": APP_KEY,
        "appsecret": APP_SECRET,
        "tr_id": tr_id,
        "content-type": "application/json; charset=utf-8",
    }


def get_domestic_balance(token: str) -> dict:
    """원화 잔고 + 국내 보유 주식"""
    tr_id = "TTTC8434R" if ENV == "real" else "VTTC8434R"
    params = {
        "CANO": CANO,
        "ACNT_PRDT_CD": ACNT_CD,
        "AFHR_FLPR_YN": "N",
        "OFL_YN": "",
        "INQR_DVSN": "02",
        "UNPR_DVSN": "01",
        "FUND_STTL_ICLD_YN": "N",
        "FNCG_AMT_AUTO_RDPT_YN": "N",
        "PRCS_DVSN": "00",
        "CTX_AREA_FK100": "",
        "CTX_AREA_NK100": "",
    }
    res = requests.get(
        f"{BASE_URL}/uapi/domestic-stock/v1/trading/inquire-balance",
        headers=_headers(token, tr_id),
        params=params,
    )
    res.raise_for_status()
    return res.json()


def get_overseas_balance(token: str) -> dict:
    """달러 잔고 + 해외 보유 주식"""
    tr_id = "TTTS3012R" if ENV == "real" else "VTTS3012R"
    params = {
        "CANO": CANO,
        "ACNT_PRDT_CD": ACNT_CD,
        "OVRS_EXCG_CD": "NASD",  # 실전: 미국 전체
        "TR_CRCY_CD": "USD",
        "CTX_AREA_FK200": "",
        "CTX_AREA_NK200": "",
    }
    res = requests.get(
        f"{BASE_URL}/uapi/overseas-stock/v1/trading/inquire-balance",
        headers=_headers(token, tr_id),
        params=params,
    )
    res.raise_for_status()
    return res.json()


def print_account_summary():
    token = get_token()

    # ── 국내 ──────────────────────────────────────────
    d = get_domestic_balance(token)
    summary = d.get("output2", [{}])[0]
    stocks  = d.get("output1", [])

    print("=" * 50)
    print("[ 국내 계좌 ]")
    print(f"  예수금       : {int(summary.get('dnca_tot_amt', 0)):>15,} 원")
    print(f"  D+2 예수금   : {int(summary.get('prvs_rcdl_excc_amt', 0)):>15,} 원")
    print(f"  주식 평가금액 : {int(summary.get('scts_evlu_amt', 0)):>15,} 원")
    print(f"  총 평가금액  : {int(summary.get('tot_evlu_amt', 0)):>15,} 원")
    print(f"  평가손익     : {int(summary.get('evlu_pfls_smtl_amt', 0)):>15,} 원")

    if stocks:
        print("\n  [ 보유 국내 주식 ]")
        print(f"  {'종목명':<16} {'수량':>7} {'평균단가':>12} {'현재가':>12} {'평가손익':>12}")
        print("  " + "-" * 63)
        for s in stocks:
            if int(s.get("hldg_qty", 0)) == 0:
                continue
            print(
                f"  {s.get('prdt_name',''):<16}"
                f" {int(s.get('hldg_qty', 0)):>7,}"
                f" {int(s.get('pchs_avg_pric', 0)):>12,.0f}"
                f" {int(s.get('prpr', 0)):>12,}"
                f" {int(s.get('evlu_pfls_amt', 0)):>12,}"
            )

    # ── 해외 ──────────────────────────────────────────
    o = get_overseas_balance(token)
    _o2 = o.get("output2", {})
    o_summary = _o2[0] if isinstance(_o2, list) else _o2
    o_stocks  = o.get("output1", [])

    print("\n" + "=" * 50)
    print("[ 해외 계좌 ]")
    print(f"  외화 예수금   : $ {float(o_summary.get('frcr_dncl_amt_1', 0)):>14,.2f}")
    print(f"  주식 평가금액  : $ {float(o_summary.get('tot_evlu_pfls_amt', 0)):>14,.2f}")
    print(f"  총 자산       : $ {float(o_summary.get('tot_asst_amt', 0)):>14,.2f}")

    if o_stocks:
        print("\n  [ 보유 해외 주식 ]")
        print(f"  {'종목코드':<10} {'수량':>8} {'평균단가':>12} {'현재가':>12} {'평가손익':>12}")
        print("  " + "-" * 58)
        for s in o_stocks:
            if float(s.get("cblc_qty", 0)) == 0:
                continue
            print(
                f"  {s.get('ovrs_pdno',''):<10}"
                f" {float(s.get('cblc_qty', 0)):>8,.2f}"
                f" {float(s.get('pchs_avg_pric', 0)):>12,.4f}"
                f" {float(s.get('now_pric2', 0)):>12,.4f}"
                f" {float(s.get('evlu_pfls_amt', 0)):>12,.2f}"
            )

    print("=" * 50)


if __name__ == "__main__":
    print_account_summary()
