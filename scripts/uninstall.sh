#!/bin/bash
# 卸载 Memory Fusion cron jobs
# 用法: bash scripts/uninstall.sh [--workspace ~/.openclaw/workspace] [--purge]

set -euo pipefail

WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"
PURGE=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --purge) PURGE=1; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "🗑️  Removing Memory Fusion cron jobs..."

for JOB_ID in $(openclaw cron list --json 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    jobs = data if isinstance(data, list) else data.get('jobs', [])
    for j in jobs:
        if j.get('name','').startswith('memory-'):
            print(j['id'])
except: pass
" 2>/dev/null); do
  echo "  Removing: $JOB_ID"
  openclaw cron delete "$JOB_ID" 2>/dev/null || true
done

if [ "$PURGE" -eq 1 ]; then
  echo ""
  echo "🧹 Purging helper scripts and state files..."
  rm -f "$WORKSPACE/scripts/scan_sessions_incremental.py" 2>/dev/null || true
  rm -f "$WORKSPACE/scripts/patch-openai-sse-empty-data.sh" 2>/dev/null || true
  rm -f "$WORKSPACE/memory/_state/scan_sessions_hourly.json" 2>/dev/null || true
  rm -f "$WORKSPACE/memory/_state/scan_sessions_daily.json" 2>/dev/null || true
  echo "  ✅ Purge done."
fi

echo ""
echo "✅ Cron jobs removed."
echo ""
echo "Note: Memory files (MEMORY.md, memory/*.md) are NOT deleted."
echo "Note: QMD backend config in openclaw.json is NOT removed."
echo "      Remove 'memory' section manually if you want to revert to builtin."
