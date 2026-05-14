"""
한국투자증권 OpenAPI 래퍼
- 인증: 파일 캐싱 (token_cache.json), 만료 시에만 재발급
- 국내주식: 현재가 / 체결내역 / 잔고(평단가)
- 해외주식: 현재가 / 체결내역 / 잔고(평단가)

반환값: 모두 API raw dict 그대로 (output/output1/output2 포함)
"""

import json
import os
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional

import requests
from dotenv import load_dotenv

load_dotenv()

# ─────────────────────────────────────────
# 공통 설정
# ─────────────────────────────────────────
APP_KEY    = os.getenv("KIS_APP_KEY")
APP_SECRET = os.getenv("KIS_APP_SECRET")
ENV        = os.getenv("KIS_ENV", "real")

BASE_URL = (
    "https://openapi.koreainvestment.com:9443"
    if ENV == "real"
    else "https://openapivts.koreainvestment.com:29443"
)

# ─────────────────────────────────────────
# 멀티 계좌 로더
# KIS_ACCOUNT_{N}_CANO / _PRDT_CD / _LABEL 패턴을 자동 수집
# 레거시 단일 계좌 키(KIS_CANO)도 폴백으로 지원
# ─────────────────────────────────────────

def load_accounts() -> list[dict]:
    """
    .env에 등록된 계좌 목록을 반환.
    반환 형태: [{"label": "us_main", "cano": "72854646", "prdt_cd": "01"}, ...]
    """
    accounts = []
    n = 1
    while True:
        cano    = os.getenv(f"KIS_ACCOUNT_{n}_CANO", "").strip()
        prdt_cd = os.getenv(f"KIS_ACCOUNT_{n}_PRDT_CD", "01").strip()
        label   = os.getenv(f"KIS_ACCOUNT_{n}_LABEL", f"account_{n}").strip()
        if not cano:
            break
        accounts.append({"label": label, "cano": cano, "prdt_cd": prdt_cd})
        n += 1

    # 레거시 단일 계좌 폴백
    if not accounts:
        cano = os.getenv("KIS_CANO", "").strip()
        if cano:
            accounts.append({
                "label": "default",
                "cano": cano,
                "prdt_cd": os.getenv("KIS_ACNT_PRDT_CD", "01").strip(),
            })
    return accounts


def get_account(label: str) -> dict:
    """label로 계좌 조회. 없으면 ValueError."""
    for acc in load_accounts():
        if acc["label"] == label:
            return acc
    raise ValueError(f"계좌 '{label}'을 .env에서 찾을 수 없습니다. 등록된 계좌: {[a['label'] for a in load_accounts()]}")


# 기본 계좌 (하위 호환 — 단일 계좌 방식을 쓰는 함수들에서 사용)
def _default_account() -> dict:
    accounts = load_accounts()
    if not accounts:
        raise RuntimeError(".env에 등록된 계좌가 없습니다.")
    return accounts[0]

# 하위 호환용 전역 변수 (단일 계좌 함수들에서 참조)
_acc     = _default_account()
CANO     = _acc["cano"]
ACNT_CD  = _acc["prdt_cd"]

# 토큰 캐시 파일 (스크립트와 같은 폴더)
_TOKEN_FILE = Path(__file__).parent / "token_cache.json"
_FMT = "%Y-%m-%d %H:%M:%S"


# ─────────────────────────────────────────
# 토큰 관리
# ─────────────────────────────────────────

def _load_cached_token() -> tuple[Optional[str], Optional[datetime]]:
    """파일에서 토큰과 만료 시각 로드. 없거나 깨지면 (None, None)."""
    if not _TOKEN_FILE.exists():
        return None, None
    try:
        data = json.loads(_TOKEN_FILE.read_text(encoding="utf-8"))
        token      = data.get("access_token")
        expires_at = datetime.strptime(data["expires_at"], _FMT)
        return token, expires_at
    except Exception:
        return None, None


def _save_token(token: str, expires_at: str) -> None:
    """토큰과 KIS가 반환한 만료 시각 문자열을 파일에 저장."""
    _TOKEN_FILE.write_text(
        json.dumps({"access_token": token, "expires_at": expires_at}, ensure_ascii=False),
        encoding="utf-8",
    )


def _is_valid(expires_at: Optional[datetime]) -> bool:
    """만료 10분 전까지는 유효."""
    if expires_at is None:
        return False
    return datetime.now() < expires_at - timedelta(minutes=10)


