"""
SOXL V4.0 무한매수법 실전 서버 스크립트.

- 일반모드: 전반전(T<10) 0.5포션×2, 후반전(10≤T<20) 1포션, 쿼터매도+최종매도
- 리버스모드: T>19 진입, 5MA 기반 매도/매수, 종가≥평단×0.80 복귀
- 큰수매수/매도거부: 전일종가×1.10 캡
- 한투 API LOC/지정가/MOC 주문
- 디스코드 웹훅 알림
"""

from dataclasses import dataclass, field
from datetime import datetime, timedelta
import argparse
import json
import math
import os
import time

import pandas_market_calendars as mcal
import pytz
import requests

try:
    from sheets_backend import load_sheets_backend_from_env
    _SHEETS_AVAILABLE = True
except ImportError:
    _SHEETS_AVAILABLE = False

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_TZ_NEW_YORK = pytz.timezone("America/New_York")

COMMISSION = 0.0025
KIS_BASE_URL = "https://openapi.koreainvestment.com:9443"
TARGET_SYMBOL = "SOXL"
N_SPLITS = 20
PROFIT_TARGET_PCT = 0.20  # +20% 최종매도
REVERSE_RECOVERY_PCT = 0.80  # 종가 ≥ 평단 × 0.80 → 일반모드 복귀
LOC_CAP_MULT = 1.10  # 전일종가 × 1.10
CRASH_PROTECTION_MAX_DROP_PCT = 0.30  # 폭락 대비: 기본가 × (1-0.30) 까지 추가 LOC 생성
CRASH_PROTECTION_MAX_ORDERS = 20      # 폭락 대비 추가 주문 최대 개수
DEFAULT_ACCOUNT_NO = "72854646-01"
STATE_FILE = "soxl_v4_state.json"
LOG_FILE = "soxl_v4_log.jsonl"
_sheets = None  # SheetsBackend singleton; initialized in send_startup_healthcheck
_US_EXCHANGE_CODE_MAP = {
    "SOXL": ("AMEX", "AMS"),
    "TQQQ": ("NASD", "NAS"),
}
US_ORDER_EXCHANGE_CODE, US_QUOTE_EXCHANGE_CODE = _US_EXCHANGE_CODE_MAP.get(
    TARGET_SYMBOL,
    ("NASD", "NAS"),
)


# ─────────────────────────────────────────────
# V4 상태 구조체
# ─────────────────────────────────────────────

@dataclass
class V4State:
    cycle_capital: float = 0.0
    T: float = 0.0
    shares: int = 0
    avg_cost: float = 0.0
    cash: float = 0.0
    mode: str = "normal"  # "normal" | "reverse"
    reverse_day: int = 0
    close_history: list = field(default_factory=list)  # 최근 5일 종가


@dataclass
class PlannedOrder:
    side: str  # "BUY" | "SELL"
    quantity: int
    price: float
    amount: float
    reason: str
    ord_dvsn: str = "34"  # 34=LOC, 00=지정가, 32=MOC


@dataclass
class TradingPlan:
    current_price: float
    prev_close: float
    mode: str
    T: float
    orders: list[PlannedOrder] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)


@dataclass
class StrategyTracker:
    cycle_no: int = 1
    cycle_start_capital: float = 0.0
    T: float = 0.0
    mode: str = "normal"
    reverse_day: int = 0
    close_history: list = field(default_factory=list)
    last_shares: float = 0.0
    last_premarket_notice_date: str = ""
    last_status_notice_at: str = ""
    last_order_submission_date: str = ""
    last_sell_order_submission_date: str = ""
    last_buy_order_submission_date: str = ""
    last_post_close_report_date: str = ""
    last_intraday_open_notice_date: str = ""
    last_buy_skip_notice_date: str = ""
    last_no_order_notice_date: str = ""
    cached_access_token: str = ""
    cached_token_expires_at: str = ""
    last_holiday_date: str = ""
    last_fill_sync_date: str = ""


@dataclass
class KisCredentials:
    app_key: str
    app_secret: str


@dataclass
class AccountSnapshot:
    checked_at: str
    shares: float
    orderable_qty: float
    avg_price: float
    current_price: float
    prev_close: float
    market_value: float
    stock_pnl_amount: float
    stock_pnl_rate: float
    remaining_cash: float
    total_assets: float
    total_pnl_amount: float


# ─────────────────────────────────────────────
# 유틸리티
# ─────────────────────────────────────────────

def to_float(value, default=0.0):
    if value in (None, "", " "):
        return default
    try:
        return float(str(value).replace(",", ""))
    except (TypeError, ValueError):
        return default


def now_ny():
    return datetime.now(_TZ_NEW_YORK)


def _section(label):
    return f"\n━━━━━━━━━━ {label} ━━━━━━━━━━"


def format_webhook_message(title, lines, status="INFO"):
    timestamp = now_ny().strftime("%m-%d %H:%M")
    header = f"[{timestamp} NY] [{status}] {title}"
    body = "\n".join(lines) if lines else ""
    return f"{header}\n{body}" if body else header


def format_signed_pct(value):
    return f"{value:+.2f}%"


def format_signed_amount(value, currency="$"):
    return f"{currency}{value:+,.2f}"


def get_strategy_equity(snapshot):
    return snapshot.remaining_cash + snapshot.market_value


def estimate_shares(amount, price):
    """매수 수량 계산: 내림(floor) 기준."""
    if amount <= 0 or price <= 0:
        return 0
    raw = (amount * (1 - COMMISSION)) / price
    qty = int(math.floor(raw))
    if qty < 1 and raw > 0:
        qty = 1
    return qty


def required_cash_for_shares(price, qty):
    if price <= 0 or qty <= 0:
        return 0.0
    return (price * qty) / (1 - COMMISSION)


def round_half_step(value):
    if value <= 0:
        return 0.0
    return round(value * 2) / 2


def calc_buy_qty_from_budget(budget, price):
    if budget <= 0 or price <= 0:
        return 0
    return estimate_shares(budget, price)


def generate_crash_protection_orders(
    budget,
    base_price,
    base_qty,
    cash_remaining=None,
    max_drop_pct=CRASH_PROTECTION_MAX_DROP_PCT,
    max_orders=CRASH_PROTECTION_MAX_ORDERS,
):
    """폭락장 대비 추가 매수 LOC 주문 생성.

    원리: 기본 매수(base_qty 주 @ base_price)를 걸어둔 상태에서 종가가 폭락하면
    수량 잔여가 발생한다. 이를 보완하기 위해 한 주씩 늘려가며 매수가를 낮춘
    추가 LOC 주문을 만든다. 종가가 어디로 떨어지든 1포션 budget을 최대한
    소진하도록 설계.

    매수가 산정: budget × (1 - COMMISSION) / qty 를 0.01 단위로 내림 → 종가가
    그 가격 이하로 떨어져 모든 LOC가 종가에 체결되어도 결제액(커미션 포함)이
    budget을 넘지 않음.

    Args:
        budget: 해당 매수 슬롯의 1회 매수금 (USD, 커미션 포함 전)
        base_price: 기본 매수가 (예: 별지점-$0.01 또는 cap_price)
        base_qty: 기본 수량
        cash_remaining: 실제 가용 현금. None이면 budget을 그대로 사용.
        max_drop_pct: 기본가 대비 최대 폭락 폭 (0.30 = 30%)
        max_orders: 추가 주문 최대 개수 (한투 API 부담 고려)

    Returns:
        list of (price, qty) — 각 추가 LOC 주문 (qty는 항상 1)
    """
    if budget <= 0 or base_price <= 0 or base_qty <= 0:
        return []

    effective_cash = cash_remaining if cash_remaining is not None else budget
    if effective_cash <= 0:
        return []

    additional = []
    qty = base_qty + 1
    min_price = base_price * (1 - max_drop_pct)
    # 안전장치: 무한 루프 방지
    hard_limit = base_qty + max_orders * 5

    while len(additional) < max_orders and qty <= hard_limit:
        # qty주 모두 종가에 체결되어도 결제액이 budget 이내가 되도록
        max_price_for_qty = budget * (1 - COMMISSION) / qty
        # 0.01 단위로 내림 (LOC 가격은 더 낮을수록 보수적)
        price = math.floor(max_price_for_qty * 100) / 100

        if price <= 0:
            break
        if price < min_price:
            # 폭락 범위를 넘었으므로 종료
            break
        if price >= base_price:
            # 기본 매수가보다 같거나 위이면 의미 없음 → 수량 늘려서 다시
            qty += 1
            continue

        # 누적 결제액(커미션 포함)이 가용 현금을 초과하면 중단
        cumulative_settle = required_cash_for_shares(price, qty)
        if cumulative_settle > effective_cash:
            break

        additional.append((round(price, 2), 1))
        qty += 1

    return additional


def calc_fractional_sell_qty(shares, ratio, min_one=True):
    if shares <= 0 or ratio <= 0:
        return 0
    qty = int(math.floor(shares * ratio))
    if min_one and qty <= 0:
        qty = 1
    return min(qty, shares)


def cap_orderable_qty(qty, orderable_qty):
    if qty <= 0 or orderable_qty <= 0:
        return 0
    return min(int(qty), int(orderable_qty))


def infer_cycle_capital_from_snapshot(snapshot):
    deployed_cash = required_cash_for_shares(snapshot.avg_price, int(snapshot.shares))
    return max(snapshot.remaining_cash + deployed_cash, deployed_cash)


def strategy_avg_cost(raw_avg_price):
    if raw_avg_price <= 0:
        return 0.0
    return raw_avg_price / (1 - COMMISSION)


# ─────────────────────────────────────────────
# V4 전략 계산
# ─────────────────────────────────────────────

def star_pct(T):
    """별% = (20 - 2T)%"""
    return (N_SPLITS - 2 * T) / 100.0


def star_price(avg_cost, T):
    """별지점 = 평단가 × (1 + 별%)"""
    return avg_cost * (1 + star_pct(T))


def buy_point(avg_cost, T):
    """매수점 = 별지점 - $0.01"""
    return round(star_price(avg_cost, T) - 0.01, 2)


def portion_amount(cash, T):
    """1회 매수금 = 잔금 / (N - T)"""
    divisor = N_SPLITS - T
    if divisor <= 0:
        return 0.0
    return cash / divisor


def calc_5ma(close_history):
    """직전 5거래일 종가 평균"""
    if len(close_history) < 5:
        return sum(close_history) / len(close_history) if close_history else 0.0
    return sum(close_history[-5:]) / 5


def is_front_half(T):
    """전반전: 0 < T < 10"""
    return 0 < T < N_SPLITS / 2


def is_back_half(T):
    """후반전: 10 ≤ T < 20"""
    return N_SPLITS / 2 <= T < N_SPLITS


def should_enter_reverse(T):
    """리버스 진입: T > 19"""
    return T > N_SPLITS - 1


def should_exit_reverse(close_price, avg_cost):
    """리버스 복귀: 종가 ≥ 평단 × 0.80"""
    return close_price >= avg_cost * REVERSE_RECOVERY_PCT


def t_after_quarter_sell(T):
    """쿼터매도 체결 후 T"""
    return T * 0.75


def t_after_final_sell(T):
    """최종매도(지정가) 체결 후 T (3/4 매도)"""
    return T * 0.25


def t_after_reverse_sell(T):
    """리버스 매도 체결 후 T"""
    return T * 0.9


