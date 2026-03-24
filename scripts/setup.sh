#!/bin/bash
# OpenClaw Memory Fusion - setup script
# Usage:
#   bash scripts/setup.sh \
#     [--tz Asia/Shanghai] \
#     [--hourly-model google/gemini-3-flash-preview] \
#     [--daily-model openrouter/minimax/minimax-m2.5] \
#     [--weekly-model anyrouter/claude-opus-4-6] \
#     [--notify-channel telegram] \
#     [--notify-to <TELEGRAM_CHAT_ID>:topic:<TOPIC_ID>] \
#     [--notify-account default] \
#     [--workspace ~/.openclaw/workspace]

set -euo pipefail

# 默认值
TZ="${TZ:-Asia/Shanghai}"
HOURLY_MODEL="${HOURLY_MODEL:-google/gemini-3-flash-preview}"
DAILY_MODEL="${DAILY_MODEL:-openrouter/minimax/minimax-m2.5}"
WEEKLY_MODEL="${WEEKLY_MODEL:-anyrouter/claude-opus-4-6}"
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"
HOURLY_CRON="${HOURLY_CRON:-0 7,11,15,19,23 * * *}"
NOTIFY_CHANNEL="${OPENCLAW_NOTIFY_CHANNEL:-telegram}"
NOTIFY_TO="${OPENCLAW_NOTIFY_TO:-}"
NOTIFY_ACCOUNT="${OPENCLAW_NOTIFY_ACCOUNT:-}"
CONFIG="$HOME/.openclaw/openclaw.json"

# 解析参数
while [[ $# -gt 0 ]]; do
  case $1 in
    --tz) TZ="$2"; shift 2 ;;
    --hourly-model) HOURLY_MODEL="$2"; shift 2 ;;
    --daily-model) DAILY_MODEL="$2"; shift 2 ;;
    --weekly-model) WEEKLY_MODEL="$2"; shift 2 ;;
    --notify-channel) NOTIFY_CHANNEL="$2"; shift 2 ;;
    --notify-to) NOTIFY_TO="$2"; shift 2 ;;
    --notify-account) NOTIFY_ACCOUNT="$2"; shift 2 ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "🧠 OpenClaw Memory Fusion Setup"
echo "================================"
echo "Timezone:      $TZ"
echo "Hourly cron:   $HOURLY_CRON"
echo "Hourly model:  $HOURLY_MODEL"
echo "Daily model:   $DAILY_MODEL"
echo "Weekly model:  $WEEKLY_MODEL"
echo "Notify channel:$NOTIFY_CHANNEL"
echo "Notify to:     ${NOTIFY_TO:-<last-route fallback>}"
echo "Notify account:${NOTIFY_ACCOUNT:-<default>}"
echo "Workspace:     $WORKSPACE"
echo ""

# Preflight: OpenClaw CLI
if ! command -v openclaw >/dev/null 2>&1; then
  echo "❌ openclaw CLI not found in PATH."
  echo "   Install OpenClaw first, then rerun this script."
  exit 1
fi

# Step 1: 检查并安装 QMD
echo "📦 Step 1: Checking QMD..."

# Prefer whichever qmd is already in PATH.
if command -v qmd >/dev/null 2>&1; then
  echo "  ✅ QMD found: $(command -v qmd)"
else
  echo "  ⚠️  QMD not found."
  echo "  🔧 Installing via npm (推荐，预编译开箱即用)..."
  if ! command -v npm &> /dev/null; then
    echo "  ❌ npm not found. Please install Node.js first: https://nodejs.org"
    exit 1
  fi
  npm install -g @tobilu/qmd
  if command -v qmd >/dev/null 2>&1; then
    echo "  ✅ QMD installed: $(command -v qmd)"
  else
    echo "  ❌ QMD install failed. Please install manually."
    exit 1
  fi
fi
echo ""

# Step 1.5: 检查 qmd 可执行（OpenClaw 会管理实际 sidecar index）
echo "🔍 Step 1.5: Verifying qmd executable..."
if qmd --help >/dev/null 2>&1; then
  echo "  ✅ qmd executable responds"
  echo "  ℹ️  OpenClaw 2026.3+ 会在自己的 sidecar/XDG home 中管理实际索引。"
  echo "     配置完成后请优先用: openclaw memory status --agent main --index"