def _issue_token() -> str:
    """KIS에서 신규 토큰 발급 후 파일 저장."""
    res = requests.post(
        f"{BASE_URL}/oauth2/tokenP",
        json={
            "grant_type": "client_credentials",
            "appkey": APP_KEY,
            "appsecret": APP_SECRET,
        },
        timeout=10,
    )
    res.raise_for_status()
    data = res.json()
    if "access_token" not in data:
        raise RuntimeError(f"토큰 발급 실패: {data}")

    # KIS 응답: access_token_token_expired = "2025-05-14 10:30:00"
    expires_str = data.get("access_token_token_expired", "")
    _save_token(data["access_token"], expires_str)
    return data["access_token"]


def get_token() -> str:
    """
    유효한 토큰 반환.
    1) 파일 캐시 로드 → 유효하면 반환
    2) 유효하지 않으면 재발급 후 반환
    """
    token, expires_at = _load_cached_token()
    if token and _is_valid(expires_at):
        return token
    return _issue_token()


def _headers(tr_id: str, token: Optional[str] = None) -> dict:
    return {
        "authorization": f"Bearer {token or get_token()}",
        "appkey": APP_KEY,
        "appsecret": APP_SECRET,
        "tr_id": tr_id,
        "content-type": "application/json; charset=utf-8",
    }


def _get(url: str, tr_id: str, params: dict) -> dict:
    """GET 요청 공통 처리 → raw dict 반환"""
    res = requests.get(
        f"{BASE_URL}{url}",
        headers=_headers(tr_id),
        params=params,
        timeout=10,
    )
    res.raise_for_status()
    return res.json()


def _resolve_account(account: "str | dict | None") -> dict:
    """account 파라미터를 dict로 정규화. None이면 첫 번째 계좌 사용."""
    if account is None:
        return _default_account()
    if isinstance(account, str):
        return get_account(account)
    return account


# ══════════════════════════════════════════════════════════════
# 국내주식
# ══════════════════════════════════════════════════════════════

def kr_price(ticker: str, market: str = "J") -> dict:
    """
    [국내주식] 현재가 시세
    ticker : 종목코드 (예: "005930")
    market : J=KRX(기본), NX=NXT, UN=통합

    반환 주요 필드 (output)
        stck_prpr   : 주식 현재가
        prdy_vrss   : 전일 대비
        prdy_ctrt   : 전일 대비율(%)
        stck_oprc   : 시가
        stck_hgpr   : 고가
        stck_lwpr   : 저가
        acml_vol    : 누적 거래량
        per         : PER
        pbr         : PBR
    """
    return _get(
        "/uapi/domestic-stock/v1/quotations/inquire-price",
        "FHKST01010100",
        {"FID_COND_MRKT_DIV_CODE": market, "FID_INPUT_ISCD": ticker},
    )


def kr_daily_ccld(
    start_dt: str,
    end_dt: str,
    side: str = "00",
    ccld_dvsn: str = "01",
    sort: str = "00",
    period: str = "inner",
    account: "str | dict | None" = None,
) -> dict:
    """
    [국내주식] 일별 주문체결 조회
    start_dt / end_dt : YYYYMMDD 형식

    반환 주요 필드 (output1 리스트)
        ord_dt       : 주문 일자
        pdno         : 상품번호(종목코드)
        prdt_name    : 종목명
        sll_buy_dvsn_cd_name : 매도/매수 구분
        ord_qty      : 주문 수량
        ord_unpr     : 주문 단가
        avg_prvs     : 체결 평균가
        tot_ccld_qty : 총 체결 수량
        tot_ccld_amt : 총 체결 금액
        ccld_cndt_name : 체결 조건 (지정가 등)
    """
    acc = _resolve_account(account)
    if period == "inner":
        tr_id = "TTTC0081R" if ENV == "real" else "VTTC0081R"
    else:
        tr_id = "CTSC9215R" if ENV == "real" else "VTSC9215R"

    return _get(
        "/uapi/domestic-stock/v1/trading/inquire-daily-ccld",
        tr_id,
        {
            "CANO": acc["cano"],
            "ACNT_PRDT_CD": acc["prdt_cd"],
            "INQR_STRT_DT": start_dt,
            "INQR_END_DT": end_dt,
            "SLL_BUY_DVSN_CD": side,
            "INQR_DVSN": sort,
            "PDNO": "",
            "CCLD_DVSN": ccld_dvsn,
            "ORD_GNO_BRNO": "",
            "ODNO": "",
            "INQR_DVSN_3": "00",
            "INQR_DVSN_1": "",
            "EXCG_ID_DVSN_CD": "KRX",
            "CTX_AREA_FK100": "",
            "CTX_AREA_NK100": "",
        },
    )