def t_after_reverse_buy(T):
    """리버스 매수 체결 후 T"""
    return T + (N_SPLITS - T) * 0.25


# ─────────────────────────────────────────────
# .env / 인증 / API
# ─────────────────────────────────────────────

def load_env_file(env_path=None):
    if env_path is None:
        env_path = os.path.join(_SCRIPT_DIR, ".env")
    env_map = {}
    if not os.path.exists(env_path):
        return env_map
    with open(env_path, "r", encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            env_map[key.strip()] = value.strip().strip('"').strip("'")
    return env_map


def load_kis_credentials(env_path=None):
    env_map = load_env_file(env_path)
    app_key = env_map.get("HTHONGIN_APP_KEY") or os.getenv("HTHONGIN_APP_KEY")
    app_secret = env_map.get("HTHONGIN_APP_SECRET") or os.getenv("HTHONGIN_APP_SECRET")
    if not app_key or not app_secret:
        raise ValueError("한투 API 앱키/시크릿을 .env 또는 환경변수에서 찾지 못했습니다.")
    return KisCredentials(app_key=app_key, app_secret=app_secret)


def load_discord_webhook_url(env_path=None):
    env_map = load_env_file(env_path)
    webhook_url = (
        env_map.get("DISCORD_WEBHOOK_URL")
        or env_map.get("DISCORD_WEB_HOOK_URL")
        or env_map.get("DISCORD_WEB_HOCK")
        or os.getenv("DISCORD_WEBHOOK_URL")
    )
    if not webhook_url:
        raise ValueError("디스코드 웹훅 URL을 .env 또는 환경변수에서 찾지 못했습니다.")
    return webhook_url


def normalize_account_no(account_no):
    raw = str(account_no or "").strip().replace(" ", "")
    if not raw:
        return ""
    if "-" in raw:
        cano, acnt_prdt_cd = raw.split("-", 1)
        cano = cano.strip()
        acnt_prdt_cd = acnt_prdt_cd.strip()
        if cano and acnt_prdt_cd:
            return f"{cano}-{acnt_prdt_cd}"
        raise ValueError(f"계좌번호 형식이 올바르지 않습니다: {account_no}")

    digits_only = "".join(ch for ch in raw if ch.isdigit())
    if len(digits_only) >= 10:
        return f"{digits_only[:8]}-{digits_only[8:10]}"

    raise ValueError(f"계좌번호 형식이 올바르지 않습니다: {account_no}")


def split_account_no(account_no):
    normalized = normalize_account_no(account_no)
    return normalized.split("-", 1)


def load_account_no(env_path=None):
    env_map = load_env_file(env_path)
    account_no = (
        env_map.get("HTHONGIN_ACCOUNT_NO")
        or env_map.get("KIS_ACCOUNT_NO")
        or env_map.get("ACCOUNT_NO")
        or env_map.get("KR_ACCOUNT_NO")
        or os.getenv("HTHONGIN_ACCOUNT_NO")
        or os.getenv("KIS_ACCOUNT_NO")
        or os.getenv("ACCOUNT_NO")
        or os.getenv("KR_ACCOUNT_NO")
    )

    if not account_no:
        cano = (
            env_map.get("HTHONGIN_CANO")
            or env_map.get("KIS_CANO")
            or env_map.get("CANO")
            or os.getenv("HTHONGIN_CANO")
            or os.getenv("KIS_CANO")
            or os.getenv("CANO")
        )
        acnt_prdt_cd = (
            env_map.get("HTHONGIN_ACNT_PRDT_CD")
            or env_map.get("KIS_ACNT_PRDT_CD")
            or env_map.get("ACNT_PRDT_CD")
            or env_map.get("ACCOUNT_PRODUCT_CODE")
            or os.getenv("HTHONGIN_ACNT_PRDT_CD")
            or os.getenv("KIS_ACNT_PRDT_CD")
            or os.getenv("ACNT_PRDT_CD")
            or os.getenv("ACCOUNT_PRODUCT_CODE")
        )
        if cano and acnt_prdt_cd:
            account_no = f"{str(cano).strip()}-{str(acnt_prdt_cd).strip()}"

    if not account_no:
        account_no = (
            env_map.get("HTHONGIN_DEFAULT_ACCOUNT_NO")
            or env_map.get("DEFAULT_ACCOUNT_NO")
            or os.getenv("HTHONGIN_DEFAULT_ACCOUNT_NO")
            or os.getenv("DEFAULT_ACCOUNT_NO")
            or DEFAULT_ACCOUNT_NO
        )
    return normalize_account_no(account_no)


def issue_kis_access_token(credentials):
    response = requests.post(
        f"{KIS_BASE_URL}/oauth2/tokenP",
        headers={"content-type": "application/json; charset=utf-8"},
        json={
            "grant_type": "client_credentials",
            "appkey": credentials.app_key,
            "appsecret": credentials.app_secret,
        },
        timeout=30,
    )
    response.raise_for_status()
    payload = response.json()
    access_token = payload.get("access_token")
    if not access_token:
        raise RuntimeError(f"접근토큰 발급 실패: {payload}")
    return access_token


def get_or_refresh_access_token(credentials, tracker, state_path):
    if tracker.cached_access_token and tracker.cached_token_expires_at:
        try:
            expires_at = datetime.fromisoformat(tracker.cached_token_expires_at)
            if now_ny() < expires_at - timedelta(minutes=5):
                return tracker.cached_access_token
        except (ValueError, TypeError):
            pass
    access_token = issue_kis_access_token(credentials)
    tracker.cached_access_token = access_token
    tracker.cached_token_expires_at = (now_ny() + timedelta(hours=23)).isoformat()
    save_strategy_tracker(state_path, tracker)
    return access_token


def build_kis_headers(credentials, access_token, tr_id):
    return {
        "content-type": "application/json; charset=utf-8",
        "authorization": f"Bearer {access_token}",
        "appkey": credentials.app_key,
        "appsecret": credentials.app_secret,
        "tr_id": tr_id,
        "custtype": "P",
    }


def request_kis_json(method, path, headers, params=None, json_body=None):
    response = requests.request(
        method=method,
        url=f"{KIS_BASE_URL}{path}",
        headers=headers,
        params=params,
        json=json_body,
        timeout=30,
    )
    response.raise_for_status()
    payload = response.json()
    if payload.get("rt_cd") != "0":
        raise RuntimeError(f"KIS API 실패: {payload.get('msg_cd')} {payload.get('msg1')}")
    return payload


def get_first_positive_value(mapping, keys):
    if not isinstance(mapping, dict):
        return 0.0, None
    for key in keys:
        value = to_float(mapping.get(key))
        if value > 0:
            return value, key
    return 0.0, None


def get_stock_quote(credentials=None, access_token=None):
    """현재가 + 전일종가 조회"""
    credentials = credentials or load_kis_credentials()
    access_token = access_token or issue_kis_access_token(credentials)

    price_headers = build_kis_headers(credentials, access_token, "HHDFS00000300")
    price_payload = request_kis_json(
        "GET",
        "/uapi/overseas-price/v1/quotations/price",
        headers=price_headers,
        params={"AUTH": "", "EXCD": US_QUOTE_EXCHANGE_CODE, "SYMB": TARGET_SYMBOL},
    )
    output = price_payload.get("output") or {}
    current_price, _ = get_first_positive_value(
        output,
        ["last", "stck_prpr", "ovrs_nmix_prpr", "base", "pbas"],
    )
    if current_price <= 0:
        raise RuntimeError(
            f"{TARGET_SYMBOL} 현재가 조회 실패: EXCD={US_QUOTE_EXCHANGE_CODE}, payload={price_payload}"
        )

    today_str = now_ny().strftime("%Y%m%d")
    hist_headers = build_kis_headers(credentials, access_token, "HHDFS76240000")
    hist_payload = request_kis_json(
        "GET",
        "/uapi/overseas-price/v1/quotations/dailyprice",
        headers=hist_headers,
        params={
            "AUTH": "", "EXCD": US_QUOTE_EXCHANGE_CODE, "SYMB": TARGET_SYMBOL,
            "GUBN": "0", "BYMD": today_str, "MODP": "0",
        },
    )
    rows = hist_payload.get("output2") or []
    prev_close = next((to_float(r.get("clos")) for r in rows if to_float(r.get("clos")) > 0), 0.0)
    if prev_close <= 0:
        raise RuntimeError(
            f"{TARGET_SYMBOL} 전일종가 조회 실패: EXCD={US_QUOTE_EXCHANGE_CODE}, payload={hist_payload}"
        )

    return current_price, prev_close


def get_recent_closes(credentials=None, access_token=None, count=5):
    """최근 N거래일 종가 리스트 반환 (5MA 계산용)"""
    credentials = credentials or load_kis_credentials()
    access_token = access_token or issue_kis_access_token(credentials)
    today_str = now_ny().strftime("%Y%m%d")
    headers = build_kis_headers(credentials, access_token, "HHDFS76240000")
    payload = request_kis_json(
        "GET",
        "/uapi/overseas-price/v1/quotations/dailyprice",
        headers=headers,
        params={
            "AUTH": "", "EXCD": US_QUOTE_EXCHANGE_CODE, "SYMB": TARGET_SYMBOL,
            "GUBN": "0", "BYMD": today_str, "MODP": "0",
        },
    )
    rows = payload.get("output2") or []
    closes = []
    for r in rows:
        c = to_float(r.get("clos"))
        if c > 0:
            closes.append(c)
        if len(closes) >= count:
            break
    return closes


def inquire_present_balance(account_no, credentials=None, access_token=None):
    credentials = credentials or load_kis_credentials()
    access_token = access_token or issue_kis_access_token(credentials)
    cano, acnt_prdt_cd = split_account_no(account_no)
    headers = build_kis_headers(credentials, access_token, "CTRP6504R")
    return request_kis_json(
        "GET",
        "/uapi/overseas-stock/v1/trading/inquire-present-balance",
        headers=headers,
        params={
            "CANO": cano, "ACNT_PRDT_CD": acnt_prdt_cd,
            "WCRC_FRCR_DVSN_CD": "02", "NATN_CD": "840",
            "TR_MKET_CD": "00", "INQR_DVSN_CD": "00",
        },
    )


def build_account_snapshot(account_no, credentials=None, access_token=None):
    credentials = credentials or load_kis_credentials()
    access_token = access_token or issue_kis_access_token(credentials)
    current_price, prev_close = get_stock_quote(credentials, access_token)
    balance = inquire_present_balance(account_no, credentials, access_token)

    output1 = balance.get("output1") or []
    output2 = balance.get("output2") or []
    output3 = balance.get("output3") or {}

    symbol_row = next((item for item in output1 if item.get("pdno") == TARGET_SYMBOL), None)
    usd_row = next((item for item in output2 if item.get("crcy_cd") == "USD"), None)

    shares = to_float(symbol_row.get("ccld_qty_smtl1") if symbol_row else 0)
    avg_price = to_float(symbol_row.get("avg_unpr3") if symbol_row else 0)
    market_value = to_float(
        symbol_row.get("frcr_evlu_amt2") if symbol_row else shares * current_price,
        shares * current_price,
    )
    remaining_cash = to_float(
        usd_row.get("frcr_drwg_psbl_amt_1") if usd_row else 0,
        to_float(usd_row.get("frcr_dncl_amt_2") if usd_row else 0),
    )
    total_assets = remaining_cash + market_value
    stock_pnl_amount = to_float(symbol_row.get("evlu_pfls_amt2") if symbol_row else 0)
    total_pnl_amount = to_float(output3.get("evlu_pfls_amt_smtl"), stock_pnl_amount)

    return AccountSnapshot(
        checked_at=now_ny().strftime("%Y-%m-%d %H:%M:%S %Z"),
        shares=shares,
        orderable_qty=to_float(symbol_row.get("ord_psbl_qty1") if symbol_row else 0),
        avg_price=avg_price,
        current_price=current_price,
        prev_close=prev_close,
        market_value=market_value,
        stock_pnl_amount=stock_pnl_amount,
        stock_pnl_rate=to_float(symbol_row.get("evlu_pfls_rt1") if symbol_row else 0),
        remaining_cash=remaining_cash,
        total_assets=total_assets,
        total_pnl_amount=total_pnl_amount,
    )


# ─────────────────────────────────────────────
# 주문 생성/제출
# ─────────────────────────────────────────────

def format_order_price(price):
    return f"{float(price):.2f}"


def format_order_quantity(quantity):
    rounded = int(quantity)
    if rounded <= 0:
        raise ValueError("주문수량이 1주 미만입니다.")
    return str(rounded)


def create_order_payload(account_no, order, ord_dvsn):
    cano, acnt_prdt_cd = split_account_no(account_no)
    payload = {
        "CANO": cano,
        "ACNT_PRDT_CD": acnt_prdt_cd,
        "OVRS_EXCG_CD": US_ORDER_EXCHANGE_CODE,
        "PDNO": TARGET_SYMBOL,
        "ORD_QTY": format_order_quantity(order.quantity),
        "OVRS_ORD_UNPR": format_order_price(order.price),
        "CTAC_TLNO": "",
        "MGCO_APTM_ODNO": "",
        "ORD_SVR_DVSN_CD": "0",
        "ORD_DVSN": ord_dvsn,
    }
    if order.side == "SELL":
        payload["SLL_TYPE"] = "00"
    return payload


def submit_stock_order(account_no, order, ord_dvsn, credentials=None, access_token=None):
    if order.side not in {"BUY", "SELL"}:
        raise ValueError("주문은 BUY 또는 SELL만 지원합니다.")
    credentials = credentials or load_kis_credentials()
    access_token = access_token or issue_kis_access_token(credentials)
    tr_id = "TTTT1002U" if order.side == "BUY" else "TTTT1006U"
    headers = build_kis_headers(credentials, access_token, tr_id)
    payload = create_order_payload(account_no, order, ord_dvsn)
    return request_kis_json(
        "POST",
        "/uapi/overseas-stock/v1/trading/order",
        headers=headers,
        json_body=payload,
    )


def submit_orders(account_no, plan, execute=False, credentials=None, access_token=None):
    previews = []
    results = []
    for order in plan.orders:
        previews.append({
            "side": order.side,
            "reason": order.reason,
            "payload": create_order_payload(account_no, order, order.ord_dvsn),
        })
    if not execute:
        return {"mode": "preview", "orders": previews}

    credentials = credentials or load_kis_credentials()
    access_token = access_token or issue_kis_access_token(credentials)
    for order in plan.orders:
        try:
            response = submit_stock_order(account_no, order, order.ord_dvsn, credentials, access_token)
            results.append({"ok": True, "response": response, "error": ""})
        except Exception as exc:
            results.append({"ok": False, "response": None, "error": str(exc)})
    return {"mode": "live", "orders": previews, "results": results}


def inquire_today_orders(account_no, credentials=None, access_token=None):
    credentials = credentials or load_kis_credentials()
    access_token = access_token or issue_kis_access_token(credentials)
    cano, acnt_prdt_cd = split_account_no(account_no)
    headers = build_kis_headers(credentials, access_token, "TTTS3018R")
    return request_kis_json(
        "GET",
        "/uapi/overseas-stock/v1/trading/inquire-nccs",
        headers=headers,
        params={
            "CANO": cano, "ACNT_PRDT_CD": acnt_prdt_cd,
            "OVRS_EXCG_CD": US_ORDER_EXCHANGE_CODE,
            "SORT_SQN": "", "CTX_AREA_FK200": "", "CTX_AREA_NK200": "",
        },
    )


def inquire_order_fills(
    account_no,
    start_date,
    end_date,
    symbol="%",
    side="00",
    filled_only="01",
    credentials=None,
    access_token=None,
):
    credentials = credentials or load_kis_credentials()
    access_token = access_token or issue_kis_access_token(credentials)
    cano, acnt_prdt_cd = split_account_no(account_no)
    headers = build_kis_headers(credentials, access_token, "TTTS3035R")
    return request_kis_json(
        "GET",
        "/uapi/overseas-stock/v1/trading/inquire-ccnl",
        headers=headers,
        params={
            "CANO": cano,
            "ACNT_PRDT_CD": acnt_prdt_cd,
            "PDNO": symbol,
            "ORD_STRT_DT": start_date,
            "ORD_END_DT": end_date,
            "SLL_BUY_DVSN": side,
            "CCLD_NCCS_DVSN": filled_only,
            "OVRS_EXCG_CD": US_ORDER_EXCHANGE_CODE,
            "SORT_SQN": "DS",
            "ORD_DT": "",
            "ORD_GNO_BRNO": "",
            "ODNO": "",
            "CTX_AREA_FK200": "",
            "CTX_AREA_NK200": "",
        },
    )


def cancel_stock_order(account_no, order_row, execute=False, credentials=None, access_token=None):
    cano, acnt_prdt_cd = split_account_no(account_no)
    orgn_odno = str(order_row.get("odno") or "").strip()
    raw_qty = to_float(order_row.get("nccs_qty") or order_row.get("ft_ord_qty") or 0)
    cancel_qty = int(raw_qty)
    if not orgn_odno or cancel_qty <= 0:
        raise ValueError("취소 대상 주문번호 또는 미체결 수량 없음")
    payload = {
        "CANO": cano, "ACNT_PRDT_CD": acnt_prdt_cd,
        "OVRS_EXCG_CD": US_ORDER_EXCHANGE_CODE, "PDNO": TARGET_SYMBOL,
        "ORGN_ODNO": orgn_odno, "RVSE_CNCL_DVSN_CD": "02",
        "ORD_QTY": str(cancel_qty), "OVRS_ORD_UNPR": "0",
        "MGCO_APTM_ODNO": "", "ORD_SVR_DVSN_CD": "0",
    }
    if not execute:
        return {"mode": "preview", "payload": payload}
    credentials = credentials or load_kis_credentials()
    access_token = access_token or issue_kis_access_token(credentials)
    headers = build_kis_headers(credentials, access_token, "TTTT1004U")
    result = request_kis_json(
        "POST", "/uapi/overseas-stock/v1/trading/order-rvsecncl",
        headers=headers, json_body=payload,
    )
    return {"mode": "live", "payload": payload, "result": result}


# ─────────────────────────────────────────────
# 상태 관리
# ─────────────────────────────────────────────

def load_strategy_tracker(state_path):
    if not os.path.exists(state_path):
        return StrategyTracker()
    with open(state_path, "r", encoding="utf-8") as f:
        try:
            p = json.load(f)
        except (json.JSONDecodeError, ValueError):
            return StrategyTracker()
    return StrategyTracker(
        cycle_no=p.get("cycle_no", 1),
        cycle_start_capital=p.get("cycle_start_capital", 0.0),
        T=p.get("T", 0.0),
        mode=p.get("mode", "normal"),
        reverse_day=p.get("reverse_day", 0),
        close_history=p.get("close_history", []),
        last_shares=p.get("last_shares", 0.0),
        last_premarket_notice_date=p.get("last_premarket_notice_date", ""),
        last_status_notice_at=p.get("last_status_notice_at", ""),
        last_order_submission_date=p.get("last_order_submission_date", ""),
        last_sell_order_submission_date=p.get("last_sell_order_submission_date", ""),
        last_buy_order_submission_date=p.get("last_buy_order_submission_date", ""),
        last_post_close_report_date=p.get("last_post_close_report_date", ""),
        last_intraday_open_notice_date=p.get("last_intraday_open_notice_date", ""),
        last_buy_skip_notice_date=p.get("last_buy_skip_notice_date", ""),
        last_no_order_notice_date=p.get("last_no_order_notice_date", ""),
        cached_access_token=p.get("cached_access_token", ""),
        cached_token_expires_at=p.get("cached_token_expires_at", ""),
        last_holiday_date=p.get("last_holiday_date", ""),
        last_fill_sync_date=p.get("last_fill_sync_date", ""),
    )


def save_strategy_tracker(state_path, tracker):
    tmp_path = state_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(tracker.__dict__, f, ensure_ascii=False, indent=2)
    os.replace(tmp_path, state_path)


def append_strategy_log(log_path, event_type, tracker, snapshot, extra=None):
    payload = {
        "logged_at": now_ny().isoformat(),
        "event": event_type,
        "cycle_no": tracker.cycle_no,
        "T": tracker.T,
        "mode": tracker.mode,
        "shares": snapshot.shares,
        "avg_price": snapshot.avg_price,
        "current_price": snapshot.current_price,
        "remaining_cash": snapshot.remaining_cash,
    }
    if extra:
        payload.update(extra)
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(payload, ensure_ascii=False) + "\n")


