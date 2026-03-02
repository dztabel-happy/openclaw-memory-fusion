#!/usr/bin/env bash
set -euo pipefail

# Patch OpenClaw-bundled OpenAI Node SDK to tolerate occasional empty SSE `data:` frames.
# Symptom: "Unexpected end of JSON input" with logs like:
#   Could not parse message into JSON:
#   From chunk: [ 'event: response.created' ]
# Fix: skip events where sse.data is empty/whitespace before JSON.parse.
#
# Usage:
#   scripts/patch-openai-sse-empty-data.sh
#   scripts/patch-openai-sse-empty-data.sh --restart

OPENCLAW_ROOT="${OPENCLAW_ROOT:-"$(npm root -g 2>/dev/null)/openclaw"}"
NEEDLE='if (!sse.data || !sse.data.trim())'

TARGETS=(
  "${OPENCLAW_ROOT}/node_modules/openai/core/streaming.js"
  "${OPENCLAW_ROOT}/node_modules/openai/core/streaming.mjs"
)

patch_one() {
  local target="$1"

  if [[ ! -f "$target" ]]; then
    echo "Target not found: $target" >&2
    return 1
  fi

  if grep -Fq "$NEEDLE" "$target"; then
    echo "Already patched: $target"
    return 0
  fi

  echo "Patching: $target"
  cp "$target" "$target.bak.$(date +%Y%m%d-%H%M%S)"

  python3 - "$target" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

old = "data = JSON.parse(sse.data);"
new = (
    "if (!sse.data || !sse.data.trim()) {\n"
    "                            continue;\n"
    "                        }\n"
    "                        data = JSON.parse(sse.data);"
)

if old not in text:
    raise SystemExit(f"pattern not found: {old}")

patched = text.replace(old, new)
path.write_text(patched)
print("ok")
PY

  echo "Patched successfully. Backup saved next to target file (*.bak.YYYYMMDD-HHMMSS)."
}

ok_any=0
for t in "${TARGETS[@]}"; do
  if patch_one "$t"; then
    ok_any=1
  fi
done

if [[ "$ok_any" != "1" ]]; then
  echo "No targets patched; set OPENCLAW_ROOT if your global install differs." >&2
  exit 1
fi

if [[ "${1:-}" == "--restart" ]]; then
  echo "Restarting gateway..."
  openclaw gateway restart
fi