else
  echo "  ❌ qmd executable test failed."
  exit 1
fi
echo ""

# Step 2: 创建目录结构 + 状态目录
echo "📁 Step 2: Creating directory structure..."
mkdir -p "$WORKSPACE/memory/weekly"
mkdir -p "$WORKSPACE/memory/archive/$(date +%Y)"
mkdir -p "$WORKSPACE/memory/_state"
mkdir -p "$WORKSPACE/scripts"
echo "  ✅ $WORKSPACE/memory/weekly/"
echo "  ✅ $WORKSPACE/memory/archive/$(date +%Y)/"
echo "  ✅ $WORKSPACE/memory/_state/"
echo "  ✅ $WORKSPACE/scripts/"
echo ""

# Step 3: 安装 helper scripts（供 cron exec 调用）
echo "🧩 Step 3: Installing helper scripts..."
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cp -f "$SCRIPT_DIR/scan_sessions_incremental.py" "$WORKSPACE/scripts/scan_sessions_incremental.py"
chmod +x "$WORKSPACE/scripts/scan_sessions_incremental.py"
cp -f "$SCRIPT_DIR/lockfile.py" "$WORKSPACE/scripts/lockfile.py"
chmod +x "$WORKSPACE/scripts/lockfile.py"
cp -f "$SCRIPT_DIR/weekly_gate.py" "$WORKSPACE/scripts/weekly_gate.py"
chmod +x "$WORKSPACE/scripts/weekly_gate.py"
cp -f "$SCRIPT_DIR/patch-openai-sse-empty-data.sh" "$WORKSPACE/scripts/patch-openai-sse-empty-data.sh"
chmod +x "$WORKSPACE/scripts/patch-openai-sse-empty-data.sh"
echo "  ✅ $WORKSPACE/scripts/scan_sessions_incremental.py"
echo "  ✅ $WORKSPACE/scripts/lockfile.py"
echo "  ✅ $WORKSPACE/scripts/weekly_gate.py"
echo "  ✅ $WORKSPACE/scripts/patch-openai-sse-empty-data.sh"
echo ""

# Step 4: 检查 openclaw.json 是否已有 memory 配置（安全：不自动修改）
echo "⚙️  Step 4: Checking memory config..."
if grep -q '"memory"' "$CONFIG" 2>/dev/null; then
  echo "  ⚠️  memory config already exists in $CONFIG"
  echo "  Please manually verify it matches the recommended config."
  echo "  See: examples/openclaw-memory-config.json"
else
  echo "  ⚠️  No memory config found. Please add the following to $CONFIG:"
  echo ""
  echo '  "memory": {'
  echo '    "backend": "qmd",'
  echo '    "citations": "auto",'
  echo '    "qmd": { ... }'
  echo '  }'
  echo ""
  echo "  See: examples/openclaw-memory-config.json for full config."
fi
echo ""

# Step 5: 添加 Cron Jobs（不依赖 sessions_list/sessions_history）
echo "⏰ Step 5: Adding cron jobs..."

CRON_COMMON_ARGS=(--session isolated --light-context --agent main)
DELIVERY_ARGS=(--announce)
if [[ -n "$NOTIFY_TO" ]]; then
  DELIVERY_ARGS+=(--channel "$NOTIFY_CHANNEL" --to "$NOTIFY_TO")
  if [[ -n "$NOTIFY_ACCOUNT" ]]; then
    DELIVERY_ARGS+=(--account "$NOTIFY_ACCOUNT")
  fi
  echo "  ✅ Explicit delivery: $NOTIFY_CHANNEL -> $NOTIFY_TO"
else
  echo "  ⚠️  No --notify-to provided; cron delivery will fall back to OpenClaw's last-route behavior."
fi
echo "  ✅ Isolated cron jobs will use --light-context to keep bootstrap context lean."

