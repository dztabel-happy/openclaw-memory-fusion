#!/usr/bin/env bash
set -euo pipefail

# Patch OpenClaw-bundled OpenAI Node SDK to tolerate occasional empty SSE `data:` frames.
#
# Symptom
# - cron/normal tasks fail with: "Unexpected end of JSON input"
# - and gateway.err.log contains lines like:
#   - "Could not parse message into JSON:" (empty)
#   - "From chunk: [ 'event: response.created' ]"
#
# Root cause
# - Some upstream OpenAI-Responses-compatible proxies occasionally emit SSE events where
#   `event:` arrives without a non-empty `data:` payload in the same frame.
# - The OpenAI Node SDK tries JSON.parse("") and crashes.
#
# Fix
# - Skip SSE events whose sse.data is empty/whitespace before JSON.parse.
#
# Usage
#   scripts/patch-openai-sse-empty-data.sh
#   scripts/patch-openai-sse-empty-data.sh --restart

OPENCLAW_ROOT="${OPENCLAW_ROOT:-"$(npm root -g 2>/dev/null)/openclaw"}"
TARGET="${OPENCLAW_ROOT}/node_modules/openai/core/streaming.js"
NEEDLE='if (!sse.data || !sse.data.trim()) { continue; }'

if [[ ! -f "${TARGET}" ]]; then
  echo "Target not found: ${TARGET}" >&2
  echo "Hint: set OPENCLAW_ROOT to your global openclaw install dir (the folder that contains node_modules/)." >&2
  exit 1
fi

if grep -Fq "${NEEDLE}" "${TARGET}"; then
  echo "Already patched: ${TARGET}"
else
  echo "Patching: ${TARGET}"
  cp "${TARGET}" "${TARGET}.bak.$(date +%Y%m%d-%H%M%S)"

  python3 - "${TARGET}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

old = "data = JSON.parse(sse.data);"
new = "if (!sse.data || !sse.data.trim()) { continue; }\n                            data = JSON.parse(sse.data);"

if old not in text:
    raise SystemExit(f"pattern not found: {old}")

# Replace all occurrences (typically 2 in this file).
patched = text.replace(old, new)
path.write_text(patched)
print("ok")
PY

  echo "Patched successfully. Backup saved next to target file (*.bak.YYYYMMDD-HHMMSS)."
fi

if [[ "${1:-}" == "--restart" ]]; then
  echo "Restarting gateway..."
  openclaw gateway restart
fi
