# 故障排除

## QMD 相关

### QMD 安装失败（bun build 报错）

QMD 用 TypeScript 编写，不需要 `tsc` 编译。直接用 `bun` 运行源码：

```bash
# 不要用 bun run build，直接创建 wrapper
cat > ~/.bun/bin/qmd << 'EOF'
#!/bin/bash
exec bun ~/.bun/install/global/node_modules/@tobilu/qmd/src/qmd.ts "$@"
EOF
chmod +x ~/.bun/bin/qmd
```

### QMD 命令找不到

确保 `~/.bun/bin` 在 PATH 中：

```bash
echo 'export PATH="$HOME/.bun/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### memory_search 返回空结果

#### 原因 1：QMD 从未建索引

OpenClaw 配置了 `includeDefaultMemory: true`，但**不会自动创建 QMD collection**。需要手动初始化：

```bash
cd ~/.openclaw/workspace

# 1. 创建 collection（索引所有 md 文件）
qmd collection add .

# 2. 生成向量嵌入（可选，BM25 搜索已可用）
qmd embed

# 3. 验证
qmd status
# 应显示: Total: N files indexed, Vectors: M embedded
```

#### 原因 2：向量 embed 失败（Bun SQLite 限制）

**问题**：Bun 内置 SQLite 不支持 `loadExtension`，导致 sqlite-vec 扩展无法加载。

**表现**：`qmd embed` 报错 "sqlite-vec is not available. Vector operations require a SQLite build with extension loading support."

**解决**：使用 npm 版的 qmd（Node.js + better-sqlite3）：

```bash
# 安装 npm 版 qmd
npm install -g @tobilu/qmd

# 修改 openclaw.json 配置
# 将 "command" 指向 qmd 可执行文件路径（用 which qmd 获取），例如：
"command": "<PATH_TO_QMD>"

# 重启 gateway
openclaw gateway restart
```

#### 原因 3：session transcripts 未被索引

检查 `retentionDays` 配置：

```bash
# 检查当前值
grep retentionDays ~/.openclaw/openclaw.json

# 如果是 0，改为 30（保留 30 天）
# "memory": { "qmd": { "sessions": { "retentionDays": 30 } } }
```

**注意**：`0` 表示"立即过期"，不是"永不过期"。

## Cron 相关

### Cron job 没有执行

```bash
# 检查 job 状态
openclaw cron list

# 查看运行历史
openclaw cron runs --id <job-id>