def extract_order_fill_rows(payload):
    if not isinstance(payload, dict):
        return []
    rows = payload.get("output")
    if isinstance(rows, list):
        return rows
    rows = payload.get("output1")
    if isinstance(rows, list):
        return rows
    return []


def get_fill_row_symbol(row):
    return str(row.get("pdno") or row.get("ovrs_pdno") or row.get("symb") or "").upper()


def get_fill_row_side(row):
    raw = str(
        row.get("sll_buy_dvsn_cd_name")
        or row.get("sll_buy_dvsn")
        or row.get("sll_buy_dvsn_cd")
        or row.get("trad_dvsn_name")
        or ""
    )
    upper_raw = raw.upper()
    if "매수" in raw or upper_raw == "02" or "BUY" in upper_raw:
        return "BUY"
    if "매도" in raw or upper_raw == "01" or "SELL" in upper_raw:
        return "SELL"
    return ""


def get_fill_row_qty(row):
    qty = to_float(
        row.get("ft_ccld_qty")
        or row.get("ccld_qty")
        or row.get("tot_ccld_qty")
        or row.get("ord_qty")
        or 0
    )
    return int(round(qty)) if qty > 0 else 0


def get_order_row_qty(row):
    qty = to_float(
        row.get("ft_ord_qty")
        or row.get("ord_qty")
        or row.get("ovrs_ord_qty")
        or row.get("tot_ord_qty")
        or 0
    )
    return int(round(qty)) if qty > 0 else 0


def get_order_row_filled_qty(row):
    qty = to_float(
        row.get("ft_ccld_qty")
        or row.get("ccld_qty")
        or row.get("tot_ccld_qty")
        or 0
    )
    return int(round(qty)) if qty > 0 else 0


def get_order_row_remaining_qty(row):
    qty = to_float(
        row.get("nccs_qty")
        or row.get("rmn_qty")
        or 0
    )
    return int(round(qty)) if qty > 0 else 0


