#!/usr/bin/env python3
"""
Incrementally scan OpenClaw session JSONL files and emit only valuable signals.

Design goals (2026-03-01):
- Cron MUST NOT rely on sessions_list/sessions_history (isolated cron may not see main session tree).
- Scan ~/.openclaw/agents/<agent>/sessions/*.jsonl and *.jsonl.reset.* instead.
- Maintain per-file byte offsets; advance only to last complete newline; tolerate partial last line.
- Prevent recursion ("套娃"):
  - Ignore cron-run sessions (heuristic: first user message starts with "[cron:").
  - Ignore notify messages like "memory-hourly ok" and "NO_REPLY".
  - Ignore system banners; ignore tool outputs.
- Valuable signal = user messages + assistant final replies.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as _dt
import glob
import json
import os
import re
import sys
from typing import Any, Dict, Iterable, List, Optional, Tuple


STATE_VERSION = 1

DEFAULT_OPENCLAW_DIR = os.path.join("~", ".openclaw")
DEFAULT_AGENT = "main"
DEFAULT_STATE_FILE = os.path.join("memory", "_state", "scan_sessions_incremental.json")


_RE_NOTIFY_OK = re.compile(r"^memory-(hourly|daily|weekly)\s+ok\b", re.IGNORECASE)


# Redaction patterns (best-effort). The goal is to prevent secrets from ever entering
# the LLM summarization prompt.
_RE_SK = re.compile(r"sk-[A-Za-z0-9]{10,}")
_RE_TG_BOT = re.compile(r"\d{6,12}:[A-Za-z0-9_-]{20,}")
_RE_GOOGLE_API_KEY = re.compile(r"AIza[0-9A-Za-z_-]{20,}")
_RE_BEARER = re.compile(r"(?i)Bearer\s+([A-Za-z0-9._-]{10,})")


@dataclasses.dataclass
class Message:
    session_id: str
    path: str
    role: str  # "user" | "assistant"
    text: str


def _utc_now_iso() -> str:
    return _dt.datetime.now(tz=_dt.timezone.utc).replace(microsecond=0).isoformat()


def _expand(path: str) -> str:
    return os.path.abspath(os.path.expanduser(path))


def _ensure_parent_dir(path: str) -> None:
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)


def _atomic_write_json(path: str, data: Dict[str, Any]) -> None:
    _ensure_parent_dir(path)
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def _load_state(path: str) -> Dict[str, Any]:
    if not os.path.exists(path):
        return {
            "version": STATE_VERSION,
            "updated_at": None,
            "files": {},  # inode_key -> record
            "session_offsets": {},  # session_id -> offset
            "session_flags": {},  # session_id -> {is_cron_session: bool}
        }
    try:
        with open(path, "r", encoding="utf-8") as f:
            state = json.load(f)
        if not isinstance(state, dict) or state.get("version") != STATE_VERSION:
            raise ValueError("state version mismatch")
        for k in ("files", "session_offsets", "session_flags"):
            if k not in state or not isinstance(state[k], dict):
                state[k] = {}
        return state
    except Exception:
        # Corrupt state: start fresh (safer than crashing cron).
        return {
            "version": STATE_VERSION,
            "updated_at": None,
            "files": {},
            "session_offsets": {},
            "session_flags": {},
            "warnings": [f"State file unreadable; reset: {path}"],
        }


def _inode_key(st: os.stat_result) -> str:
    return f"{getattr(st, 'st_dev', 0)}:{getattr(st, 'st_ino', 0)}"


def _session_id_from_filename(filename: str) -> str:
    base = os.path.basename(filename)
    if base.endswith(".jsonl"):
        return base[: -len(".jsonl")]
    marker = ".jsonl.reset."
    if marker in base:
        return base.split(marker, 1)[0]
    return os.path.splitext(base)[0]


def _candidate_message_obj(obj: Any) -> Optional[Dict[str, Any]]:
    if not isinstance(obj, dict):
        return None
    if "role" in obj and ("content" in obj or "text" in obj):
        return obj
    for k in ("message", "msg", "data", "item"):
        nested = obj.get(k)
        if isinstance(nested, dict) and "role" in nested and ("content" in nested or "text" in nested):
            return nested
    return None


def _content_to_text(content: Any) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, dict):
        if "text" in content:
            return _content_to_text(content.get("text"))
        if "content" in content:
            return _content_to_text(content.get("content"))
        if "value" in content:
            return _content_to_text(content.get("value"))
        return ""
    if isinstance(content, list):
        parts: List[str] = []
        for part in content:
            if isinstance(part, str):
                parts.append(part)
                continue
            if isinstance(part, dict):
                # OpenAI Responses-style parts often use {"type": "..._text", "text": "..."}
                if isinstance(part.get("text"), str):
                    parts.append(part["text"])
                    continue
                if isinstance(part.get("content"), str):
                    parts.append(part["content"])
                    continue
                if isinstance(part.get("content"), list) or isinstance(part.get("content"), dict):
                    nested = _content_to_text(part.get("content"))
                    if nested:
                        parts.append(nested)
                        continue
        return "".join(parts)
    return ""


def _is_final_assistant_message(msg_obj: Dict[str, Any], text: str) -> bool:
    if not text.strip():
        return False
    # Tool-call-only assistant messages are not useful for memory extraction.
    if msg_obj.get("tool_calls") or msg_obj.get("tool_call_id"):
        return False
    return True


def _redact_secrets(s: str) -> str:
    s = _RE_SK.sub("sk-***REDACTED***", s)
    s = _RE_TG_BOT.sub("<TELEGRAM_BOT_TOKEN_REDACTED>", s)
    s = _RE_GOOGLE_API_KEY.sub("AIza***REDACTED***", s)
    s = _RE_BEARER.sub("Bearer ***REDACTED***", s)
    return s


def _strip_conversation_info_wrapper(s: str) -> str:
    # Telegram relay may prefix messages with:
    #   Conversation info (untrusted metadata):
    #   ```json
    #   {...}
    #   ```
    #   <actual text>
    if not (s.startswith("Conversation info") and "untrusted metadata" in s):
        return s
    first = s.find("```")
    if first == -1:
        return s
    second = s.find("```", first + 3)
    if second == -1:
        return s
    return s[second + 3 :].strip()


def _strip_tag_blocks(s: str) -> str:
    # Remove accidental <think> blocks, keep <final> content.
    s = re.sub(r"<think>[\s\S]*?</think>", "", s, flags=re.IGNORECASE)
    s = s.replace("<final>", "").replace("</final>", "")
    return s


def _normalize_text(s: str, role: str) -> str:
    s = (s or "").strip()
    s = _strip_conversation_info_wrapper(s)
    s = _strip_tag_blocks(s)
    s = _redact_secrets(s)
    return s.strip()


def _should_ignore_text(text: str) -> bool:
    s = text.strip()
    if not s:
        return True

    # Do not let cron self-notifications or system banners become memory inputs.
    if s == "NO_REPLY":
        return True
    if _RE_NOTIFY_OK.match(s):
        return True
    if s.startswith("System:"):
        return True
    if s.startswith("已连接到群："):
        return True
    if s.startswith("[") and (
        "[System Message]" in s
        or "Exec completed" in s
        or "Queued announce messages" in s
        or "A cron job" in s
    ):
        return True
    return False


def _classify_is_cron_session(
    path: str,
    session_id: str,
    state: Dict[str, Any],
    *,
    max_probe_lines: int = 4000,
) -> Optional[bool]:
    flags = state.get("session_flags", {}).get(session_id)
    if isinstance(flags, dict) and "is_cron_session" in flags:
        v = flags["is_cron_session"]
        if isinstance(v, bool):
            return v
    # Probe from the start until the first user message.
    try:
        with open(path, "rb") as f:
            for _ in range(max_probe_lines):
                line = f.readline()
                if not line:
                    break
                if not line.endswith(b"\n"):
                    break
                try:
                    obj = json.loads(line.decode("utf-8", errors="replace"))
                except Exception:
                    continue
                msg_obj = _candidate_message_obj(obj)
                if not msg_obj:
                    continue
                role = msg_obj.get("role")
                if role != "user":
                    continue
                text = _content_to_text(msg_obj.get("content", msg_obj.get("text")))
                text = _normalize_text(text, role)
                is_cron = text.lstrip().startswith("[cron:")
                state.setdefault("session_flags", {}).setdefault(session_id, {})["is_cron_session"] = is_cron
                return is_cron
    except FileNotFoundError:
        return None
    except PermissionError:
        return None
    return None


def _iter_session_files(sessions_dir: str) -> Iterable[str]:
    patterns = [
        os.path.join(sessions_dir, "*.jsonl"),
        os.path.join(sessions_dir, "*.jsonl.reset.*"),
    ]
    seen: set[str] = set()
    for pat in patterns:
        for p in glob.glob(pat):
            if p not in seen:
                seen.add(p)
                yield p


def scan_incremental(
    sessions_dir: str,
    state_path: str,
    *,
    include_user: bool = True,
    include_assistant: bool = True,
    max_messages: Optional[int] = None,
    max_chars: Optional[int] = None,
    ignore_cron_sessions: bool = True,
) -> Tuple[Dict[str, Any], List[Message]]:
    state = _load_state(state_path)
    warnings: List[str] = []

    files_total = 0
    files_with_new = 0
    lines_read = 0
    parse_errors = 0
    messages_emitted = 0
    messages_ignored = 0
    truncated = False

    messages: List[Message] = []

    # Deterministic-ish ordering: newer files first (helps cron summarize freshest context).
    file_paths = list(_iter_session_files(sessions_dir))
    file_paths.sort(key=lambda p: os.path.getmtime(p) if os.path.exists(p) else 0, reverse=True)

    for path in file_paths:
        files_total += 1
        try:
            st = os.stat(path)
        except FileNotFoundError:
            continue
        except PermissionError:
            warnings.append(f"Permission denied: {path}")
            continue

        inode = _inode_key(st)
        session_id = _session_id_from_filename(path)

        if ignore_cron_sessions:
            is_cron = _classify_is_cron_session(path, session_id, state)
            if is_cron is True:
                # Still advance cursor to avoid re-reading forever.
                state.setdefault("files", {}).setdefault(inode, {})["offset"] = st.st_size
                state["files"][inode].update(
                    {
                        "path": path,
                        "session_id": session_id,
                        "size": st.st_size,
                        "mtime": st.st_mtime,
                        "last_seen": _utc_now_iso(),
                    }
                )
                state.setdefault("session_offsets", {})[session_id] = max(
                    int(state.get("session_offsets", {}).get(session_id, 0)), int(st.st_size)
                )
                continue

        prev = state.get("files", {}).get(inode)
        offset: int
        if isinstance(prev, dict) and isinstance(prev.get("offset"), int):
            offset = int(prev["offset"])
        else:
            # Fallback for renames/copies: use session-level offset if present.
            offset = int(state.get("session_offsets", {}).get(session_id, 0))

        if offset < 0:
            offset = 0
        if st.st_size < offset:
            # Truncated/replaced.
            offset = 0

        if st.st_size == offset:
            # No new bytes.
            state.setdefault("files", {}).setdefault(inode, {}).update(
                {
                    "path": path,
                    "session_id": session_id,
                    "offset": offset,
                    "size": st.st_size,
                    "mtime": st.st_mtime,
                    "last_seen": _utc_now_iso(),
                }
            )
            continue

        files_with_new += 1

        bytes_advanced = 0
        try:
            with open(path, "rb") as f:
                f.seek(offset)
                while True:
                    line = f.readline()
                    if not line:
                        break
                    if not line.endswith(b"\n"):
                        # Partial last line at EOF: do not advance past it.
                        break
                    bytes_advanced += len(line)
                    lines_read += 1

                    raw = line.decode("utf-8", errors="replace").rstrip("\n")
                    try:
                        obj = json.loads(raw)
                    except Exception:
                        parse_errors += 1
                        continue

                    msg_obj = _candidate_message_obj(obj)
                    if not msg_obj:
                        continue

                    role = msg_obj.get("role")
                    if role == "tool" or role == "system":
                        messages_ignored += 1
                        continue

                    text = _content_to_text(msg_obj.get("content", msg_obj.get("text")))
                    text = _normalize_text(text, role)
                    if max_chars is not None and isinstance(max_chars, int) and max_chars > 0:
                        if len(text) > max_chars:
                            text = text[: max_chars - 1] + "…"

                    if _should_ignore_text(text):
                        messages_ignored += 1
                        continue

                    if role == "user" and include_user:
                        messages.append(Message(session_id=session_id, path=path, role="user", text=text))
                        messages_emitted += 1
                    elif role == "assistant" and include_assistant:
                        if _is_final_assistant_message(msg_obj, text):
                            messages.append(
                                Message(session_id=session_id, path=path, role="assistant", text=text)
                            )
                            messages_emitted += 1
                        else:
                            messages_ignored += 1
                    else:
                        messages_ignored += 1

                    if max_messages is not None and messages_emitted >= max_messages:
                        truncated = True
                        break
        except FileNotFoundError:
            continue
        except PermissionError:
            warnings.append(f"Permission denied: {path}")
            continue

        new_offset = offset + bytes_advanced

        state.setdefault("files", {}).setdefault(inode, {}).update(
            {
                "path": path,
                "session_id": session_id,
                "offset": new_offset,
                "size": st.st_size,
                "mtime": st.st_mtime,
                "last_seen": _utc_now_iso(),
            }
        )
        state.setdefault("session_offsets", {})[session_id] = max(
            int(state.get("session_offsets", {}).get(session_id, 0)), int(new_offset)
        )

        if truncated:
            break

    state["updated_at"] = _utc_now_iso()
    if warnings:
        state.setdefault("warnings", [])
        for w in warnings:
            if w not in state["warnings"]:
                state["warnings"].append(w)

    report = {
        "ok": True,
        "version": STATE_VERSION,
        "sessions_dir": sessions_dir,
        "state_file": state_path,
        "updated_at": state["updated_at"],
        "stats": {
            "files_total": files_total,
            "files_with_new_bytes": files_with_new,
            "lines_read": lines_read,
            "parse_errors": parse_errors,
            "messages_emitted": messages_emitted,
            "messages_ignored": messages_ignored,
            "truncated": truncated,
        },
        "warnings": warnings,
    }

    _atomic_write_json(state_path, state)
    return report, messages


def _render_json(report: Dict[str, Any], messages: List[Message]) -> str:
    sessions: Dict[str, Dict[str, Any]] = {}
    for m in messages:
        s = sessions.setdefault(
            m.session_id,
            {"session_id": m.session_id, "path": m.path, "messages": []},
        )
        s["path"] = m.path
        s["messages"].append({"role": m.role, "text": m.text})
    out = dict(report)
    out["sessions"] = list(sessions.values())
    return json.dumps(out, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def _render_md(report: Dict[str, Any], messages: List[Message]) -> str:
    stats = report.get("stats", {})
    lines = [
        "# scan_sessions_incremental",
        "",
        f"- sessions_dir: `{report.get('sessions_dir')}`",
        f"- state_file: `{report.get('state_file')}`",
        f"- files_total: {stats.get('files_total')}",
        f"- files_with_new_bytes: {stats.get('files_with_new_bytes')}",
        f"- messages_emitted: {stats.get('messages_emitted')}",
        f"- messages_ignored: {stats.get('messages_ignored')}",
        f"- parse_errors: {stats.get('parse_errors')}",
    ]
    if stats.get("truncated"):
        lines.append("- truncated: true (rerun to continue)")
    if report.get("warnings"):
        lines.append("")
        lines.append("## warnings")
        for w in report["warnings"]:
            lines.append(f"- {w}")

    grouped: Dict[str, List[Message]] = {}
    for m in messages:
        grouped.setdefault(m.session_id, []).append(m)

    for session_id, msgs in grouped.items():
        lines.append("")
        basename = os.path.basename(msgs[0].path) if msgs else session_id
        lines.append(f"## {session_id} ({basename})")
        for m in msgs:
            prefix = "U" if m.role == "user" else "A"
            text = m.text.replace("\r\n", "\n").replace("\r", "\n")
            text = text.strip()
            # Keep output compact and LLM-friendly.
            text = re.sub(r"\n{3,}", "\n\n", text)
            if "\n" in text:
                indented = "\n".join("  " + ln for ln in text.splitlines())
                lines.append(f"- {prefix}:")
                lines.append(indented)
            else:
                lines.append(f"- {prefix}: {text}")

    lines.append("")
    return "\n".join(lines)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Incrementally scan OpenClaw session JSONL files.")
    parser.add_argument("--openclaw-dir", default=DEFAULT_OPENCLAW_DIR, help="Default: ~/.openclaw")
    parser.add_argument("--agent", default=DEFAULT_AGENT, help="Default: main")
    parser.add_argument(
        "--sessions-dir",
        default=None,
        help="Override sessions dir. Default: <openclaw-dir>/agents/<agent>/sessions",
    )
    parser.add_argument("--state-file", default=DEFAULT_STATE_FILE, help="Default: memory/_state/...")
    parser.add_argument("--format", choices=["json", "md"], default="json")
    parser.add_argument("--max-messages", type=int, default=None, help="Stop after emitting N messages.")
    parser.add_argument("--max-chars", type=int, default=None, help="Truncate each message text to N chars.")
    parser.add_argument("--no-user", action="store_true", help="Do not emit user messages.")
    parser.add_argument("--no-assistant", action="store_true", help="Do not emit assistant messages.")
    parser.add_argument("--include-cron", action="store_true", help="Do not ignore [cron:*] sessions.")

    args = parser.parse_args(argv)

    sessions_dir = (
        _expand(args.sessions_dir)
        if args.sessions_dir
        else _expand(os.path.join(args.openclaw_dir, "agents", args.agent, "sessions"))
    )
    state_file = _expand(args.state_file)

    if not os.path.isdir(sessions_dir):
        sys.stderr.write(f"[scan_sessions_incremental] sessions dir not found: {sessions_dir}\n")
        sys.stderr.write("Hint: pass --sessions-dir or --openclaw-dir/--agent.\n")
        return 2

    report, messages = scan_incremental(
        sessions_dir,
        state_file,
        include_user=not args.no_user,
        include_assistant=not args.no_assistant,
        max_messages=args.max_messages,
        max_chars=args.max_chars,
        ignore_cron_sessions=not args.include_cron,
    )

    try:
        if args.format == "md":
            sys.stdout.write(_render_md(report, messages))
        else:
            sys.stdout.write(_render_json(report, messages))
    except BrokenPipeError:
        # e.g. piping into `head` which closes early.
        try:
            sys.stdout.close()
        except Exception:
            pass
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