def kr_balance(account: "str | dict | None" = None) -> dict:
    """
    [국내주식] 잔고 조회 (평단가 포함)

    반환 주요 필드
        output1 (보유 종목 리스트)
            pdno          : 종목코드
            prdt_name     : 종목명
            hldg_qty      : 보유 수량
            pchs_avg_pric : 매입 평균가 (평단가)
            prpr          : 현재가
            evlu_pfls_amt : 평가손익
            evlu_erng_rt  : 수익률(%)
        output2 (계좌 요약)
            dnca_tot_amt       : 예수금
            scts_evlu_amt      : 주식 평가금액
            tot_evlu_amt       : 총 평가금액
            evlu_pfls_smtl_amt : 총 평가손익
    """
    acc = _resolve_account(account)
    tr_id = "TTTC8434R" if ENV == "real" else "VTTC8434R"
    return _get(
        "/uapi/domestic-stock/v1/trading/inquire-balance",
        tr_id,
        {
            "CANO": acc["cano"],
            "ACNT_PRDT_CD": acc["prdt_cd"],
            "AFHR_FLPR_YN": "N",
            "OFL_YN": "",
            "INQR_DVSN": "02",
            "UNPR_DVSN": "01",
            "FUND_STTL_ICLD_YN": "N",
            "FNCG_AMT_AUTO_RDPT_YN": "N",
            "PRCS_DVSN": "00",
            "CTX_AREA_FK100": "",
            "CTX_AREA_NK100": "",
        },
    )


def kr_avg_price(ticker: str) -> Optional[str]:
    """
    [국내주식] 특정 종목 평단가만 추출 (잔고 조회 후 필터)
    보유하지 않으면 None 반환
    """
    data = kr_balance()
    for item in data.get("output1", []):
        if item.get("pdno") == ticker and int(item.get("hldg_qty", 0)) > 0:
            return item.get("pchs_avg_pric")
    return None


# ══════════════════════════════════════════════════════════════
# 해외주식
# ══════════════════════════════════════════════════════════════

def us_price(ticker: str, exchange: str = "NAS") -> dict:
    """
    [해외주식] 현재체결가
    ticker   : 종목코드 (예: "AAPL")
    exchange : NAS=나스닥, NYS=뉴욕, AMS=아멕스, HKS=홍콩, SHS=상해, SZS=심천

    반환 주요 필드 (output)
        last   : 현재가
        diff   : 전일 대비
        rate   : 등락률(%)
        open   : 시가
        high   : 고가
        low    : 저가
        tvol   : 거래량
        pbr    : PBR
        per    : PER
    """
    return _get(
        "/uapi/overseas-price/v1/quotations/price",
        "HHDFS00000300",
        {"AUTH": "", "EXCD": exchange, "SYMB": ticker},
    )


def us_daily_ccnl(
    start_dt: str,
    end_dt: str,
    side: str = "00",
    ccld: str = "00",
    sort: str = "DS",
    exchange: str = "NASD",
    account: "str | dict | None" = None,
) -> dict:
    """
    [해외주식] 주문체결 내역 조회
    start_dt / end_dt : YYYYMMDD 형식 (현지시각 기준)

    반환 주요 필드 (output 리스트)
        ord_dt         : 주문 일자
        ovrs_pdno      : 종목코드
        ovrs_item_name : 종목명
        sll_buy_dvsn_cd: 매도(01)/매수(02) 구분
        ft_ord_qty     : 주문 수량
        ft_ord_unpr3   : 주문 단가
        ft_ccld_qty    : 체결 수량
        ft_ccld_unpr3  : 체결 단가
        ft_ccld_amt3   : 체결 금액 (달러)
        ovrs_excg_cd   : 거래소 코드
        tr_crcy_cd     : 통화
        ccld_cndt_name : 체결 조건
    """
    acc = _resolve_account(account)
    tr_id = "TTTS3035R" if ENV == "real" else "VTTS3035R"
    return _get(
        "/uapi/overseas-stock/v1/trading/inquire-ccnl",
        tr_id,
        {
            "CANO": acc["cano"],
            "ACNT_PRDT_CD": acc["prdt_cd"],
            "PDNO": "%",          # 전종목 (모의는 "" 필요)
            "ORD_STRT_DT": start_dt,
            "ORD_END_DT": end_dt,
            "SLL_BUY_DVSN": side,
            "CCLD_NCCS_DVSN": ccld,
            "OVRS_EXCG_CD": exchange,
            "SORT_SQN": sort,
            "ORD_DT": "",
            "ORD_GNO_BRNO": "",
            "ODNO": "",
            "CTX_AREA_NK200": "",
            "CTX_AREA_FK200": "",
        },
    )