# 检查是否已存在
EXISTING=$(openclaw cron list --json 2>/dev/null | grep -c "memory-" || true)
if [ "$EXISTING" -gt 0 ]; then
  echo "  ⚠️  Found $EXISTING existing memory-* cron jobs."
  echo "  Skipping cron creation. Delete existing jobs first if you want to recreate."
else
  SCAN_SCRIPT="$WORKSPACE/scripts/scan_sessions_incremental.py"
  STATE_HOURLY="$WORKSPACE/memory/_state/scan_sessions_hourly.json"
  STATE_DAILY="$WORKSPACE/memory/_state/scan_sessions_daily.json"
  STATE_WEEKLY="$WORKSPACE/memory/_state/memory-weekly.json"
  MEMORY_LOCK="$WORKSPACE/memory/_state/MEMORY.lock"

  # Hourly
  openclaw cron add \
    --name "memory-hourly" \
    --cron "$HOURLY_CRON" \
    --tz "$TZ" \
    "${CRON_COMMON_ARGS[@]}" \
    "${DELIVERY_ARGS[@]}" \
    --model "$HOURLY_MODEL" \
    --timeout-seconds 300 \
    --message "[cron:memory-hourly] 你是记忆微同步 agent。禁止调用 sessions_list/sessions_history。请用 exec 运行增量扫描脚本获取新内容：python3 \"$SCAN_SCRIPT\" --state-file \"$STATE_HOURLY\" --format md --max-chars 4000。脚本输出已过滤 tool/system/cron/通知，仅保留 user + assistant 最终回复。若无新内容：回复 Telegram 通知，第一行必须是 memory-hourly ok；随后给出 stats（files_with_new_bytes/messages_emitted/truncated）；最多 3 条要点 bullet。若有新内容：将关键信号 append 到 memory/YYYY-MM-DD.md（按主题/时间，小而精的 bullet）；必要时更新 MEMORY.md（仅长期偏好/关键决策）；最后回复 Telegram 通知：第一行 memory-hourly ok，然后 stats，然后最多 3 条 bullet（本次新增最重要的记忆点）。规则：不要把工具输出写进记忆；不要把自己的通知写进记忆；不要总结任何以 memory- 开头的 ok 消息。" \
    > /dev/null 2>&1
  echo "  ✅ memory-hourly (L1: incremental scan + micro-sync)"

  # Daily
  openclaw cron add \
    --name "memory-daily" \
    --cron "30 23 * * *" \
    --tz "$TZ" \
    "${CRON_COMMON_ARGS[@]}" \
    "${DELIVERY_ARGS[@]}" \
    --model "$DAILY_MODEL" \
    --timeout-seconds 600 \
    --message "[cron:memory-daily] 你是每日记忆蒸馏 agent。禁止调用 sessions_list/sessions_history。请用 exec 运行增量扫描脚本获取自上次 daily 以来的新对话：python3 \"$SCAN_SCRIPT\" --state-file \"$STATE_DAILY\" --format md --max-chars 8000。脚本输出已过滤 tool/system/cron/通知，仅保留 user + assistant 最终回复。将今天的重要内容整理为结构化日志写入 memory/YYYY-MM-DD.md（固定写入/更新：## 23:30 日级记忆（自动），按主题：关键决策/结论、重要信息/偏好、待办/后续行动、待核对）。然后维护 MEMORY.md 的滚动区（## 近期重要更新（自动，滚动7天））：先 exec 运行 python3 \"$WORKSPACE/scripts/lockfile.py\" acquire --lock \"$MEMORY_LOCK\" --timeout 120 --stale-seconds 7200；更新滚动区（<=30条，最近7天，每次新增<=5条，必须是可复用的长期偏好/关键决策/关键配置/已验证修复；不确定标注待核对）；最后 exec 运行 python3 \"$WORKSPACE/scripts/lockfile.py\" release --lock \"$MEMORY_LOCK\"。将超过 7 天的 daily log 移到 memory/archive/YYYY/。最后发送 Telegram 通知：第一行 memory-daily ok；随后 stats；最多 5 条 bullet（今天最重要的新增记忆/决策）。规则：不要把工具输出写进记忆；不要把自己的通知写进记忆；不要总结任何以 memory- 开头的 ok 消息。" \
    > /dev/null 2>&1
  echo "  ✅ memory-daily  (L2: every night at 23:30)"

  # Weekly
  openclaw cron add \
    --name "memory-weekly" \
    --cron "20 0 * * *" \
    --tz "$TZ" \
    "${CRON_COMMON_ARGS[@]}" \
    "${DELIVERY_ARGS[@]}" \
    --model "$WEEKLY_MODEL" \
    --timeout-seconds 900 \
    --message "[cron:memory-weekly] 你是每周记忆巩固 agent。先用 exec 运行 weekly gate：python3 \"$WORKSPACE/scripts/weekly_gate.py\" --mode check --state \"$STATE_WEEKLY\" --timezone \"$TZ\"。若 shouldRun=false：直接回复 Telegram 通知 memory-weekly skipped（包含 weekKey/lastWeekKey）并退出。若 shouldRun=true：读取 suggestedLookbackDays=N（<=30），加载最近 N 天的 memory/YYYY-MM-DD.md + 当前 MEMORY.md；在写 MEMORY.md 前先获取锁：python3 \"$WORKSPACE/scripts/lockfile.py\" acquire --lock \"$MEMORY_LOCK\" --timeout 120 --stale-seconds 7200；执行分类治理（偏好/约束、关键配置、常见故障修复、项目状态等），对滚动区条目做交叉验证后晋升进正式分类并清理滚动区；保存并释放锁；写入 memory/weekly/YYYY-WXX.md；最后 exec 运行 python3 \"$WORKSPACE/scripts/weekly_gate.py\" --mode mark --state \"$STATE_WEEKLY\" --timezone \"$TZ\"；最后发送 Telegram 通知：第一行 memory-weekly ok；随后小 stats；最多 5 条 bullet（本周最重要的记忆点）。规则：不要把自己的通知写进记忆；不要总结任何以 memory- 开头的 ok 消息。" \
    > /dev/null 2>&1
  echo "  ✅ memory-weekly (L3: daily trigger at 00:20 + weekly gate)"