def get_fill_row_price(row):
    # `or` chain on raw strings treats "0.00000000" as truthy, so unfilled orders
    # with ft_ccld_unpr3="0.00000000" return 0 instead of falling back to ft_ord_unpr3.
    # Iterate and convert each field, stopping at the first > 0 result.
    for key in (
        "ft_ccld_unpr3", "ft_ccld_unpr", "avg_unpr",
        "ft_ord_unpr3",  "ft_ord_unpr",  "ovrs_ord_unpr",
    ):
        val = to_float(row.get(key))
        if val > 0:
            return val
    return 0.0


def get_fill_row_amount(row):
    amount = to_float(
        row.get("ft_ccld_amt")
        or row.get("ccld_amt")
        or row.get("frcr_buy_amt1")
        or row.get("frcr_sll_amt_smtl1")
        or 0
    )
    if amount > 0:
        return amount
    qty = get_fill_row_qty(row)
    price = get_fill_row_price(row)
    return qty * price


def get_fill_row_date(row):
    return str(row.get("ord_dt") or row.get("trad_dt") or row.get("bass_dt") or "")


def get_fill_row_time(row):
    raw = str(row.get("ord_tmd") or row.get("ord_tm") or row.get("ccld_dtime") or "")
    digits = "".join(ch for ch in raw if ch.isdigit())
    return digits.zfill(6) if digits else "000000"


def get_fill_row_sort_key(row):
    return (
        get_fill_row_date(row),
        get_fill_row_time(row),
        str(row.get("odno") or row.get("ord_no") or ""),
    )


def estimate_normal_buy_t_delta(cycle_capital, fill_amount):
    if cycle_capital <= 0 or fill_amount <= 0:
        return 0.0
    unit_cash = cycle_capital / N_SPLITS
    if unit_cash <= 0:
        return 0.0
    gross_cash = fill_amount / (1 - COMMISSION)
    return round_half_step(gross_cash / unit_cash)


def sync_tracker_with_fill_history(
    tracker,
    snapshot,
    account_no,
    trading_date,
    credentials=None,
    access_token=None,
    lookback_days=120,
    preserve_existing_t=False,
    return_details=False,
):
    details = {
        "action": "skipped",
        "reason": "",
        "saved_t": tracker.T,
        "saved_cycle_no": tracker.cycle_no,
        "estimated_t": tracker.T,
        "estimated_cycle_no": tracker.cycle_no,
        "preserved_existing_t": False,
        "has_buy_fill_today": False,
    }

    def _finish(updated_tracker):
        details["estimated_t"] = updated_tracker.T
        details["estimated_cycle_no"] = updated_tracker.cycle_no
        if return_details:
            return updated_tracker, details
        return updated_tracker

    if snapshot.shares <= 0:
        details["action"] = "no_position"
        details["reason"] = "보유 수량이 없어 T 동기화를 건너뜀"
        return _finish(tracker)

    end_date = trading_date.replace("-", "")
    start_date = (now_ny() - timedelta(days=lookback_days)).strftime("%Y%m%d")
    try:
        payload = inquire_order_fills(
            account_no,
            start_date=start_date,
            end_date=end_date,
            symbol=TARGET_SYMBOL,
            side="00",
            filled_only="01",
            credentials=credentials,
            access_token=access_token,
        )
    except Exception:
        if tracker.T <= 0 and snapshot.shares > 0:
            inferred_capital = infer_cycle_capital_from_snapshot(snapshot)
            unit_cash = inferred_capital / N_SPLITS if inferred_capital > 0 else 0.0
            deployed_cash = required_cash_for_shares(snapshot.avg_price, int(snapshot.shares))
            if unit_cash > 0:
                tracker.cycle_start_capital = inferred_capital
                tracker.T = min(N_SPLITS, round_half_step(deployed_cash / unit_cash))
                details["action"] = "estimated_from_snapshot"
                details["reason"] = "체결내역 조회 실패로 현재 잔고 기준 추정"
            else:
                details["action"] = "failed_no_estimate"
                details["reason"] = "체결내역 조회 실패, 잔고 기준 추정도 불가"
        else:
            details["action"] = "kept_saved_t"
            details["reason"] = "저장된 T값이 있어 체결내역 재추정을 생략"
            details["preserved_existing_t"] = True
        return _finish(tracker)

    fill_rows = [
        row for row in extract_order_fill_rows(payload)
        if get_fill_row_symbol(row) == TARGET_SYMBOL and get_fill_row_side(row) in {"BUY", "SELL"}
    ]
    fill_rows.sort(key=get_fill_row_sort_key)

    if not fill_rows:
        if tracker.T <= 0 and snapshot.shares > 0:
            inferred_capital = infer_cycle_capital_from_snapshot(snapshot)
            unit_cash = inferred_capital / N_SPLITS if inferred_capital > 0 else 0.0
            deployed_cash = required_cash_for_shares(snapshot.avg_price, int(snapshot.shares))
            if unit_cash > 0:
                tracker.cycle_start_capital = inferred_capital
                tracker.T = min(N_SPLITS, round_half_step(deployed_cash / unit_cash))
                details["action"] = "estimated_from_snapshot"
                details["reason"] = "체결내역이 없어 현재 잔고 기준 추정"
            else:
                details["action"] = "failed_no_estimate"
                details["reason"] = "체결내역이 없고 잔고 기준 추정도 불가"
        else:
            details["action"] = "kept_saved_t"
            details["reason"] = "저장된 T값이 있어 체결내역 재추정을 생략"
            details["preserved_existing_t"] = True
        return _finish(tracker)

    cycle_capital = 0.0
    cycle_t = 0.0
    cycle_mode = "normal"
    cycle_shares = 0
    cycle_no = 1
    today_digits = trading_date.replace("-", "")
    has_buy_fill_today = False

    for row in fill_rows:
        side = get_fill_row_side(row)
        qty = get_fill_row_qty(row)
        amount = get_fill_row_amount(row)
        row_date = get_fill_row_date(row)

        if qty <= 0:
            continue

        if side == "BUY":
            if row_date == today_digits:
                has_buy_fill_today = True
            if cycle_capital <= 0:
                gross_cash = amount / (1 - COMMISSION) if amount > 0 else 0.0
                cycle_capital = gross_cash * N_SPLITS if gross_cash > 0 else infer_cycle_capital_from_snapshot(snapshot)

            if cycle_mode == "reverse":
                cycle_t = t_after_reverse_buy(cycle_t)
            else:
                t_delta = estimate_normal_buy_t_delta(cycle_capital, amount)
                if t_delta <= 0:
                    t_delta = 1.0 if cycle_shares <= 0 and cycle_t <= 0 else 0.5
                cycle_t += t_delta
            cycle_shares += qty

            if cycle_mode == "normal" and should_enter_reverse(cycle_t):
                cycle_mode = "reverse"

        elif side == "SELL":
            if cycle_shares <= 0:
                continue

            if qty >= cycle_shares:
                cycle_shares = 0
                cycle_t = 0.0
                cycle_mode = "normal"
                cycle_capital = 0.0
                cycle_no += 1
                continue

            sold_ratio = qty / cycle_shares if cycle_shares > 0 else 0.0
            if cycle_mode == "reverse":
                cycle_t = t_after_reverse_sell(cycle_t)
            elif sold_ratio >= 0.7:
                cycle_t = t_after_final_sell(cycle_t)
            else:
                cycle_t = t_after_quarter_sell(cycle_t)
            cycle_shares = max(cycle_shares - qty, 0)

    if snapshot.shares > 0 and cycle_capital <= 0:
        cycle_capital = infer_cycle_capital_from_snapshot(snapshot)

    if snapshot.shares > 0 and cycle_t <= 0 and cycle_capital > 0:
        unit_cash = cycle_capital / N_SPLITS
        deployed_cash = required_cash_for_shares(snapshot.avg_price, int(snapshot.shares))
        if unit_cash > 0:
            cycle_t = round_half_step(deployed_cash / unit_cash)

    elif snapshot.shares > 0 and cycle_capital > 0 and cycle_shares != int(snapshot.shares):
        # SELL row가 skip돼 재구성 수량과 실제 수량이 다를 때 → 실제 배포 자본으로 T 재산출
        unit_cash = cycle_capital / N_SPLITS
        deployed_cash = required_cash_for_shares(snapshot.avg_price, int(snapshot.shares))
        if unit_cash > 0:
            cycle_t = round_half_step(deployed_cash / unit_cash)

    details["has_buy_fill_today"] = has_buy_fill_today

    if preserve_existing_t and tracker.T > 0:
        if cycle_capital > 0 and tracker.cycle_start_capital <= 0:
            tracker.cycle_start_capital = cycle_capital
        tracker.last_fill_sync_date = trading_date
        details["action"] = "kept_saved_t"
        details["reason"] = "저장된 T값이 있어 유지하고, 체결내역은 오늘 매수 감지에만 사용"
        details["preserved_existing_t"] = True
        if has_buy_fill_today:
            tracker.last_buy_order_submission_date = trading_date
        return _finish(tracker)

    tracker.cycle_no = max(tracker.cycle_no, cycle_no)
    tracker.cycle_start_capital = cycle_capital
    tracker.T = min(N_SPLITS, max(cycle_t, 0.0))
    tracker.mode = cycle_mode
    tracker.last_fill_sync_date = trading_date
    details["action"] = "estimated_from_fills"
    details["reason"] = "해외주식 주문체결내역 기준으로 T와 cycle을 재구성"

    if has_buy_fill_today:
        tracker.last_buy_order_submission_date = trading_date

    return _finish(tracker)


# ─────────────────────────────────────────────
# 트래커 갱신 (체결 감지)
# ─────────────────────────────────────────────

def update_strategy_tracker(tracker, snapshot, log_path=None, webhook_url=None):
    current_equity = get_strategy_equity(snapshot)
    today_str = now_ny().strftime("%Y-%m-%d")

    # 첫 포지션 시작 → 사이클 시작
    if snapshot.shares > 0 and tracker.cycle_start_capital <= 0:
        tracker.cycle_start_capital = current_equity
        if log_path:
            append_strategy_log(log_path, "cycle_started", tracker, snapshot,
                                extra={"cycle_start_capital": tracker.cycle_start_capital})
        if webhook_url:
            try:
                send_discord_webhook(
                    format_webhook_message("🟢 사이클 시작", [
                        f"🔄 Cycle: {tracker.cycle_no}",
                        f"💰 Start Capital: ${tracker.cycle_start_capital:,.2f}",
                        f"📦 {snapshot.shares:.0f} shares @ ${snapshot.avg_price:,.2f}",
                        f"📊 T={tracker.T:.2f} | Mode: {tracker.mode}",
                    ], status="CYCLE"),
                    webhook_url,
                )
            except Exception:
                pass

    elif snapshot.shares > tracker.last_shares:
        is_initial_startup = tracker.last_shares <= 0 and tracker.last_buy_order_submission_date == ""
        is_manual = not is_initial_startup and tracker.last_buy_order_submission_date != today_str
        if is_manual:
            tracker.last_buy_order_submission_date = today_str
            if webhook_url:
                try:
                    send_discord_webhook(
                        format_webhook_message("📈 수동 매수 감지", [
                            f"📦 {tracker.last_shares:.0f} → {snapshot.shares:.0f} shares",
                            f"💰 Avg: ${snapshot.avg_price:,.2f}",
                            "⚠️ 오늘 자동 매수는 건너뜁니다. 매도는 유지됩니다.",
                        ], status="BUY"),
                        webhook_url,
                    )
                except Exception:
                    pass

    # 전량 매도 감지 → 사이클 종료
    if tracker.last_shares > 0 and snapshot.shares <= 0:
        cycle_return = ((current_equity / tracker.cycle_start_capital) - 1) * 100 if tracker.cycle_start_capital > 0 else 0.0
        if log_path:
            append_strategy_log(log_path, "cycle_closed", tracker, snapshot,
                                extra={"cycle_start_capital": tracker.cycle_start_capital, "cycle_return": cycle_return})
        if webhook_url:
            try:
                send_discord_webhook(
                    format_webhook_message("🔴 사이클 종료", [
                        f"🔄 Cycle: {tracker.cycle_no} (전량 매도 완료)",
                        f"💰 ${tracker.cycle_start_capital:,.2f} → ${current_equity:,.2f}",
                        f"📊 수익률: {cycle_return:+.2f}%",
                    ], status="CYCLE"),
                    webhook_url,
                )
            except Exception:
                pass
        tracker.cycle_no += 1
        tracker.cycle_start_capital = 0.0
        tracker.T = 0.0
        tracker.mode = "normal"
        tracker.reverse_day = 0
        tracker.close_history = []

    tracker.last_shares = snapshot.shares
    return tracker


