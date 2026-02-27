#!/bin/bash
# OpenClaw Memory Fusion - 一键安装脚本
# 用法: bash setup.sh [--tz Asia/Shanghai] [--hourly-model google/gemini-3-flash-preview] [--daily-model openrouter/minimax/minimax-m2.5] [--weekly-model anyrouter/claude-opus-4-6]

set -e

# 默认值
TZ="${TZ:-Asia/Shanghai}"
HOURLY_MODEL="${HOURLY_MODEL:-google/gemini-3-flash-preview}"
DAILY_MODEL="${DAILY_MODEL:-openrouter/minimax/minimax-m2.5}"
WEEKLY_MODEL="${WEEKLY_MODEL:-anyrouter/claude-opus-4-6}"
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"

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
echo "Hourly model:  $HOURLY_MODEL"
echo "Daily model:   $DAILY_MODEL"
echo "Weekly model:  $WEEKLY_MODEL"
echo "Workspace:     $WORKSPACE"
echo ""

# Step 1: 检查并安装 QMD
echo "📦 Step 1: Checking QMD..."

# 优先检查 npm 安装的 qmd（预编译，开箱即用）
if [ -f "$HOME/.npm-global/bin/qmd" ]; then
  echo "  ✅ QMD found (npm): $HOME/.npm-global/bin/qmd"
  export PATH="$HOME/.npm-global/bin:$PATH"
elif command -v qmd &> /dev/null; then
  echo "  ⚠️  QMD found (system): $(which qmd)"
  echo "     注意: 推荐使用 npm 安装（预编译版本，bun 安装需额外构建步骤）"
else
  echo "  ⚠️  QMD not found."
  echo "  🔧 Installing via npm (推荐，预编译开箱即用)..."
  if ! command -v npm &> /dev/null; then
    echo "  ❌ npm not found. Please install Node.js first: https://nodejs.org"
    exit 1
  fi
  npm install -g @tobilu/qmd
  if [ -f "$HOME/.npm-global/bin/qmd" ]; then
    echo "  ✅ QMD installed via npm"
    export PATH="$HOME/.npm-global/bin:$PATH"
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

# Step 2: 创建目录结构
echo "📁 Step 2: Creating directory structure..."
mkdir -p "$WORKSPACE/memory/weekly"
mkdir -p "$WORKSPACE/memory/archive/$(date +%Y)"
echo "  ✅ $WORKSPACE/memory/weekly/"
echo "  ✅ $WORKSPACE/memory/archive/$(date +%Y)/"
echo ""

# Step 3: 检查 openclaw.json 是否已有 memory 配置
echo "⚙️  Step 3: Checking memory config..."
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

# Step 4: 添加 Cron Jobs
echo "⏰ Step 4: Adding cron jobs..."

# 检查是否已存在
EXISTING=$(openclaw cron list --json 2>/dev/null | grep -c "memory-" || true)
if [ "$EXISTING" -gt 0 ]; then
  echo "  ⚠️  Found $EXISTING existing memory-* cron jobs."
  echo "  Skipping cron creation. Delete existing jobs first if you want to recreate."
else
  # Hourly
  openclaw cron add \
    --name "memory-hourly" \
    --cron "0 10,13,16,19,22 * * *" \
    --tz "$TZ" \
    --session isolated \
    --agent main \
    --model "$HOURLY_MODEL" \
    --timeout-seconds 120 \
    --no-deliver \
    --message '你是记忆微同步 agent。检查最近是否有新的有价值内容。数据源：1.用 sessions_list 查看当前活跃 session；2.用 exec 扫描归档 session：ls -lt ~/.openclaw/agents/main/sessions/*.reset.* 2>/dev/null | head -10，筛选最近几小时内新归档的文件；3.对归档文件用 read 读取 jsonl 内容。处理规则：1.先读 memory/YYYY-MM-DD.md，解析第一行 <!-- processed: id1, id2 --> 获取已处理 session ID；2.跳过已处理的 session ID（文件名中 .jsonl 前的 UUID）；3.跳过无意义 session（<2条 role=user 消息）；4.无新内容回复 NO_REPLY；5.有新内容 append 到 memory/YYYY-MM-DD.md，格式：## HH:MM 简短标题 换行 - 要点；6.更新第一行 <!-- processed: ... --> 加入本次处理的 ID；7.完成后回复 NO_REPLY' \
    > /dev/null 2>&1
  echo "  ✅ memory-hourly (L1: every 3h during daytime)"

  # Daily
  openclaw cron add \
    --name "memory-daily" \
    --cron "0 23 * * *" \
    --tz "$TZ" \
    --session isolated \
    --agent main \
    --model "$DAILY_MODEL" \
    --timeout-seconds 300 \
    --no-deliver \
    --message '你是每日记忆蒸馏 agent。将今天所有对话蒸馏为结构化日志。数据源：1.用 sessions_list(activeMinutes=1440) 获取今天活跃 session；2.用 exec 扫描归档 session：ls -lt ~/.openclaw/agents/main/sessions/*.reset.* 2>/dev/null，筛选今天的归档文件；3.对活跃 session 用 sessions_history，对归档文件用 read 读取 jsonl；4.QMD 兜底：用 memory_search 搜索今天关键词。幂等性：1.读 memory/YYYY-MM-DD.md 第一行 <!-- processed: id1, id2 --> 获取已处理 ID；2.跳过已处理 session ID；3.处理完更新注释。蒸馏规则：1.跳过无意义 session（<2条 role=user 消息）；2.蒸馏为结构化格式写入 memory/YYYY-MM-DD.md（## 主题标题 换行 - 关键决策/结论 - 重要信息/偏好 - 待办/后续行动）；3.将超过 7 天的 daily log 移到 memory/archive/YYYY/；4.完成后回复 NO_REPLY' \
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
    --timeout-seconds 600 \
    --no-deliver \
    --message '你是每周记忆巩固 agent。聚合本周记忆，精简 MEMORY.md。步骤：1.读取本周所有 memory/YYYY-MM-DD.md 日志；2.读取当前 MEMORY.md；3.提取本周新的偏好、决策、项目状态、技术配置、人物关系、重要教训；4.更新 MEMORY.md：合并新信息到对应分类，剪枝过时/已失效信息，保持精简（软上限约200行），更新底部最后更新时间戳；5.将本周日志压缩摘要写入 memory/weekly/YYYY-WXX.md（XX=周数）；6.完成后回复 NO_REPLY' \
    > /dev/null 2>&1
  echo "  ✅ memory-weekly (L3: every Sunday at 22:00)"
fi
echo ""

# Step 5: 验证
echo "✅ Step 5: Verification"
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
echo "     → qmd 命令路径使用 npm 版（预编译）: $(which qmd 2>/dev/null || echo '/Users/abel/.npm-global/bin/qmd')"
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
