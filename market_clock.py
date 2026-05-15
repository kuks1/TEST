"""
market_clock.py — 이벤트 기반 시장 시계

사용 예:
    clock = MarketClock("XKRX")
    print(clock.summary())

    # 비동기 대기
    await clock.wait_for(MarketState.OPEN)

    # 상태 전이 콜백
    clock.on_state_change(lambda mkt, old, new: print(f"{mkt}: {old.value} → {new.value}"))
    await clock.run_forever()
"""

import asyncio
import logging
from datetime import datetime, timedelta, timezone
from enum import Enum
from typing import Callable, Optional

import exchange_calendars as xcals
import pandas as pd
import pytz

logger = logging.getLogger(__name__)


# ─────────────────────────────────────────
# 상태 정의
# ─────────────────────────────────────────

class MarketState(Enum):
    CLOSED   = "CLOSED"
    PRE_OPEN = "PRE_OPEN"
    OPEN     = "OPEN"
    POST     = "POST"


# ─────────────────────────────────────────
# 거래소별 프리/애프터 오프셋 (정규 open/close 기준)
# exchange_calendars는 정규 세션만 제공하므로 여기서 확장
# ─────────────────────────────────────────

_MARKET_OFFSETS: dict[str, dict] = {
    "XKRX": {
        # 한국: 정규 09:00-15:30 KST
        "pre_open":   timedelta(hours=-1),    # 08:00 KST
        "post_close": timedelta(hours=+2, minutes=+30),  # 18:00 KST
    },
    "XNYS": {
        # 미국: 정규 09:30-16:00 ET
        "pre_open":   timedelta(hours=-5, minutes=-30),  # 04:00 ET
        "post_close": timedelta(hours=+4),               # 20:00 ET
    },
    "XNAS": {
        # 나스닥 (NYSE와 동일 시간)
        "pre_open":   timedelta(hours=-5, minutes=-30),
        "post_close": timedelta(hours=+4),
    },
}

# 알 수 없는 거래소 폴백 (프리/애프터 없음)
_DEFAULT_OFFSET: dict = {"pre_open": timedelta(0), "post_close": timedelta(0)}


# ─────────────────────────────────────────
# MarketClock
# ─────────────────────────────────────────