# ─────────────────────────────────────────────
# 핵심: V4 트레이딩 플랜 생성
# ─────────────────────────────────────────────

def build_v4_trading_plan(snapshot, tracker):
    """V4.0 전략 명세서에 따라 오늘의 주문 계획 생성"""
    T = tracker.T
    mode = tracker.mode
    avg_cost = strategy_avg_cost(snapshot.avg_price)
    prev_close = snapshot.prev_close
    current_price = snapshot.current_price
    shares = int(snapshot.shares)
    orderable_qty = int(snapshot.orderable_qty)
    cash = snapshot.remaining_cash
    cap_price = round(prev_close * LOC_CAP_MULT, 2)

    plan = TradingPlan(
        current_price=current_price,
        prev_close=prev_close,
        mode=mode,
        T=T,
    )

    # ═══════════════════════════════════════════
    # 리버스모드
    # ═══════════════════════════════════════════
    if mode == "reverse":
        reverse_day = tracker.reverse_day
        five_ma = calc_5ma(tracker.close_history) if tracker.close_history else current_price
        five_ma = round(five_ma, 2)

        plan.notes.append(f"리버스모드 Day {reverse_day} | 5MA=${five_ma:,.2f} | T={T:.2f}")

        if reverse_day == 1:
            # MOC 매도: 보유/10 (내림, 최소1주)
            sell_qty = calc_fractional_sell_qty(shares, 0.10, min_one=True)
            sell_qty = cap_orderable_qty(sell_qty, orderable_qty)
            if sell_qty > 0:
                plan.orders.append(PlannedOrder(
                    side="SELL", quantity=sell_qty, price=current_price,
                    amount=sell_qty * current_price,
                    reason=f"리버스 1일차 MOC 매도 (보유{shares}/10={sell_qty}주)",
                    ord_dvsn="32",
                ))
            plan.notes.append("리버스 1일차: MOC 매도만, 매수 없음")
        else:
            # LOC 매도: 5MA, 보유/10 (내림, 최소1주)
            sell_qty = calc_fractional_sell_qty(shares, 0.10, min_one=True)
            sell_qty = cap_orderable_qty(sell_qty, orderable_qty)
            if sell_qty > 0:
                plan.orders.append(PlannedOrder(
                    side="SELL", quantity=sell_qty, price=five_ma,
                    amount=sell_qty * five_ma,
                    reason=f"리버스 LOC 매도 5MA (보유{shares}/10={sell_qty}주)",
                    ord_dvsn="34",
                ))

            # LOC 매수: 잔금/4, 5MA-0.01
            buy_budget = cash / 4 if cash > 0 else 0
            buy_price = round(five_ma - 0.01, 2)
            buy_qty = calc_buy_qty_from_budget(buy_budget, buy_price)
            if buy_qty >= 1:
                plan.orders.append(PlannedOrder(
                    side="BUY", quantity=buy_qty, price=buy_price,
                    amount=buy_qty * buy_price,
                    reason=f"리버스 쿼터매수 (잔금${cash:,.0f}/4=${buy_budget:,.0f})",
                    ord_dvsn="34",
                ))

        return plan

    # ═══════════════════════════════════════════
    # 일반모드
    # ═══════════════════════════════════════════

    # T > 19이면 리버스 전환 예고 (실제 전환은 run_strategy_cycle에서)
    if should_enter_reverse(T):
        plan.notes.append(f"⚠️ T={T:.2f} > {N_SPLITS-1} → 리버스모드 전환 예정")
        return plan

    one_portion = portion_amount(cash, T)

    # ─── 첫 매수 (T=0, 보유 0주) ───
    if T == 0 and shares == 0:
        buy_price = cap_price  # 전일종가 × 1.10 (큰수)
        first_budget = min(one_portion, cash)
        buy_qty = calc_buy_qty_from_budget(first_budget, buy_price)
        if buy_qty >= 1:
            plan.orders.append(PlannedOrder(
                side="BUY", quantity=buy_qty, price=buy_price,
                amount=round(buy_qty * buy_price, 2),
                reason=f"첫 매수 LOC (전일종가×1.10=${buy_price:.2f}, 1포션=${one_portion:.2f})",
                ord_dvsn="34",
            ))
            # 폭락장 대비 추가 매수
            cash_after_base = cash - required_cash_for_shares(buy_price, buy_qty)
            crash_orders = generate_crash_protection_orders(
                budget=first_budget,
                base_price=buy_price,
                base_qty=buy_qty,
                cash_remaining=cash_after_base + required_cash_for_shares(buy_price, buy_qty),
            )
            for add_price, add_qty in crash_orders:
                plan.orders.append(PlannedOrder(
                    side="BUY", quantity=add_qty, price=add_price,
                    amount=round(add_qty * add_price, 2),
                    reason=f"첫 매수 폭락대비 LOC (${add_price:.2f}, {add_qty}주)",
                    ord_dvsn="34",
                ))
            if crash_orders:
                plan.notes.append(
                    f"첫 매수 폭락대비: {len(crash_orders)}건 추가 "
                    f"(${crash_orders[-1][0]:.2f}까지)"
                )
        else:
            plan.notes.append(f"첫 매수 불가: 현금 ${cash:.2f} 부족")
        return plan

    # ─── 매도 주문 (쿼터매도 선행 → 나머지 전량 지정가매도) ───
    if shares > 0 and avg_cost > 0:
        sp = round(star_price(avg_cost, T), 2)
        final_sell_price = round(avg_cost * (1 + PROFIT_TARGET_PCT), 2)

        # 쿼터매도: LOC 매도, 별지점, 보유×0.25 (내림, 최소1주)
        quarter_qty = calc_fractional_sell_qty(shares, 0.25, min_one=True)
        quarter_qty = cap_orderable_qty(quarter_qty, orderable_qty)

        # 최종매도: 보유 - 쿼터수량, 20% 익절 지정가 (잔량 없이)
        final_qty = shares - quarter_qty
        final_qty = cap_orderable_qty(final_qty, max(orderable_qty - quarter_qty, 0))

        if quarter_qty > 0:
            plan.orders.append(PlannedOrder(
                side="SELL", quantity=quarter_qty, price=sp,
                amount=round(quarter_qty * sp, 2),
                reason=f"쿼터매도 LOC (별지점=${sp:.2f}, 보유{shares}×1/4={quarter_qty}주)",
                ord_dvsn="34",
            ))

        if final_qty > 0:
            plan.orders.append(PlannedOrder(
                side="SELL", quantity=final_qty, price=final_sell_price,
                amount=round(final_qty * final_sell_price, 2),
                reason=f"최종매도 지정가 (평단${avg_cost:.2f}×1.20=${final_sell_price:.2f}, {final_qty}주)",
                ord_dvsn="00",
            ))

    # ─── 매수 주문 ───
    if avg_cost <= 0 and T > 0:
        plan.notes.append("평단가 없음 → 후속 매수 불가")
        return plan

    if cash <= 1:
        plan.notes.append("현금 부족 → 매수 생략")
        return plan

    if T > 0 and avg_cost > 0:
        sp = round(star_price(avg_cost, T), 2)
        bp = round(buy_point(avg_cost, T), 2)

        if is_front_half(T):
            # 전반전: 별지점 매수 + 평단가 매수
            # 별지점 매수: 1회 매수 자본 * 0.5 만큼 (내림)
            star_buy_budget = min(one_portion * 0.5, cash)
            star_buy_qty = calc_buy_qty_from_budget(star_buy_budget, bp)

            # 평단가 매수: 잔여 현금 내 0.5포션 매수 (내림)
            remaining_cash_after_star = max(cash - required_cash_for_shares(bp, star_buy_qty), 0)
            avg_buy_budget = min(one_portion * 0.5, remaining_cash_after_star)
            avg_buy_qty = calc_buy_qty_from_budget(avg_buy_budget, avg_cost)

            if star_buy_qty >= 1:
                plan.orders.append(PlannedOrder(
                    side="BUY", quantity=star_buy_qty, price=bp,
                    amount=round(star_buy_qty * bp, 2),
                    reason=f"전반전 별지점 매수 LOC (${bp:.2f}, {star_buy_qty}주, T={T:.1f})",
                    ord_dvsn="34",
                ))
                # 폭락장 대비 추가 매수 (별지점만, 평단가 매수는 제외)
                crash_orders = generate_crash_protection_orders(
                    budget=star_buy_budget,
                    base_price=bp,
                    base_qty=star_buy_qty,
                    cash_remaining=star_buy_budget,
                )
                for add_price, add_qty in crash_orders:
                    plan.orders.append(PlannedOrder(
                        side="BUY", quantity=add_qty, price=add_price,
                        amount=round(add_qty * add_price, 2),
                        reason=f"전반전 별지점 폭락대비 LOC (${add_price:.2f}, {add_qty}주, T={T:.1f})",
                        ord_dvsn="34",
                    ))
                if crash_orders:
                    plan.notes.append(
                        f"전반전 별지점 폭락대비: {len(crash_orders)}건 추가 "
                        f"(${crash_orders[-1][0]:.2f}까지)"
                    )
            if avg_buy_qty >= 1:
                plan.orders.append(PlannedOrder(
                    side="BUY", quantity=avg_buy_qty, price=round(avg_cost, 2),
                    amount=round(avg_buy_qty * avg_cost, 2),
                    reason=f"전반전 평단가 매수 LOC (${avg_cost:.2f}, {avg_buy_qty}주, T={T:.1f})",
                    ord_dvsn="34",
                ))

        elif is_back_half(T):
            # 후반전: 1포션 별지점 LOC
            buy_price = bp
            back_budget = min(one_portion, cash)
            buy_qty = calc_buy_qty_from_budget(back_budget, buy_price)
            if buy_qty >= 1:
                plan.orders.append(PlannedOrder(
                    side="BUY", quantity=buy_qty, price=buy_price,
                    amount=round(buy_qty * buy_price, 2),
                    reason=f"후반전 별지점 매수 LOC (${buy_price:.2f}, {buy_qty}주, T={T:.1f})",
                    ord_dvsn="34",
                ))
                # 폭락장 대비 추가 매수
                crash_orders = generate_crash_protection_orders(
                    budget=back_budget,
                    base_price=buy_price,
                    base_qty=buy_qty,
                    cash_remaining=back_budget,
                )
                for add_price, add_qty in crash_orders:
                    plan.orders.append(PlannedOrder(
                        side="BUY", quantity=add_qty, price=add_price,
                        amount=round(add_qty * add_price, 2),
                        reason=f"후반전 별지점 폭락대비 LOC (${add_price:.2f}, {add_qty}주, T={T:.1f})",
                        ord_dvsn="34",
                    ))
                if crash_orders:
                    plan.notes.append(
                        f"후반전 별지점 폭락대비: {len(crash_orders)}건 추가 "
                        f"(${crash_orders[-1][0]:.2f}까지)"
                    )

    plan.notes.append(f"별%={(N_SPLITS - 2*T):.1f}% | 별지점=${star_price(avg_cost, T) if avg_cost > 0 else 0:.2f} | T={T:.2f}")
    return plan


