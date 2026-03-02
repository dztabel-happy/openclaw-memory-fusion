#!/usr/bin/env python3
"""Weekly at-least-once gate.

Why:
- A cron scheduled "once per week" can be missed if the machine sleeps.
- Scheduling it daily + gating ensures it runs at least once per ISO week.

Modes:
- check: decide whether to run this week and suggest lookback days
- mark: record a successful weekly run

State file schema:
{
  "version": 1,
  "lastWeekKey": "2026-W10",
  "lastMarkedAt": "2026-03-02T00:30:00+08:00"
}
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

try:
    from zoneinfo import ZoneInfo  # py3.9+
except Exception:  # pragma: no cover
    ZoneInfo = None


def now_in_tz(tz_name: str) -> datetime:
    if ZoneInfo is not None:
        try:
            tz = ZoneInfo(tz_name)
        except Exception:
            tz = timezone(timedelta(hours=8))
    else:
        tz = timezone(timedelta(hours=8))
    return datetime.now(tz)


def week_key(dt: datetime) -> str:
    iso = dt.isocalendar()
    return f"{iso.year}-W{iso.week:02d}"


def load_state(path: Path) -> dict:
    if not path.exists():
        return {"version": 1}
    try:
        return json.loads(path.read_text())
    except Exception:
        return {"version": 1}


def save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")


def parse_dt(value: str) -> datetime | None:
    try:
        return datetime.fromisoformat(value)
    except Exception:
        return None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", required=True)
    ap.add_argument("--timezone", default="Asia/Shanghai")
    ap.add_argument("--mode", choices=["check", "mark"], default="check")
    ap.add_argument("--max-lookback-days", type=int, default=30)
    args = ap.parse_args()

    state_path = Path(args.state).expanduser()
    state = load_state(state_path)

    now = now_in_tz(args.timezone)
    wk = week_key(now)

    last_wk = state.get("lastWeekKey")
    last_marked_at = parse_dt(state.get("lastMarkedAt", "")) if isinstance(state.get("lastMarkedAt"), str) else None

    if args.mode == "mark":
        state["version"] = 1
        state["lastWeekKey"] = wk
        state["lastMarkedAt"] = now.isoformat()
        save_state(state_path, state)
        print(json.dumps({"ok": True, "mode": "mark", "weekKey": wk, "state": str(state_path)}, ensure_ascii=False))
        return

    should_run = last_wk != wk
    since_days = None
    if last_marked_at is not None:
        since_days = (now - last_marked_at).days

    # Suggested lookback: if we haven't run for >7 days, widen the window (<=30).
    lookback = 7
    if since_days is None:
        lookback = 7
    else:
        lookback = min(args.max_lookback_days, max(7, since_days + 2))

    result = {
        "ok": True,
        "mode": "check",
        "weekKey": wk,
        "lastWeekKey": last_wk,
        "shouldRun": should_run,
        "sinceLastMarkedDays": since_days,
        "suggestedLookbackDays": lookback,
        "state": str(state_path),
    }
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