def us_balance(exchange: str = "NASD", currency: str = "USD", account: "str | dict | None" = None) -> dict:
    """
    [해외주식] 잔고 조회 (평단가 포함)
    exchange : NASD=미국전체(실전), NASD=나스닥(모의)
    currency : USD, HKD, CNY, JPY, VND

    반환 주요 필드
        output1 (보유 종목 리스트)
            ovrs_pdno       : 종목코드
            ovrs_item_name  : 종목명
            cblc_qty        : 잔고 수량
            pchs_avg_pric   : 매입 평균가 (평단가)
            now_pric2       : 현재가
            evlu_pfls_amt   : 평가손익
            evlu_erng_rt    : 수익률(%)
            tr_crcy_cd      : 통화
        output2 (계좌 요약)
            frcr_dncl_amt_1 : 외화 예수금
            tot_evlu_pfls_amt : 총 평가손익
            tot_asst_amt    : 총 자산
    """
    acc = _resolve_account(account)
    tr_id = "TTTS3012R" if ENV == "real" else "VTTS3012R"
    return _get(
        "/uapi/overseas-stock/v1/trading/inquire-balance",
        tr_id,
        {
            "CANO": acc["cano"],
            "ACNT_PRDT_CD": acc["prdt_cd"],
            "OVRS_EXCG_CD": exchange,
            "TR_CRCY_CD": currency,
            "CTX_AREA_FK200": "",
            "CTX_AREA_NK200": "",
        },
    )


def us_avg_price(ticker: str) -> Optional[str]:
    """
    [해외주식] 특정 종목 평단가만 추출 (잔고 조회 후 필터)
    보유하지 않으면 None 반환
    """
    data = us_balance()
    for item in data.get("output1", []):
        if item.get("ovrs_pdno") == ticker and float(item.get("cblc_qty", 0)) > 0:
            return item.get("pchs_avg_pric")
    return None


# ══════════════════════════════════════════════════════════════
# 주문 공통 POST
# ══════════════════════════════════════════════════════════════

def _post(url: str, tr_id: str, body: dict) -> dict:
    """POST 요청 공통 처리 → raw dict 반환"""
    res = requests.post(
        f"{BASE_URL}{url}",
        headers=_headers(tr_id),
        json=body,
        timeout=10,
    )
    res.raise_for_status()
    return res.json()


# ══════════════════════════════════════════════════════════════
# 국내주식 주문
# ══════════════════════════════════════════════════════════════

def kr_order(
    ticker: str,
    side: str,
    qty: int,
    price: int = 0,
    ord_dvsn: str = "00",
    account: "str | dict | None" = None,
) -> dict:
    """
    [국내주식] 주문 (매수/매도)
    side     : "BUY" | "SELL"
    qty      : 주문 수량
    price    : 주문 단가 (지정가 시 필수, 시장가·LOC 등은 0)
    ord_dvsn : 00=지정가, 01=시장가, 05=장전시간외, 06=장후시간외
               13=최유리지정가, 14=최우선지정가

    반환 주요 필드 (output)
        KRX_FWDG_ORD_ORGNO : 주문 기관 번호
        ODNO               : 주문 번호
        ORD_TMD            : 주문 시각
    """
    acc = _resolve_account(account)
    if side == "BUY":
        tr_id = "TTTC0802U" if ENV == "real" else "VTTC0802U"
    else:
        tr_id = "TTTC0801U" if ENV == "real" else "VTTC0801U"

    return _post(
        "/uapi/domestic-stock/v1/trading/order-cash",
        tr_id,
        {
            "CANO": acc["cano"],
            "ACNT_PRDT_CD": acc["prdt_cd"],
            "PDNO": ticker,
            "ORD_DVSN": ord_dvsn,
            "ORD_QTY": str(qty),
            "ORD_UNPR": str(price),
        },
    )