# ─────────────────────────────────────────────
# 디스코드 메시지 포맷
# ─────────────────────────────────────────────

def build_discord_status_message(snapshot, tracker):
    strategy_equity = get_strategy_equity(snapshot)
    cycle_return = 0.0
    if tracker.cycle_start_capital > 0:
        cycle_return = ((strategy_equity / tracker.cycle_start_capital) - 1) * 100

    lines = []
    lines.append(_section("Account Summary"))
    lines.append(f"💰 Total: ${strategy_equity:,.2f}")
    if snapshot.shares > 0:
        pnl_pct = format_signed_pct(snapshot.stock_pnl_rate)
        lines.append(f"📦 {snapshot.shares:.0f} shares @ ${snapshot.avg_price:,.2f}")
        lines.append(f"📈 Price: ${snapshot.current_price:,.2f} ({pnl_pct})")
    else:
        lines.append("📦 미보유")
    lines.append(f"💳 Cash: ${snapshot.remaining_cash:,.2f}")

    lines.append(_section("V4 Strategy"))
    lines.append(f"🔄 Cycle: {tracker.cycle_no} | Mode: {tracker.mode}")
    lines.append(f"📊 T={tracker.T:.2f} | 별%={(N_SPLITS - 2*tracker.T):.1f}%")
    if tracker.mode == "reverse":
        five_ma = calc_5ma(tracker.close_history) if tracker.close_history else 0
        lines.append(f"🔀 Reverse Day: {tracker.reverse_day} | 5MA=${five_ma:,.2f}")
    lines.append(f"📊 Cycle Return: {format_signed_pct(cycle_return)}")

    return "\n".join(lines)


def build_order_summary_message(plan, execution_mode, results=None):
    if execution_mode != "live":
        header = "⚠️  주문 시뮬레이션 (PREVIEW)"
    else:
        buy_count = sum(1 for o in plan.orders if o.side == "BUY")
        sell_count = sum(1 for o in plan.orders if o.side == "SELL")
        parts = []
        if buy_count: parts.append(f"매수 {buy_count}건")
        if sell_count: parts.append(f"매도 {sell_count}건")
        header = "📨  주문 제출 완료 " + ("(" + ", ".join(parts) + ")" if parts else "")

    lines = [
        header,
        f"📈 Price: ${plan.current_price:,.2f} | Prev: ${plan.prev_close:,.2f}",
        f"Mode: {plan.mode} | T={plan.T:.2f}",
    ]

    if plan.orders:
        lines.append(_section("Orders"))
        for i, order in enumerate(plan.orders, 1):
            icon = "🟢" if order.side == "BUY" else "🔴"
            ot = {"34": "LOC", "00": "지정가", "32": "MOC"}.get(order.ord_dvsn, order.ord_dvsn)
            line = f"{icon} {order.side} {order.quantity}주 @ ${order.price:,.2f} | ${order.amount:,.2f} | {ot}"
            if execution_mode == "live" and results and i - 1 < len(results):
                odno = (results[i - 1].get("output") or {}).get("odno", "")
                if odno:
                    line += f" | #{odno}"
            line += f"\n   └ {order.reason}"
            lines.append(line)
    else:
        lines.append("📭  제출 주문 없음")

    if plan.notes:
        lines.append(_section("Notes"))
        for note in plan.notes:
            lines.append(f"  {note}")

    return "\n".join(lines)


def calculate_price_gap_pct(reference_price, target_price):
    if reference_price <= 0 or target_price <= 0:
        return 0.0
    return ((target_price / reference_price) - 1) * 100


def get_order_report_label(order):
    reason = order.reason
    if order.side == "SELL":
        if "최종매도" in reason:
            return "Limit Sell"
        if "리버스" in reason:
            return "Reverse Sell"
        return "Star Sell"

    if "평단가" in reason:
        return "LOC Average Buy"
    if "첫 매수" in reason:
        return "Initial Buy"
    if "리버스" in reason:
        return "Reverse Buy"
    return "Star Buy"


def build_execution_status_message(plan, submit_result):
    current_price = plan.current_price
    lines = [
        f"Current Price: ${current_price:,.2f}",
        f"Mode: {plan.mode} | T={plan.T:.2f}",
    ]

    grouped = {"SELL": [], "BUY": []}
    for order, result in zip(plan.orders, submit_result.get("results") or []):
        label = get_order_report_label(order)
        gap_pct = calculate_price_gap_pct(current_price, order.price)
        status = "SUCCESS" if result.get("ok") else "FAILED"
        line = (
            f"{label} - {status} | Qty {order.quantity} | ${order.price:,.2f} | "
            f"Gap vs current {gap_pct:+.2f}%"
        )
        if result.get("ok"):
            odno = ((result.get("response") or {}).get("output") or {}).get("odno", "")
            if odno:
                line += f" | Order #{odno}"
        else:
            line += f" | {result.get('error') or 'Order rejected'}"
        grouped[order.side].append(line)

    if grouped["SELL"]:
        lines.append(_section("Sell"))
        lines.extend(grouped["SELL"])
    if grouped["BUY"]:
        lines.append(_section("Buy"))
        lines.extend(grouped["BUY"])

    failed_count = sum(1 for result in (submit_result.get("results") or []) if not result.get("ok"))
    if failed_count:
        lines.append("Failed orders were not retried today. The bot will try again tomorrow. You can place them manually if needed.")

    return "\n".join(lines)


def build_startup_plan_message(snapshot, tracker, trading_date):
    plan = build_v4_trading_plan(snapshot, tracker)

    if tracker.last_buy_order_submission_date == trading_date:
        plan = TradingPlan(
            current_price=plan.current_price,
            prev_close=plan.prev_close,
            mode=plan.mode,
            T=plan.T,
            orders=[order for order in plan.orders if order.side != "BUY"],
            notes=list(plan.notes) + ["오늘 이미 매수 체결/제출 기록이 있어 시작 시점 자동 매수는 제외"],
        )

    return build_order_summary_message(plan, "preview")


def extract_today_order_rows(payload):
    if not isinstance(payload, dict):
        return []
    rows = payload.get("output")
    if isinstance(rows, list):
        return rows
    rows = payload.get("output1")
    if isinstance(rows, list):
        return rows
    return []


def classify_order_row_label(row, snapshot, tracker):
    side = get_fill_row_side(row)
    ord_dvsn = str(
        row.get("ord_dvsn")
        or row.get("ord_dvsn_cd")
        or row.get("ord_dvsn_name")
        or ""
    ).strip()
    order_price = to_float(row.get("ft_ord_unpr3") or row.get("ft_ord_unpr") or row.get("ovrs_ord_unpr") or 0)
    strategy_avg = strategy_avg_cost(snapshot.avg_price)

    if side == "SELL":
        if ord_dvsn == "00":
            return "Limit Sell"
        if ord_dvsn == "32" or tracker.mode == "reverse":
            return "Reverse Sell"
        return "Star Sell"

    if side == "BUY":
        if tracker.mode == "reverse":
            return "Reverse Buy"
        if strategy_avg <= 0:
            return "Initial Buy"
        if abs(order_price - round(strategy_avg, 2)) <= 0.02:
            return "LOC Average Buy"
        return "Star Buy"

    return "Order"


def build_order_status_section(order_rows, snapshot, tracker):
    symbol_rows = []
    for row in order_rows or []:
        symbol = str(row.get("pdno") or row.get("ovrs_pdno") or row.get("symb") or "").upper()
        if symbol == TARGET_SYMBOL:
            symbol_rows.append(row)
    if not symbol_rows:
        return "No order records found yet. They may not be reflected yet, or the query may have failed."
    lines = []
    for r in symbol_rows:
        side = get_fill_row_side(r)
        odno = r.get("odno", "-")
        ord_qty = get_order_row_qty(r)
        ccld_qty = get_order_row_filled_qty(r)
        nccs_qty = get_order_row_remaining_qty(r)
        ord_unpr = get_fill_row_price(r)
        stat = str(r.get("prcs_stat_name") or "-")
        gap_pct = calculate_price_gap_pct(snapshot.current_price, ord_unpr)
        label = classify_order_row_label(r, snapshot, tracker)
        if ccld_qty > 0 and nccs_qty <= 0:
            status = "FILLED"
        elif ccld_qty > 0 and nccs_qty > 0:
            status = "PARTIAL"
        else:
            status = "OPEN"
        lines.append(
            f"{label} - {status} | ${ord_unpr:,.2f} | Gap vs current {gap_pct:+.2f}% | "
            f"Qty {ord_qty} | Filled {ccld_qty} | Remaining {nccs_qty} | {stat} | Order #{odno}"
        )
    return "\n".join(lines)


# ─────────────────────────────────────────────
# 시장 시간 / 캘린더
# ─────────────────────────────────────────────

_NYSE_CALENDAR = mcal.get_calendar("NYSE")


def is_nyse_trading_day(date_str):
    try:
        schedule = _NYSE_CALENDAR.schedule(start_date=date_str, end_date=date_str)
        return not schedule.empty
    except Exception:
        return True


def get_us_market_times(reference=None):
    reference = reference or now_ny()
    ny_now = reference.astimezone(_TZ_NEW_YORK)
    open_ny = _TZ_NEW_YORK.localize(datetime(ny_now.year, ny_now.month, ny_now.day, 9, 30, 0))
    close_ny = _TZ_NEW_YORK.localize(datetime(ny_now.year, ny_now.month, ny_now.day, 16, 0, 0))
    return open_ny, close_ny


def send_discord_webhook(message, webhook_url=None):
    webhook_url = webhook_url or load_discord_webhook_url()
    response = requests.post(webhook_url, json={"content": message}, timeout=30)
    response.raise_for_status()
    return response


# ─────────────────────────────────────────────
# 프리장 주문 일괄 제출 (매도+매수 동시)
# ─────────────────────────────────────────────
# V4 가격 구조상 LOC매수(별지점-0.01)와 LOC매도(별지점)는
# $0.01 갭으로 상호배타 → 동시 체결(자전거래) 불가.
# 지정가매도(+20%)와 LOC매수도 가격 역전 없음.
# 따라서 프리장에 매도+매수 전량 일괄 제출 가능.
# ─────────────────────────────────────────────

def filter_plan_orders(plan, side):
    return TradingPlan(
        current_price=plan.current_price,
        prev_close=plan.prev_close,
        mode=plan.mode,
        T=plan.T,
        orders=[o for o in plan.orders if o.side == side],
        notes=list(plan.notes),
    )


