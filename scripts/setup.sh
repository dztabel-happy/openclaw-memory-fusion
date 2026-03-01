#!/bin/bash
# OpenClaw Memory Fusion - setup script
# Usage:
#   bash scripts/setup.sh \
#     [--tz Asia/Shanghai] \
#     [--hourly-model google/gemini-3-flash-preview] \
#     [--daily-model openrouter/minimax/minimax-m2.5] \
#     [--weekly-model anyrouter/claude-opus-4-6] \
#     [--workspace ~/.openclaw/workspace]

set -euo pipefail

# 默认值
TZ="${TZ:-Asia/Shanghai}"
HOURLY_MODEL="${HOURLY_MODEL:-google/gemini-3-flash-preview}"
DAILY_MODEL="${DAILY_MODEL:-openrouter/minimax/minimax-m2.5}"
WEEKLY_MODEL="${WEEKLY_MODEL:-anyrouter/claude-opus-4-6}"
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"
HOURLY_CRON="${HOURLY_CRON:-0 7,11,15,19,23 * * *}"

# 解析参数
while [[ $# -gt 0 ]]; do
  case $1 in
    --tz) TZ="$2"; shift 2 ;;
    --hourly-model) HOURLY_MODEL="$2"; shift 2 ;;
    --daily-model) DAILY_MODEL="$2"; shift 2 ;;
    --weekly-model) WEEKLY_MODEL="$2"; shift 2 ;;
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

# Step 1.5: 初始化 QMD 索引（关键步骤）
echo "🔍 Step 1.5: Initializing QMD index..."
cd "$WORKSPACE"
if qmd status 2>/dev/null | grep -q "0 files indexed"; then
  echo "  📂 Creating collection..."
  qmd collection add . 2>/dev/null || true
  echo "  🔢 Generating embeddings (可选，需几秒钟)..."
  qmd embed 2>/dev/null || echo "     ⚠️  embed 失败，继续... (BM25 搜索仍可用)"
else
  echo "  ✅ QMD index already exists"
fi
QMD_STATUS=$(qmd status 2>/dev/null)
FILES=$(echo "$QMD_STATUS" | grep "Total:" | awk '{print $2}')
VECS=$(echo "$QMD_STATUS" | grep "Vectors:" | awk '{print $2}')
echo "     索引状态: $FILES files, $VECS vectors"
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
cp -f "$SCRIPT_DIR/patch-openai-sse-empty-data.sh" "$WORKSPACE/scripts/patch-openai-sse-empty-data.sh"
chmod +x "$WORKSPACE/scripts/patch-openai-sse-empty-data.sh"
echo "  ✅ $WORKSPACE/scripts/scan_sessions_incremental.py"
echo "  ✅ $WORKSPACE/scripts/patch-openai-sse-empty-data.sh"
echo ""

# Step 4: 检查 openclaw.json 是否已有 memory 配置（安全：不自动修改）
echo "⚙️  Step 4: Checking memory config..."
CONFIG="$HOME/.openclaw/openclaw.json"
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

# 检查是否已存在
EXISTING=$(openclaw cron list --json 2>/dev/null | grep -c "memory-" || true)
if [ "$EXISTING" -gt 0 ]; then
  echo "  ⚠️  Found $EXISTING existing memory-* cron jobs."
  echo "  Skipping cron creation. Delete existing jobs first if you want to recreate."