fi
echo ""

# Step 6: 验证
echo "✅ Step 6: Verification"
echo ""
openclaw cron list 2>/dev/null | grep "memory-" || echo "  (no memory cron jobs found)"
echo ""
echo "🎉 Setup complete!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚠️  关键步骤（必须完成，否则记忆系统无效）："
echo ""
echo "  1. 添加 memory 配置到 ~/.openclaw/openclaw.json"
echo "     → 复制 examples/openclaw-memory-config.json"
echo "     → 重点检查: retentionDays 必须为 30（不是 0！）"
echo "     → qmd 命令路径建议用 npm 版（预编译）: $(command -v qmd 2>/dev/null || echo '<PATH_TO_QMD>')"
echo "     → 如果你依赖 *.jsonl.reset.* 回扫，请同步检查 session.maintenance.resetArchiveRetention"
echo ""
echo "  2. 合并 AGENTS-memory-section.md 到你的 AGENTS.md"
echo ""
echo "  3. 配置通常会热加载（cron/hooks/session 等大多无需手动重启）"
echo "     → 若 memory backend 状态没有更新，再执行: openclaw gateway restart"
echo ""
echo "  4. 验证 OpenClaw 实际使用的 memory/QMD 状态"
echo "     → openclaw memory status --agent main --index"
echo "     → 这比裸 qmd status 更接近 OpenClaw 实际使用的 sidecar 索引"
echo ""
if [[ -n "$NOTIFY_TO" ]]; then
  echo "  5. 验证 Telegram cron 通知路由"
  echo "     → 当前显式投递目标: $NOTIFY_CHANNEL / $NOTIFY_TO"
else
  echo "  5. 如需稳定投递到 Telegram 群/话题，建议重装时补上:"
  echo "     → --notify-to '<TELEGRAM_CHAT_ID>:topic:<TOPIC_ID>'"
fi
echo ""
echo "详细文档: https://github.com/dztabel-happy/openclaw-memory-fusion"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
