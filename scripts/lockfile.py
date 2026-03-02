#!/usr/bin/env python3
"""Tiny lockfile helper.

Purpose: coordinate cron jobs that may write the same file (e.g., MEMORY.md).

This uses an atomic create (O_EXCL). It is intentionally simple and portable.

Examples:
  python3 scripts/lockfile.py acquire --lock memory/_state/MEMORY.lock --timeout 120 --stale-seconds 7200
  python3 scripts/lockfile.py release --lock memory/_state/MEMORY.lock
"""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path


def acquire(lock_path: Path, timeout: float, stale_seconds: float) -> dict:
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.time() + timeout

    while True:
        try:
            fd = os.open(str(lock_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            try:
                payload = {
                    "pid": os.getpid(),
                    "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                }
                os.write(fd, (json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8"))
            finally:
                os.close(fd)
            return {"ok": True, "acquired": True, "lock": str(lock_path)}
        except FileExistsError:
            try:
                age = time.time() - lock_path.stat().st_mtime
            except FileNotFoundError:
                age = 0

            if age > stale_seconds:
                try:
                    lock_path.unlink(missing_ok=True)
                except Exception:
                    pass
            else:
                if time.time() >= deadline:
                    return {
                        "ok": False,
                        "acquired": False,
                        "lock": str(lock_path),
                        "reason": "timeout",
                        "ageSeconds": round(age, 1),
                    }
                time.sleep(1.0)


def release(lock_path: Path) -> dict:
    try:
        lock_path.unlink(missing_ok=True)
        return {"ok": True, "released": True, "lock": str(lock_path)}
    except Exception as exc:
        return {"ok": False, "released": False, "lock": str(lock_path), "error": str(exc)}


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    acq = sub.add_parser("acquire")
    acq.add_argument("--lock", required=True)
    acq.add_argument("--timeout", type=float, default=120)
    acq.add_argument("--stale-seconds", type=float, default=7200)

    rel = sub.add_parser("release")
    rel.add_argument("--lock", required=True)

    args = parser.parse_args()
    lock_path = Path(args.lock).expanduser()

    if args.cmd == "acquire":
        result = acquire(lock_path, timeout=args.timeout, stale_seconds=args.stale_seconds)
    else:
        result = release(lock_path)

    print(json.dumps(result, ensure_ascii=False))
    raise SystemExit(0 if result.get("ok") else 1)


if __name__ == "__main__":
    main()