else
  SCAN_SCRIPT="$WORKSPACE/scripts/scan_sessions_incremental.py"
  STATE_HOURLY="$WORKSPACE/memory/_state/scan_sessions_hourly.json"
  STATE_DAILY="$WORKSPACE/memory/_state/scan_sessions_daily.json"

  # Hourly
  openclaw cron add \
    --name "memory-hourly" \
    --cron "$HOURLY_CRON" \
    --tz "$TZ" \
    --session isolated \
    --agent main \
    --model "$HOURLY_MODEL" \
    --timeout-seconds 300 \
    --message "[cron:memory-hourly] 你是记忆微同步 agent。禁止调用 sessions_list/sessions_history。请用 exec 运行增量扫描脚本获取新内容：python3 \"$SCAN_SCRIPT\" --state-file \"$STATE_HOURLY\" --format md --max-chars 4000。脚本输出已过滤 tool/system/cron/通知，仅保留 user + assistant 最终回复。若无新内容：回复 Telegram 通知，第一行必须是 memory-hourly ok；随后给出 stats（files_with_new_bytes/messages_emitted/truncated）；最多 3 条要点 bullet。若有新内容：将关键信号 append 到 memory/YYYY-MM-DD.md（按主题/时间，小而精的 bullet）；必要时更新 MEMORY.md（仅长期偏好/关键决策）；最后回复 Telegram 通知：第一行 memory-hourly ok，然后 stats，然后最多 3 条 bullet（本次新增最重要的记忆点）。规则：不要把工具输出写进记忆；不要把自己的通知写进记忆；不要总结任何以 memory- 开头的 ok 消息。" \
    > /dev/null 2>&1
  echo "  ✅ memory-hourly (L1: incremental scan + micro-sync)"

  # Daily
  openclaw cron add \
    --name "memory-daily" \
    --cron "0 23 * * *" \
    --tz "$TZ" \
    --session isolated \
    --agent main \
    --model "$DAILY_MODEL" \
    --timeout-seconds 600 \
    --message "[cron:memory-daily] 你是每日记忆蒸馏 agent。禁止调用 sessions_list/sessions_history。请用 exec 运行增量扫描脚本获取自上次 daily 以来的新对话：python3 \"$SCAN_SCRIPT\" --state-file \"$STATE_DAILY\" --format md --max-chars 8000。脚本输出已过滤 tool/system/cron/通知，仅保留 user + assistant 最终回复。将今天的重要内容整理为结构化日志写入 memory/YYYY-MM-DD.md（按主题：关键决策/结论、重要信息/偏好、待办/后续行动）。将超过 7 天的 daily log 移到 memory/archive/YYYY/。最后发送 Telegram 通知：第一行 memory-daily ok；随后 stats（新增消息数、写入条目数、归档文件数等）；最多 5 条 bullet（今天最重要的新增记忆/决策）。规则：不要把工具输出写进记忆；不要把自己的通知写进记忆；不要总结任何以 memory- 开头的 ok 消息。" \
    > /dev/null 2>&1
  echo "  ✅ memory-daily  (L2: every night at 23:00)"

  # Weekly
  openclaw cron add \
    --name "memory-weekly" \
    --cron "0 22 * * 0" \
    --tz "$TZ" \
    --session isolated \
    --agent main \
    --model "$WEEKLY_MODEL" \
    --timeout-seconds 900 \
    --message "[cron:memory-weekly] 你是每周记忆巩固 agent。聚合本周记忆，精简 MEMORY.md。步骤：1) 读取本周所有 memory/YYYY-MM-DD.md 日志；2) 读取当前 MEMORY.md；3) 提取本周新的偏好、决策、项目状态、技术配置、人物关系、重要教训；4) 更新 MEMORY.md：合并新信息到对应分类，剪枝过时/已失效信息，保持精简（软上限约200行），更新最后更新时间；5) 将本周压缩摘要写入 memory/weekly/YYYY-WXX.md（XX=周数）；6) 最后发送 Telegram 通知：第一行 memory-weekly ok；随后小 stats（本周新增条目数、MEMORY.md 行数变化等）；最多 5 条 bullet（本周最重要的记忆点）。规则：不要把自己的通知写进记忆；不要总结任何以 memory- 开头的 ok 消息。" \
    > /dev/null 2>&1
  echo "  ✅ memory-weekly (L3: every Sunday at 22:00)"
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
echo ""
echo "  2. 合并 AGENTS-memory-section.md 到你的 AGENTS.md"
echo ""
echo "  3. 重启 gateway 使配置生效"
echo "     → openclaw gateway restart"
echo ""
echo "  4. 验证 QMD 索引正常"
echo "     → qmd status"
echo "     → 应显示: Total: N files indexed, Vectors: M embedded"
echo ""
echo "详细文档: https://github.com/dztabel-happy/openclaw-memory-fusion"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