def kr_cancel_order(
    org_no: str,
    ord_no: str,
    qty: int,
    price: int = 0,
    ord_dvsn: str = "00",
    qty_all_yn: str = "Y",
    account: "str | dict | None" = None,
) -> dict:
    """
    [국내주식] 주문 취소/정정
    org_no     : KRX_FWDG_ORD_ORGNO (주문 기관 번호)
    ord_no     : ODNO (원주문 번호)
    qty        : 취소 수량 (qty_all_yn="Y" 이면 무시)
    price      : 정정 단가 (취소 시 0)
    ord_dvsn   : 원주문과 동일하게 맞춤
    qty_all_yn : Y=전량취소, N=부분취소

    반환: kr_order와 동일 구조
    """
    acc = _resolve_account(account)
    tr_id = "TTTC0803U" if ENV == "real" else "VTTC0803U"
    return _post(
        "/uapi/domestic-stock/v1/trading/order-rvsecncl",
        tr_id,
        {
            "CANO": acc["cano"],
            "ACNT_PRDT_CD": acc["prdt_cd"],
            "KRX_FWDG_ORD_ORGNO": org_no,
            "ORGN_ODNO": ord_no,
            "ORD_DVSN": ord_dvsn,
            "RVSE_CNCL_DVSN_CD": "02",   # 02=취소
            "ORD_QTY": str(qty),
            "ORD_UNPR": str(price),
            "QTY_ALL_ORD_YN": qty_all_yn,
        },
    )


def kr_open_orders(account: "str | dict | None" = None) -> dict:
    """
    [국내주식] 미체결 주문 조회

    반환 주요 필드 (output1 리스트)
        odno           : 주문 번호
        ord_tmd        : 주문 시각
        pdno           : 종목코드
        prdt_name      : 종목명
        sll_buy_dvsn_cd_name : 매도/매수 구분
        ord_qty        : 주문 수량
        ord_unpr       : 주문 단가
        rmn_qty        : 잔여 수량
        ccld_qty       : 체결 수량
        ord_dvsn_name  : 주문 구분명
        krx_fwdg_ord_orgno : 기관 번호 (취소 시 필요)
    """
    acc = _resolve_account(account)
    tr_id = "TTTC8036R" if ENV == "real" else "VTTC8036R"
    return _get(
        "/uapi/domestic-stock/v1/trading/inquire-psbl-rvsecncl",
        tr_id,
        {
            "CANO": acc["cano"],
            "ACNT_PRDT_CD": acc["prdt_cd"],
            "CTX_AREA_FK100": "",
            "CTX_AREA_NK100": "",
            "INQR_DVSN_1": "",
            "INQR_DVSN_2": "",
        },
    )


# ══════════════════════════════════════════════════════════════
# 해외주식 주문
# ══════════════════════════════════════════════════════════════

def us_order(
    ticker: str,
    exchange: str,
    side: str,
    qty: int,
    price: float = 0.0,
    ord_dvsn: str = "00",
    account: "str | dict | None" = None,
) -> dict:
    """
    [해외주식] 주문 (매수/매도)
    ticker   : 종목코드 (예: "SOXL")
    exchange : NASD=나스닥, NYSE=뉴욕, AMEX=아멕스
    side     : "BUY" | "SELL"
    qty      : 주문 수량
    price    : 주문 단가 (LOC/MOC는 0)
    ord_dvsn : 00=지정가, 32=MOC(시장가마감), 34=LOC(지정가마감)

    반환 주요 필드 (output)
        KRX_FWDG_ORD_ORGNO : 주문 기관 번호
        ODNO               : 주문 번호
        ORD_TMD            : 주문 시각
    """
    acc = _resolve_account(account)
    if side == "BUY":
        tr_id = "TTTS0308U" if ENV == "real" else "VTTS0308U"
    else:
        tr_id = "TTTS0307U" if ENV == "real" else "VTTS0307U"

    return _post(
        "/uapi/overseas-stock/v1/trading/order",
        tr_id,
        {
            "CANO": acc["cano"],
            "ACNT_PRDT_CD": acc["prdt_cd"],
            "OVRS_EXCG_CD": exchange,
            "PDNO": ticker,
            "ORD_DVSN": ord_dvsn,
            "ORD_QTY": str(qty),
            "OVRS_ORD_UNPR": f"{price:.2f}",
            "ORD_SVR_DVSN_CD": "0",
        },
    )


