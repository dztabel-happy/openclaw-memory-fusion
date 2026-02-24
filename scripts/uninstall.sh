#!/bin/bash
# 卸载 Memory Fusion cron jobs
# 用法: bash uninstall.sh

set -e

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

echo ""
echo "✅ Cron jobs removed."
echo ""
echo "Note: Memory files (MEMORY.md, memory/*.md) are NOT deleted."
echo "Note: QMD backend config in openclaw.json is NOT removed."
echo "      Remove 'memory' section manually if you want to revert to builtin."