class MarketClock:
    def __init__(self, market: str):
        """
        market: IANA 거래소 코드 ("XKRX", "XNYS", "XNAS", ...)
        타임존은 exchange_calendars에서 자동 결정 — 코드에 하드코딩 없음.
        """
        self._market = market
        self._cal    = xcals.get_calendar(market)
        self._tz     = pytz.timezone(self._cal.tz.key)
        self._off    = _MARKET_OFFSETS.get(market, _DEFAULT_OFFSET)

        # {date: {"pre_open", "open", "close", "post_close"}} 로컬 TZ datetime
        self._cache: dict[object, dict] = {}
        self._cache_date: Optional[object] = None

        self._on_state_change: Optional[Callable] = None

    # ── 내부 유틸 ────────────────────────────────

    def _now(self) -> datetime:
        return datetime.now(self._tz)

    def _refresh_cache(self, anchor: Optional[datetime] = None) -> None:
        """anchor 날짜 기준 10일치 세션 캐싱. 하루 1회만 실행."""
        anchor = anchor or self._now()
        today  = anchor.date()
        if self._cache_date == today:
            return

        start = pd.Timestamp(today)
        end   = pd.Timestamp(today + timedelta(days=10))

        try:
            sessions = self._cal.sessions_in_range(start, end)
        except Exception as exc:
            logger.error("[%s] sessions_in_range 실패: %s", self._market, exc)
            return

        self._cache = {}
        for session in sessions:
            open_utc  = self._cal.session_open(session)
            close_utc = self._cal.session_close(session)
            open_local  = open_utc.tz_convert(self._tz)
            close_local = close_utc.tz_convert(self._tz)

            self._cache[session.date()] = {
                "pre_open":   open_local  + self._off["pre_open"],
                "open":       open_local,
                "close":      close_local,
                "post_close": close_local + self._off["post_close"],
            }

        self._cache_date = today
        logger.debug("[%s] 캐시 갱신 완료 (%d 세션)", self._market, len(self._cache))

    def _day(self, dt: Optional[datetime] = None) -> Optional[dict]:
        """해당 날짜의 스케줄 반환. 휴장일이면 None."""
        dt = dt or self._now()
        self._refresh_cache(dt)
        return self._cache.get(dt.date())

    def _next_transition(self) -> tuple[datetime, MarketState]:
        """
        현재 시각 이후 가장 가까운 상태 전이 시각과 전이될 상태 반환.
        오늘 세션이 끝났으면 다음 영업일의 PRE_OPEN을 반환.
        """
        now = self._now()
        self._refresh_cache(now)

        for date in sorted(self._cache):
            if date < now.date():
                continue
            s = self._cache[date]
            candidates = [
                (s["pre_open"],   MarketState.PRE_OPEN),
                (s["open"],       MarketState.OPEN),
                (s["close"],      MarketState.POST),
                (s["post_close"], MarketState.CLOSED),
            ]
            for dt, state in candidates:
                if dt > now:
                    return dt, state

        raise RuntimeError(f"[{self._market}] 캐시 소진 — _refresh_cache 필요")

    # ── 공개 API ────────────────────────────────

    def state(self, dt: Optional[datetime] = None) -> MarketState:
        """현재(또는 지정) 시각의 시장 상태."""
        dt  = dt or self._now()
        day = self._day(dt)

        if day is None:
            return MarketState.CLOSED
        if dt < day["pre_open"]:
            return MarketState.CLOSED
        if dt < day["open"]:
            return MarketState.PRE_OPEN
        if dt < day["close"]:
            return MarketState.OPEN
        if dt < day["post_close"]:
            return MarketState.POST
        return MarketState.CLOSED

    def is_open(self, dt: Optional[datetime] = None) -> bool:
        """정규장 여부."""
        return self.state(dt) == MarketState.OPEN

    def next_open(self) -> datetime:
        """다음 정규장 시작 시각 (현재가 이미 장 중이어도 다음 영업일 기준)."""
        now = self._now()
        self._refresh_cache(now)
        for date in sorted(self._cache):
            s = self._cache[date]
            if s["open"] > now:
                return s["open"]
        raise RuntimeError(f"[{self._market}] 캐시 소진")

    def next_close(self) -> datetime:
        """다음 정규장 종료 시각."""
        now = self._now()
        self._refresh_cache(now)
        for date in sorted(self._cache):
            s = self._cache[date]
            if s["close"] > now:
                return s["close"]
        raise RuntimeError(f"[{self._market}] 캐시 소진")

    def on_state_change(self, callback: Callable[[str, MarketState, MarketState], None]) -> None:
        """
        상태 전이 콜백 등록.
        signature: callback(market: str, old: MarketState, new: MarketState)
        """
        self._on_state_change = callback

    async def wait_for(self, state: MarketState, timeout_sec: float = None) -> bool:
        """
        지정 상태가 될 때까지 대기 (폴링 없음, asyncio.sleep 기반).
        이미 해당 상태면 즉시 True 반환.
        timeout_sec 초 초과 시 False 반환.
        """
        if self.state() == state:
            return True

        deadline = (
            datetime.now(timezone.utc) + timedelta(seconds=timeout_sec)
            if timeout_sec else None
        )

        while True:
            now        = self._now()
            next_dt, _ = self._next_transition()
            sleep_sec  = max(1.0, (next_dt - now).total_seconds() + 1)

            if deadline:
                remaining = (deadline - datetime.now(timezone.utc)).total_seconds()
                if remaining <= 0:
                    return False
                sleep_sec = min(sleep_sec, remaining)

            logger.debug("[%s] wait_for(%s) — %.0fs 대기 중",
                         self._market, state.value, sleep_sec)
            await asyncio.sleep(sleep_sec)

            if self.state() == state:
                return True

    async def run_forever(self) -> None:
        """
        상태 머신 루프.
        - 상태 전이 시각까지 sleep → 전이 후 콜백 호출
        - 매 1시간 워치독: 캐시 무결성 확인
        - 매일 거래소 로컬 00:05에 캐시 강제 갱신
        """
        prev_state  = self.state()
        watchdog_at = datetime.now(timezone.utc) + timedelta(hours=1)

        logger.info("[%s] run_forever 시작 — 초기 상태: %s", self._market, prev_state.value)

        while True:
            now        = self._now()
            next_dt, _ = self._next_transition()
            sleep_sec  = max(1.0, (next_dt - now).total_seconds() + 1)

            # 워치독까지 남은 시간이 더 짧으면 워치독 먼저
            watchdog_remaining = (watchdog_at - datetime.now(timezone.utc)).total_seconds()
            sleep_sec = min(sleep_sec, max(1.0, watchdog_remaining))

            await asyncio.sleep(sleep_sec)

            # ── 워치독 ────────────────────────────
            if datetime.now(timezone.utc) >= watchdog_at:
                cache_ok = len(self._cache) > 0 and self._cache_date is not None
                if not cache_ok:
                    logger.warning("[%s] 워치독: 캐시 무효 — 재갱신", self._market)
                    self._cache_date = None
                    self._refresh_cache()
                watchdog_at = datetime.now(timezone.utc) + timedelta(hours=1)

            # ── 자정 캐시 갱신 (거래소 로컬 00:05) ──
            local_now = self._now()
            if local_now.hour == 0 and local_now.minute == 5:
                self._cache_date = None
                self._refresh_cache()
                logger.info("[%s] 일일 캐시 갱신 완료", self._market)

            # ── 상태 전이 감지 ────────────────────
            new_state = self.state()
            if new_state != prev_state:
                logger.info("[%s] %s → %s", self._market, prev_state.value, new_state.value)
                if self._on_state_change:
                    try:
                        self._on_state_change(self._market, prev_state, new_state)
                    except Exception as exc:
                        logger.error("[%s] 콜백 오류: %s", self._market, exc)
                prev_state = new_state

    def summary(self) -> dict:
        """현재 상태 요약. 디버그/로깅용."""
        now = self._now()
        day = self._day(now)

        def fmt(dt: Optional[datetime]) -> str:
            return dt.strftime("%m/%d %H:%M %Z") if dt else "—"

        try:
            next_dt, next_state = self._next_transition()
            next_event = f"{next_state.value} @ {fmt(next_dt)}"
        except RuntimeError:
            next_event = "—"

        return {
            "market":      self._market,
            "timezone":    str(self._tz),
            "now":         now.strftime("%Y-%m-%d %H:%M:%S %Z"),
            "state":       self.state().value,
            "is_open":     self.is_open(),
            "today_schedule": {
                "pre_open":   fmt(day["pre_open"])   if day else "휴장",
                "open":       fmt(day["open"])        if day else "휴장",
                "close":      fmt(day["close"])       if day else "휴장",
                "post_close": fmt(day["post_close"])  if day else "휴장",
            },
            "next_event":  next_event,
            "next_open":   fmt(self.next_open()),
            "next_close":  fmt(self.next_close()),
        }


# ─────────────────────────────────────────
# 빠른 확인용
# ─────────────────────────────────────────

if __name__ == "__main__":
    import sys, json
    sys.stdout.reconfigure(encoding="utf-8")
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    for mkt in ["XKRX", "XNYS"]:
        clock = MarketClock(mkt)
        print(json.dumps(clock.summary(), ensure_ascii=False, indent=2))
        print()