def maybe_submit_all_orders(account_no, tracker, snapshot, execute_orders, webhook_url, state_path, trading_date, credentials=None, access_token=None):
    """프리장에 매도+매수 주문 일괄 제출"""
    if (
        tracker.last_sell_order_submission_date == trading_date
        and tracker.last_buy_order_submission_date == trading_date
    ):
        return

    plan = build_v4_trading_plan(snapshot, tracker)

    if not plan.orders:
        lines = []
        if snapshot.shares <= 0:
            lines.append("📦 Holdings: 0 shares")
        lines.append(f"💵 Cash: ${snapshot.remaining_cash:,.2f}")
        lines.append(f"📊 T={tracker.T:.2f} | Mode: {tracker.mode}")
        if plan.notes:
            lines.extend(plan.notes)
        send_discord_webhook(
            format_webhook_message("ℹ️ 주문 없음", lines, status="SKIP"),
            webhook_url,
        )
        tracker.last_order_submission_date = trading_date
        tracker.last_sell_order_submission_date = trading_date
        tracker.last_buy_order_submission_date = trading_date
        save_strategy_tracker(state_path, tracker)
        return

    sell_plan = filter_plan_orders(plan, "SELL")
    buy_plan = filter_plan_orders(plan, "BUY")
    handled_any = False

    if sell_plan.orders and tracker.last_sell_order_submission_date != trading_date:
        sell_result = submit_orders(account_no, sell_plan, execute=execute_orders, credentials=credentials, access_token=access_token)
        sell_message = build_order_summary_message(sell_plan, sell_result["mode"], sell_result.get("results"))
        if execute_orders:
            sell_message = build_execution_status_message(sell_plan, sell_result)
        send_discord_webhook(
            format_webhook_message("📤 매도 주문 제출", [
                sell_message,
            ], status="ORDER"),
            webhook_url,
        )
        tracker.last_sell_order_submission_date = trading_date
        handled_any = True

    if buy_plan.orders:
        if tracker.last_buy_order_submission_date == trading_date:
            if tracker.last_buy_skip_notice_date != trading_date:
                send_discord_webhook(
                    format_webhook_message("📋 매수 스킵", [
                        "⚠️ 오늘 이미 매수 체결이 있어 자동 매수는 건너뜁니다.",
                        f"📦 {snapshot.shares:.0f} shares @ ${snapshot.avg_price:,.2f}",
                        "매도 주문은 그대로 유지됩니다.",
                    ], status="SKIP"),
                    webhook_url,
                )
                tracker.last_buy_skip_notice_date = trading_date
                handled_any = True
        else:
            buy_result = submit_orders(account_no, buy_plan, execute=execute_orders, credentials=credentials, access_token=access_token)
            buy_message = build_order_summary_message(buy_plan, buy_result["mode"], buy_result.get("results"))
            if execute_orders:
                buy_message = build_execution_status_message(buy_plan, buy_result)
            send_discord_webhook(
                format_webhook_message("📥 매수 주문 제출", [
                    buy_message,
                ], status="ORDER"),
                webhook_url,
            )
            tracker.last_buy_order_submission_date = trading_date
            tracker.last_buy_skip_notice_date = trading_date
            handled_any = True

    if handled_any:
        tracker.last_order_submission_date = trading_date
        save_strategy_tracker(state_path, tracker)


# ─────────────────────────────────────────────
# 알림 함수들
# ─────────────────────────────────────────────

def maybe_send_premarket_notice(tracker, snapshot, webhook_url, now, market_open, state_path):
    today_str = now.strftime("%Y-%m-%d")
    if tracker.last_premarket_notice_date == today_str:
        return
    five_before = market_open - timedelta(minutes=5)
    if five_before <= now < market_open:
        try:
            send_discord_webhook(
                format_webhook_message("📊 장전 계좌 현황", [
                    build_discord_status_message(snapshot, tracker),
                ], status="INFO"),
                webhook_url,
            )
        except Exception:
            pass
        tracker.last_premarket_notice_date = today_str
        save_strategy_tracker(state_path, tracker)


def maybe_send_intraday_open_notice(account_no, tracker, snapshot, webhook_url, now, market_open, state_path, credentials=None, access_token=None):
    today_str = now.strftime("%Y-%m-%d")
    if tracker.last_intraday_open_notice_date == today_str:
        return
    if now < market_open + timedelta(minutes=5):
        return

    order_rows = []
    order_query_error = None
    try:
        payload = inquire_today_orders(account_no, credentials, access_token)
        order_rows = extract_today_order_rows(payload)
    except Exception as exc:
        order_query_error = str(exc)

    lines = [
        f"📈 Price: ${snapshot.current_price:,.2f} | Avg: ${snapshot.avg_price:,.2f}",
        f"📊 T={tracker.T:.2f} | Mode: {tracker.mode}",
        f"📌 {( '일반모드' if tracker.mode == 'normal' else '리버스모드' )} 제출 주문 현황",
    ]
    lines.append(_section("제출 여부"))
    lines.append(
        f"매도 제출: {'완료' if tracker.last_sell_order_submission_date == today_str else '미제출'} | "
        f"매수 제출: {'완료' if tracker.last_buy_order_submission_date == today_str else '미제출'}"
    )

    lines.append(_section("주문 확인"))
    if order_query_error:
        lines.append(f"⚠️ 주문 조회 실패: {order_query_error}")
    else:
        lines.append(build_order_status_section(order_rows, snapshot, tracker))

    try:
        send_discord_webhook(
            format_webhook_message("📋 주문 확인", lines, status="INFO"),
            webhook_url,
        )
    except Exception:
        pass
    tracker.last_intraday_open_notice_date = today_str
    save_strategy_tracker(state_path, tracker)


def maybe_send_post_close_report(account_no, tracker, snapshot, webhook_url, now, market_close, state_path, log_path=None, credentials=None, access_token=None):
    trading_date = now.strftime("%Y-%m-%d")
    if tracker.last_post_close_report_date == trading_date:
        return
    if now < market_close + timedelta(minutes=30):
        return

    today_str = now.strftime("%Y%m%d")
    order_rows = []
    order_query_error = None
    try:
        payload = inquire_order_fills(
            account_no,
            start_date=today_str,
            end_date=today_str,
            symbol=TARGET_SYMBOL,
            side="00",
            filled_only="01",
            credentials=credentials,
            access_token=access_token,
        )
        order_rows = extract_order_fill_rows(payload)
    except Exception as exc:
        order_query_error = str(exc)

    lines = [build_discord_status_message(snapshot, tracker)]
    lines.append(_section("당일 체결 내역"))
    if order_query_error:
        lines.append(f"⚠️ 체결 조회 실패: {order_query_error}")
    elif order_rows:
        lines.append(build_order_status_section(order_rows, snapshot, tracker))
    else:
        lines.append("오늘 체결된 주문이 없습니다.")

    try:
        send_discord_webhook(
            format_webhook_message("📊 장후 리포트", lines, status="INFO"),
            webhook_url,
        )
    except Exception:
        pass
    if log_path:
        append_strategy_log(log_path, "post_close", tracker, snapshot, extra={
            "fills": len(order_rows),
            "T": tracker.T,
            "mode": tracker.mode,
        })
    tracker.last_post_close_report_date = trading_date
    save_strategy_tracker(state_path, tracker)


# ─────────────────────────────────────────────
# T값 갱신 (장후 체결 결과 기반)
# ─────────────────────────────────────────────

def update_t_from_fills(tracker, prev_snapshot, new_snapshot, log_path=None, webhook_url=None):
    """체결 결과를 보고 T값과 모드를 갱신한다.
    매일 장후 리포트 시점에 prev_snapshot(장전) → new_snapshot(장후) 비교."""
    prev_shares = int(prev_snapshot.shares) if prev_snapshot else int(tracker.last_shares)
    new_shares = int(new_snapshot.shares)
    T = tracker.T
    mode = tracker.mode
    changed = False

    if mode == "normal":
        if new_shares > prev_shares:
            # 매수 체결 감지
            if T == 0:
                T += 1  # 첫 매수
            elif is_front_half(T):
                # 전반전: 별지점만 체결=+0.5, 둘다=+1
                # 근사 판단: 수량 증가 비율로 추정
                portion_cash = portion_amount(new_snapshot.remaining_cash + (new_shares - prev_shares) * new_snapshot.avg_price, T)
                half_portion_qty = estimate_shares(portion_cash * 0.5, new_snapshot.avg_price) if new_snapshot.avg_price > 0 else 1
                added = new_shares - prev_shares
                if half_portion_qty > 0 and added > half_portion_qty * 1.3:
                    T += 1  # 두 주문 다 체결
                else:
                    T += 0.5  # 별지점만 체결
            else:
                T += 1  # 후반전

            changed = True
            fill_details = []
            if is_front_half(T):
                fill_details.append("전반전: 별지점+평단가 매수 체결")
            else:
                fill_details.append("후반전: 별지점 매수 체결")
            fill_details.append(f"수량: +{new_shares - prev_shares}주")
            if webhook_url:
                try:
                    send_discord_webhook(
                        format_webhook_message("📈 매수 체결 감지", [
                            f"📦 {prev_shares} → {new_shares} shares (+{new_shares - prev_shares})",
                            f"📊 T: {tracker.T:.2f} → {T:.2f}",
                            *fill_details
                        ], status="FILL"),
                        webhook_url,
                    )
                except Exception:
                    pass

        elif new_shares < prev_shares:
            # 매도 체결 감지
            sold = prev_shares - new_shares
            quarter_qty = max(int(prev_shares * 0.25), 1)

            if new_shares == 0:
                # 전량 매도 → 사이클 종료 (update_strategy_tracker에서 처리)
                fill_details = ["전량 매도 체결", f"수량: -{sold}주"]
            elif sold <= quarter_qty * 1.2:
                # 쿼터매도만 체결
                T = t_after_quarter_sell(T)
                fill_details = ["쿼터매도 체결", f"수량: -{sold}주", f"T 조정: {tracker.T:.2f} → {T:.2f}"]
                changed = True
            elif sold >= prev_shares * 0.7:
                # 최종매도(3/4) 체결 (LOC쿼터 미체결)
                T = t_after_final_sell(T)
                fill_details = ["최종매도 체결", f"수량: -{sold}주", f"T 조정: {tracker.T:.2f} → {T:.2f}"]
                changed = True
            else:
                # 쿼터+최종 둘 다? → 전량이어야 함 (위에서 처리)
                T = t_after_quarter_sell(T)
                fill_details = ["부분 매도 체결", f"수량: -{sold}주", f"T 조정: {tracker.T:.2f} → {T:.2f}"]
                changed = True

            if changed and webhook_url:
                try:
                    send_discord_webhook(
                        format_webhook_message("📉 매도 체결 감지", [
                            f"📦 {prev_shares} → {new_shares} shares (-{sold})",
                            *fill_details
                        ], status="FILL"),
                        webhook_url,
                    )
                except Exception:
                    pass

        # 리버스 진입 체크
        if should_enter_reverse(T) and mode == "normal":
            mode = "reverse"
            tracker.reverse_day = 0
            changed = True
            if webhook_url:
                try:
                    send_discord_webhook(
                        format_webhook_message("🔀 리버스모드 진입", [
                            f"📊 T={T:.2f} > {N_SPLITS-1} → 리버스 전환",
                        ], status="MODE"),
                        webhook_url,
                    )
                except Exception:
                    pass

    elif mode == "reverse":
        if new_shares < prev_shares:
            # 리버스 매도 체결
            T = t_after_reverse_sell(T)
            changed = True
        if new_shares > prev_shares:
            # 리버스 매수 체결
            T = t_after_reverse_buy(T)
            changed = True

        # 복귀 체크: 종가 ≥ 평단 × 0.80
        if new_snapshot.avg_price > 0 and should_exit_reverse(new_snapshot.current_price, new_snapshot.avg_price):
            mode = "normal"
            tracker.reverse_day = 0
            changed = True
            if webhook_url:
                try:
                    send_discord_webhook(
                        format_webhook_message("↩️ 일반모드 복귀", [
                            f"종가 ${new_snapshot.current_price:,.2f} ≥ 평단×0.80 ${new_snapshot.avg_price * REVERSE_RECOVERY_PCT:,.2f}",
                            f"📊 T={T:.2f} 유지",
                        ], status="MODE"),
                        webhook_url,
                    )
                except Exception:
                    pass

    if changed:
        tracker.T = T
        tracker.mode = mode
        if log_path:
            append_strategy_log(log_path, "t_updated", tracker, new_snapshot,
                                extra={"T": T, "mode": mode})

    return tracker