def us_cancel_order(
    org_no: str,
    ord_no: str,
    ticker: str,
    exchange: str,
    qty: int,
    price: float = 0.0,
    ord_dvsn: str = "00",
    qty_all_yn: str = "Y",
    account: "str | dict | None" = None,
) -> dict:
    """
    [해외주식] 주문 취소/정정
    org_no     : KRX_FWDG_ORD_ORGNO
    ord_no     : ODNO (원주문 번호)
    ticker     : 종목코드
    exchange   : NASD / NYSE / AMEX
    qty        : 취소 수량 (qty_all_yn="Y" 이면 무시)
    price      : 정정 단가 (취소 시 0)
    ord_dvsn   : 원주문과 동일
    qty_all_yn : Y=전량, N=부분

    반환: us_order와 동일 구조
    """
    acc = _resolve_account(account)
    tr_id = "TTTS0309U" if ENV == "real" else "VTTS0309U"
    return _post(
        "/uapi/overseas-stock/v1/trading/order-rvsecncl",
        tr_id,
        {
            "CANO": acc["cano"],
            "ACNT_PRDT_CD": acc["prdt_cd"],
            "OVRS_EXCG_CD": exchange,
            "PDNO": ticker,
            "ORGN_ODNO": ord_no,
            "ORD_SVR_DVSN_CD": "0",
            "RVSE_CNCL_DVSN_CD": "02",   # 02=취소
            "ORD_QTY": str(qty),
            "OVRS_ORD_UNPR": f"{price:.2f}",
            "QTY_ALL_ORD_YN": qty_all_yn,
        },
    )


def us_open_orders(
    exchange: str = "NASD",
    account: "str | dict | None" = None,
) -> dict:
    """
    [해외주식] 미체결 주문 조회

    반환 주요 필드 (output 리스트)
        odno               : 주문 번호
        ord_tmd            : 주문 시각
        ovrs_pdno          : 종목코드
        ovrs_item_name     : 종목명
        sll_buy_dvsn_cd    : 매도(01)/매수(02)
        ft_ord_qty         : 주문 수량
        ft_ord_unpr3       : 주문 단가
        nccs_qty           : 미체결 수량
        ovrs_excg_cd       : 거래소 코드
        krx_fwdg_ord_orgno : 기관 번호 (취소 시 필요)
    """
    acc = _resolve_account(account)
    tr_id = "TTTS3018R" if ENV == "real" else "VTTS3018R"
    return _get(
        "/uapi/overseas-stock/v1/trading/inquire-nccs",
        tr_id,
        {
            "CANO": acc["cano"],
            "ACNT_PRDT_CD": acc["prdt_cd"],
            "OVRS_EXCG_CD": exchange,
            "SORT_SQN": "DS",
            "CTX_AREA_FK200": "",
            "CTX_AREA_NK200": "",
        },
    )


# ══════════════════════════════════════════════════════════════
# 빠른 확인용 (직접 실행 시)
# ══════════════════════════════════════════════════════════════

if __name__ == "__main__":
    import sys, json
    sys.stdout.reconfigure(encoding="utf-8")
    today = datetime.today().strftime("%Y%m%d")
    week_ago = (datetime.today() - timedelta(days=7)).strftime("%Y%m%d")

    print("=== [국내] 삼성전자 현재가 ===")
    print(json.dumps(kr_price("005930"), ensure_ascii=False, indent=2))

    print("\n=== [국내] 잔고 (평단가 포함) ===")
    print(json.dumps(kr_balance(), ensure_ascii=False, indent=2))

    print(f"\n=== [국내] 체결내역 ({week_ago}~{today}) ===")
    print(json.dumps(kr_daily_ccld(week_ago, today), ensure_ascii=False, indent=2))

    print("\n=== [해외] AAPL 현재가 ===")
    print(json.dumps(us_price("AAPL", "NAS"), ensure_ascii=False, indent=2))

    print("\n=== [해외] 잔고 (평단가 포함) ===")
    print(json.dumps(us_balance(), ensure_ascii=False, indent=2))

    print(f"\n=== [해외] 체결내역 ({week_ago}~{today}) ===")
    print(json.dumps(us_daily_ccnl(week_ago, today), ensure_ascii=False, indent=2))