# 手动触发测试
openclaw cron run <job-id>
```

### Cron job 执行但没写入文件

常见原因：
- cron prompt 仍在用旧方案（`sessions_list` / `sessions_history`），隔离 cron 下可能看不到主会话树 → 直接漏数据
- 模型没有正确调用文件工具（`read`/`write`/`edit` 等）
- 扫描器 state 被重置（导致重复/漏读；见下）

建议排查：
1) 手动运行看输出：`openclaw cron run <job-id>`
2) 确认 prompt 使用最新模板（见 `docs/cron-prompts.md`），且第一行以 `[cron:` 开头（防套娃）
3) 观察 `~/.openclaw/workspace/memory/_state/scan_sessions_*.json` 是否持续更新（mtime/offset 变化）

### Cron 表达式速查

OpenClaw 使用标准 5-field cron 表达式：

```
分钟 小时 日 月 星期
0    23   *  *  *      = 每天 23:00
0    22   *  *  0      = 每周日 22:00
0    7,11,15,19,23 * * * = 每天 7/11/15/19/23 点
```

### 扫描脚本常见问题

#### 1) sessions dir not found

`scan_sessions_incremental.py` 默认扫描：`~/.openclaw/agents/main/sessions/`。  
如果你的 agent 名称不是 `main`，在 cron prompt 中显式传参：

```bash
python3 ~/.openclaw/workspace/scripts/scan_sessions_incremental.py \
  --openclaw-dir ~/.openclaw \
  --agent <YOUR_AGENT_NAME> \
  --state-file ~/.openclaw/workspace/memory/_state/scan_sessions_hourly.json \
  --format md
```

#### 2) state 文件被删/损坏导致重复写入

扫描器用 `memory/_state/scan_sessions_*.json` 记录每个 session 文件的 byte offset。  
如果你删除了 state 文件，下一次扫描会从头读取，**可能导致重复写入记忆**。

建议：
- 如果只是想“从现在开始重新记”，删除 state 后在记忆文件中手动加一条分界线，避免混淆
- 如果想“彻底重跑一天/一周”，建议先写到新文件（例如 `memory/rebuild-YYYY-MM-DD.md`），验证后再合并

## Gateway 相关

### 配置文件格式错误

```bash
# 检查配置
openclaw doctor

# 自动修复
openclaw doctor --fix
```

### gateway restart 超时

这是正常的——restart 命令有时会超时断开，但 gateway 实际已重启：

```bash
# 验证 gateway 状态
openclaw gateway status
```

## 记忆文件相关

### memory/YYYY-MM-DD.md 命名不一致

之前可能有带时间戳的文件（如 `2026-02-22-1418.md`），这是 session-memory hook 生成的。可以手动整理：

```bash
# 查看现有文件
ls ~/.openclaw/workspace/memory/

# 考虑关闭 session-memory hook 避免冲突
# 在 openclaw.json 的 hooks.internal.entries 中：
# "session-memory": { "enabled": false }
```

### MEMORY.md 超过 200 行

这是软上限，不会出错。但建议：

1. 等周日 weekly cron 自动剪枝
2. 或手动精简：移除过时信息，合并重复项
3. 细节内容靠 QMD 语义搜索召回，不需要全放 MEMORY.md

### Cron job 报 "LLM request timed out"

**问题**：cron job 执行报超时，但模型和 timeout 配置跟其他正常运行的 job 相同。

**排查步骤**：

```bash
# 查看详细错误
openclaw cron list --json | python3 -c "
import sys,json
data=json.load(sys.stdin)
for j in data.get('jobs',[]):
    s = j.get('state',{})
    if s.get('lastRunStatus') == 'error':
        print(f\"{j['name']}: {s.get('lastError')}\")"
```

**常见根因（新方案）**

- 扫描输出过大（一天对话太多）→ 模型总结超时
- 提示词没有约束“只写小而精的要点”→ 记忆写入过长

**修复建议**

1) 让输出可控（分段处理）  
在 prompt 中对扫描脚本加限制（比如 `--max-messages`），让下一次 cron 继续补跑：

```bash
python3 ~/.openclaw/workspace/scripts/scan_sessions_incremental.py \
  --state-file ~/.openclaw/workspace/memory/_state/scan_sessions_daily.json \
  --format md \
  --max-chars 8000 \
  --max-messages 200
```

2) 提高 timeout 或提高运行频率（尤其是 daily）  
例如把 daily 拆成每 6 小时一次（仍使用增量 state，不会重复）。

**验证**：

```bash
openclaw cron list --json | python3 -c "
import sys,json
data=json.load(sys.stdin)
for j in data.get('jobs',[]):
    if j['name'] == 'memory-hourly':
        s = j.get('state',{})
        print(f\"status: {s.get('lastRunStatus')}\")
        print(f\"consecutiveErrors: {s.get('consecutiveErrors')}\")"
```

## Telegram 通知相关

### Cron 通知没有发到群里 / 发错群

要点：**cron 的输出投递目标是在 cron job 的 `delivery.to` 里配置的**，不是在 Telegram 的 group allowlist 里配置的。

排查/配置步骤：

1) 确认机器人已在群里（建议给管理员权限，避免权限问题）。
2) 拿到群 `chat_id`（通常是 `-100...` 或负数）。
3) 把 cron 投递目标切到群：

```bash
openclaw cron edit <memory-hourly-id> --channel telegram --to <GROUP_CHAT_ID> --announce --best-effort-deliver
openclaw cron edit <memory-daily-id>  --channel telegram --to <GROUP_CHAT_ID> --announce --best-effort-deliver
openclaw cron edit <memory-weekly-id> --channel telegram --to <GROUP_CHAT_ID> --announce --best-effort-deliver
```

> 注意：不要把真实 chat_id 提交到任何仓库；用占位符即可。

### 机器人在群里不响应 @ / 群消息被忽略

这通常是 **OpenClaw 的群消息门控**导致的（只影响“接收/响应群消息”，不影响“往群里发通知”）。

如果你配置了：

- `channels.telegram.groupPolicy: "allowlist"`

那你还需要在 `openclaw.json` 里显式允许群与触发者（示例结构，字段以官方文档为准）：

```json5
{
  "channels": {
    "telegram": {
      "groupPolicy": "allowlist",
      "groupAllowFrom": ["<YOUR_TELEGRAM_USER_ID>"]
      ,
      "groups": {
        "<GROUP_CHAT_ID>": {
          "enabled": true,
          "requireMention": true
        }
      }
    }
  }
}
```

## OpenAI Responses 流式崩溃（SSE 空 data）

### 症状

使用 OpenAI Responses 的 streaming（`text/event-stream` / SSE）时，偶发出现某些 event 的 `data:` 为空字符串，导致 OpenAI Node SDK 内部 `JSON.parse("")` 报错 `Unexpected end of JSON input`，从而让 cron/普通任务直接失败。

### 判定特征

在 `~/.openclaw/logs/gateway.err.log` 同时出现：

- `Could not parse message into JSON:`（后面是空）
- `From chunk: [ 'event: response.created' ]`
- 以及 run end: `Unexpected end of JSON input`

### 修复

使用本仓库提供的补丁脚本，对 **OpenClaw 自带依赖**里的 `openai/core/streaming.js` 打补丁（遇到空 `sse.data` 直接跳过）：

```bash
# 在这个仓库里执行
bash scripts/patch-openai-sse-empty-data.sh --restart

# 或者只打补丁不重启
bash scripts/patch-openai-sse-empty-data.sh
```

如需手动指定 OpenClaw 安装目录：

```bash
OPENCLAW_ROOT="$(npm root -g)/openclaw" bash scripts/patch-openai-sse-empty-data.sh --restart
```

### 注意

- 这是对 vendor 代码打补丁：升级 OpenClaw / 依赖后可能被覆盖，需要重新执行脚本
