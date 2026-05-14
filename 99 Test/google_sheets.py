"""
google_sheets.py — Google Sheets 연동
- 서비스 계정 인증 (google_sa_key.json)
- 시트 읽기 / 쓰기 / 행 추가
"""

import os
from pathlib import Path
from typing import Any, Optional

import gspread
from dotenv import load_dotenv
from google.oauth2.service_account import Credentials

load_dotenv()

_SA_KEY_PATH   = Path(__file__).parent / os.getenv("GOOGLE_SA_KEY_PATH", "google_sa_key.json")
_SHEETS_ID     = os.getenv("GOOGLE_SHEETS_ID", "")
_SCOPES        = [
    "https://spreadsheets.google.com/feeds",
    "https://www.googleapis.com/auth/drive",
]

# gspread 클라이언트 (모듈 로드 시 1회 초기화)
_gc: Optional[gspread.Client] = None


def _client() -> gspread.Client:
    global _gc
    if _gc is None:
        creds = Credentials.from_service_account_file(str(_SA_KEY_PATH), scopes=_SCOPES)
        _gc = gspread.authorize(creds)
    return _gc


def _worksheet(sheet_id: str, tab: str | int) -> gspread.Worksheet:
    """sheet_id의 워크시트 반환. tab은 이름(str) 또는 인덱스(int, 0-based)."""
    sh = _client().open_by_key(sheet_id)
    if isinstance(tab, int):
        return sh.get_worksheet(tab)
    return sh.worksheet(tab)


# ── 읽기 ────────────────────────────────────────────────────

def read_all(tab: str | int = 0, sheet_id: str = _SHEETS_ID) -> list[dict]:
    """
    시트 전체를 [{헤더: 값, ...}, ...] 형태로 반환.
    첫 행을 헤더로 사용.
    """
    ws = _worksheet(sheet_id, tab)
    return ws.get_all_records()


def read_range(cell_range: str, tab: str | int = 0, sheet_id: str = _SHEETS_ID) -> list[list]:
    """
    지정 범위를 2D 리스트로 반환.
    cell_range 예: "A1:D10", "A:C"
    """
    ws = _worksheet(sheet_id, tab)
    return ws.get(cell_range)


def read_col(col: int | str, tab: str | int = 0, sheet_id: str = _SHEETS_ID) -> list:
    """
    열 전체 값 리스트 반환.
    col: 1-based int 또는 "A", "B" 등 열 문자
    """
    ws = _worksheet(sheet_id, tab)
    if isinstance(col, str):
        col = gspread.utils.column_letter_to_index(col)
    return ws.col_values(col)


def read_row(row: int, tab: str | int = 0, sheet_id: str = _SHEETS_ID) -> list:
    """행 전체 값 리스트 반환. row: 1-based."""
    ws = _worksheet(sheet_id, tab)
    return ws.row_values(row)


# ── 쓰기 ────────────────────────────────────────────────────

def write_cell(cell: str, value: Any, tab: str | int = 0, sheet_id: str = _SHEETS_ID) -> None:
    """
    단일 셀 값 업데이트.
    cell 예: "A1", "B3"
    """
    ws = _worksheet(sheet_id, tab)
    ws.update_acell(cell, value)


def write_range(cell_range: str, values: list[list], tab: str | int = 0, sheet_id: str = _SHEETS_ID) -> None:
    """
    범위 일괄 업데이트.
    values: 2D 리스트 [[row1col1, row1col2], [row2col1, ...]]
    """
    ws = _worksheet(sheet_id, tab)
    ws.update(cell_range, values)


def append_row(values: list, tab: str | int = 0, sheet_id: str = _SHEETS_ID) -> None:
    """마지막 데이터 다음 행에 새 행 추가."""
    ws = _worksheet(sheet_id, tab)
    ws.append_row(values, value_input_option="USER_ENTERED")


def append_rows(rows: list[list], tab: str | int = 0, sheet_id: str = _SHEETS_ID) -> None:
    """여러 행을 한 번에 추가."""
    ws = _worksheet(sheet_id, tab)
    ws.append_rows(rows, value_input_option="USER_ENTERED")


# ── 시트 정보 ────────────────────────────────────────────────

def list_tabs(sheet_id: str = _SHEETS_ID) -> list[str]:
    """워크시트 탭 이름 목록 반환."""
    sh = _client().open_by_key(sheet_id)
    return [ws.title for ws in sh.worksheets()]


# ── 빠른 확인용 ─────────────────────────────────────────────

if __name__ == "__main__":
    import sys, json
    sys.stdout.reconfigure(encoding="utf-8")

    print("=== 탭 목록 ===")
    tabs = list_tabs()
    print(tabs)

    print(f"\n=== 첫 번째 탭 전체 (최대 3행) ===")
    rows = read_all(tab=0)
    for r in rows[:3]:
        print(json.dumps(r, ensure_ascii=False))