# ─────────────────────────────────────────────
# 메인 사이클
# ─────────────────────────────────────────────

def run_strategy_cycle(account_no, state_path=STATE_FILE, log_path=LOG_FILE, execute_orders=False):
    webhook_url = None
    try:
        webhook_url = load_discord_webhook_url()
    except Exception as exc:
        print(f"discord webhook load error: {exc}")
        return

    tracker = load_strategy_tracker(state_path)
    now = now_ny()
    market_open, market_close = get_us_market_times(now)
    trading_date = now.strftime("%Y-%m-%d")

    in_market = market_open <= now < market_close
    after_close = now >= market_close + timedelta(minutes=30)
    pre_market = market_open - timedelta(minutes=5) <= now < market_open

    is_weekend = now.weekday() >= 5
    is_holiday = is_weekend or not is_nyse_trading_day(trading_date)
    needs_snapshot = (
        not is_holiday
        and (
            pre_market or in_market
            or (after_close and tracker.last_post_close_report_date != trading_date)
        )
    )

    if not needs_snapshot:
        return False

    try:
        credentials = load_kis_credentials()
        access_token = get_or_refresh_access_token(credentials, tracker, state_path)
        snapshot = build_account_snapshot(account_no, credentials, access_token)

        # 종가 히스토리 갱신 (리버스모드 5MA용)
        if after_close and snapshot.current_price > 0:
            today_added = False
            if tracker.close_history:
                # 오늘 이미 추가했는지 체크 (대략적)
                if len(tracker.close_history) > 0 and tracker.close_history[-1] == snapshot.current_price:
                    today_added = True
            if not today_added:
                tracker.close_history.append(snapshot.current_price)
                if len(tracker.close_history) > 10:
                    tracker.close_history = tracker.close_history[-10:]

        # 리버스모드: reverse_day 증가
        if tracker.mode == "reverse" and in_market:
            if tracker.last_sell_order_submission_date != trading_date:
                tracker.reverse_day += 1

        tracker, sync_details = sync_tracker_with_fill_history(
            tracker,
            snapshot,
            account_no,
            trading_date,
            credentials=credentials,
            access_token=access_token,
            preserve_existing_t=False,
            return_details=True,
        )

        # 사이클 시작/종료 감지
        tracker = update_strategy_tracker(tracker, snapshot, log_path=log_path, webhook_url=webhook_url)

        if pre_market:
            maybe_send_premarket_notice(tracker, snapshot, webhook_url, now, market_open, state_path)
            maybe_submit_all_orders(account_no, tracker, snapshot, execute_orders, webhook_url, state_path, trading_date, credentials, access_token)

        if in_market:
            maybe_send_intraday_open_notice(account_no, tracker, snapshot, webhook_url, now, market_open, state_path, credentials, access_token)

        maybe_send_post_close_report(account_no, tracker, snapshot, webhook_url, now, market_close, state_path, log_path=log_path, credentials=credentials, access_token=access_token)
        tracker.last_status_notice_at = now.isoformat()
        save_strategy_tracker(state_path, tracker)

    except Exception as exc:
        error_message = f"{TARGET_SYMBOL} V4 server error: {exc}"
        print(error_message)
        try:
            send_discord_webhook(
                format_webhook_message("❌ 서버 오류", [str(exc)], status="ERROR"),
                webhook_url,
            )
        except Exception:
            pass
    return True


def send_startup_healthcheck(account_no, state_path=STATE_FILE, log_path=LOG_FILE, execute_orders=False):
    webhook_url = None
    try:
        webhook_url = load_discord_webhook_url()
    except Exception as exc:
        print(f"startup webhook load error: {exc}")
        return

    tracker = load_strategy_tracker(state_path)
    mode_label = "LIVE" if execute_orders else "PREVIEW"

    # ─── Google Sheets 초기화 ───
    global _sheets
    if _SHEETS_AVAILABLE and _sheets is None:
        try:
            env_map = load_env_file()
            _sheets = load_sheets_backend_from_env(env_map, script_dir=_SCRIPT_DIR)
        except Exception as _e:
            print(f"[sheets] 초기화 오류: {_e}")

    # state.json 없으면 시트에서 복구 시도
    if _sheets and not os.path.exists(state_path):
        try:
            sheet_state = _sheets.read_latest_state()
            if sheet_state:
                tracker.T = float(sheet_state.get("T") or 0)
                tracker.mode = str(sheet_state.get("mode") or "normal")
                tracker.cycle_no = int(sheet_state.get("cycle_no") or 1)
                try:
                    tracker.close_history = json.loads(str(sheet_state.get("close_history") or "[]"))
                except Exception:
                    tracker.close_history = []
                print(f"[sheets] state.json 없어 시트 복구: T={tracker.T} mode={tracker.mode} cycle={tracker.cycle_no}")
        except Exception as _e:
            print(f"[sheets] state 복구 오류: {_e}")

    try:
        credentials = load_kis_credentials()
        access_token = get_or_refresh_access_token(credentials, tracker, state_path)
        snapshot = build_account_snapshot(account_no, credentials, access_token)
        saved_t = tracker.T
        saved_cycle_no = tracker.cycle_no
        trading_date = now_ny().strftime("%Y-%m-%d")
        tracker, sync_details = sync_tracker_with_fill_history(
            tracker,
            snapshot,
            account_no,
            trading_date,
            credentials=credentials,
            access_token=access_token,
            preserve_existing_t=False,
            return_details=True,
        )
        tracker = update_strategy_tracker(tracker, snapshot, log_path=log_path)
        tracker.last_status_notice_at = now_ny().isoformat()
        save_strategy_tracker(state_path, tracker)
        startup_plan_message = build_startup_plan_message(snapshot, tracker, trading_date)
        ny_now_text = now_ny().strftime("%Y-%m-%d %H:%M:%S %Z")

        send_discord_webhook(
            format_webhook_message("🟢 서버 시작 확인", [
                "프로세스 시작 감지",
                f"🕒 NY Now: {ny_now_text}",
                f"🧭 Mode: {mode_label}",
                f"🔐 Account: {account_no}",
                f"📌 Startup T: {tracker.T:.2f} (saved {saved_t:.2f})",
                f"🔄 Startup Cycle: {tracker.cycle_no} (saved {saved_cycle_no})",
                f"🧠 T Sync: {sync_details['action']}",
                f"📝 Reason: {sync_details['reason']}",
                startup_plan_message,
                build_discord_status_message(snapshot, tracker),
            ], status="STARTUP"),
            webhook_url,
        )
    except Exception as exc:
        try:
            send_discord_webhook(
                format_webhook_message("❌ 서버 시작 점검 실패", [
                    f"🧭 Mode: {mode_label}",
                    f"🔐 Account: {account_no}",
                    str(exc),
                ], status="ERROR"),
                webhook_url,
            )
        except Exception:
            pass
        print(f"startup healthcheck error: {exc}")


def run_strategy_loop(account_no, poll_seconds=60, state_path=STATE_FILE, log_path=LOG_FILE, execute_orders=False):
    send_startup_healthcheck(
        account_no=account_no,
        state_path=state_path,
        log_path=log_path,
        execute_orders=execute_orders,
    )
    while True:
        try:
            run_strategy_cycle(
                account_no=account_no,
                state_path=state_path,
                log_path=log_path,
                execute_orders=execute_orders,
            )
        except Exception as exc:
            print(f"strategy loop error (will retry): {exc}")

        loop_now = now_ny()
        loop_market_open, loop_market_close = get_us_market_times(loop_now)
        active_start = loop_market_open - timedelta(minutes=10)
        active_end = loop_market_close + timedelta(minutes=35)

        is_trading_day = loop_now.weekday() < 5 and is_nyse_trading_day(loop_now.strftime("%Y-%m-%d"))

        if is_trading_day and active_start <= loop_now <= active_end:
            _tracker = load_strategy_tracker(state_path)
            pre_order_window = loop_market_open - timedelta(minutes=5) <= loop_now < loop_market_open
            if pre_order_window and _tracker.last_order_submission_date != loop_now.strftime("%Y-%m-%d"):
                effective_poll = 5
            else:
                effective_poll = 60
            time.sleep(effective_poll)
        else:
            time.sleep(600)


def send_once_status(account_no, state_path=STATE_FILE, log_path=LOG_FILE):
    webhook_url = load_discord_webhook_url()
    tracker = load_strategy_tracker(state_path)
    snapshot = build_account_snapshot(account_no)
    trading_date = now_ny().strftime("%Y-%m-%d")
    tracker, sync_details = sync_tracker_with_fill_history(
        tracker,
        snapshot,
        account_no,
        trading_date,
        preserve_existing_t=False,
        return_details=True,
    )
    tracker = update_strategy_tracker(tracker, snapshot, log_path=log_path)
    send_discord_webhook(
        format_webhook_message("📊 계좌 현황", [
            f"🧠 T Sync: {sync_details['action']} | {sync_details['reason']}",
            build_discord_status_message(snapshot, tracker),
        ], status="INFO"),
        webhook_url,
    )
    save_strategy_tracker(state_path, tracker)


def build_argument_parser():
    parser = argparse.ArgumentParser(description=f"{TARGET_SYMBOL} V4.0 무한매수법 실전 서버")
    parser.add_argument("--account", default=DEFAULT_ACCOUNT_NO)
    parser.add_argument("--poll-seconds", type=int, default=60)
    parser.add_argument("--state-path", default=STATE_FILE)
    parser.add_argument("--log-path", default=LOG_FILE)
    parser.add_argument("--execute-orders", action="store_true")
    parser.add_argument("--send-once-status", action="store_true")
    parser.add_argument("--loop", action="store_true")
    return parser


if __name__ == "__main__":
    args = build_argument_parser().parse_args()

    def _abs(p):
        return p if os.path.isabs(p) else os.path.join(_SCRIPT_DIR, p)

    state_path = _abs(args.state_path)
    log_path = _abs(args.log_path)
    account_no = args.account

    if args.send_once_status:
        send_once_status(account_no=account_no, state_path=state_path, log_path=log_path)
    elif args.loop:
        run_strategy_loop(
            account_no=account_no, poll_seconds=args.poll_seconds,
            state_path=state_path, log_path=log_path, execute_orders=args.execute_orders,
        )
    else:
        run_strategy_cycle(
            account_no=account_no, state_path=state_path,
            log_path=log_path, execute_orders=args.execute_orders,
        )
