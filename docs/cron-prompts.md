# Cron Prompts 详解（2026-03-01 最新设计）

本文档解释三层 cron job 的 prompt 设计思路，并给出可直接使用的「单行 prompt」模板。

## 总原则（必须遵守）

1) **不要用 `sessions_list` / `sessions_history`**  
隔离（isolated）cron 运行时可能看不到主会话树，调用这两个工具会漏数据或直接失败。

2) **唯一数据源：扫描会话文件**  
扫描目录：`~/.openclaw/agents/main/sessions/` 下的：
- `*.jsonl`（活跃会话持续 append）
- `*.jsonl.reset.*`（`/new` 后归档的会话）

3) **增量游标：按文件字节偏移（byte offset）**  
使用 `scripts/scan_sessions_incremental.py` 维护状态文件（`memory/_state/*.json`）：
- 每个文件单独记录 offset
- **只推进到最后一个完整换行**（避免读到半行 JSON）
- 同一会话文件 append 新内容时不会漏；漏跑一晚上也会在下一次补上

4) **防止套娃（递归）**
- cron prompt 第一行必须以 `[cron:` 开头（例：`[cron:memory-hourly] ...`），扫描器会直接忽略整段 cron 会话
- 扫描器会忽略通知文本（`memory-<layer> ok` / `NO_REPLY`）与 `tool/system` 输出

5) **只提取“有价值信号”**
- ✅ `role=user` 的消息
- ✅ `role=assistant` 的最终回复（非 tool-call）
- ❌ tool 输出 / system banner / cron 通知

6) **Telegram 通知格式（统一）**
- 第一行固定：`memory-<layer> ok`
- 第二行：简短 stats（例如 `sessions=2 msgs=11 truncated=false`）
- 后面最多 3~5 条 bullet（最重要的新增记忆点/决策）

> 提示：`scripts/setup.sh` 会把扫描脚本复制到 `~/.openclaw/workspace/scripts/`，并创建默认的状态文件目录 `~/.openclaw/workspace/memory/_state/`。

## Layer 1: Hourly Micro-Sync

**目标**：轻量安全网。把“自上次 hourly 以来”新增的对话要点快速落盘到 `memory/YYYY-MM-DD.md`。

**推荐 prompt（单行，直接可用）**：

```
[cron:memory-hourly] 你是记忆微同步 agent。禁止调用 sessions_list/sessions_history。请用 exec 运行增量扫描脚本获取新内容：python3 ~/.openclaw/workspace/scripts/scan_sessions_incremental.py --state-file ~/.openclaw/workspace/memory/_state/scan_sessions_hourly.json --format md --max-chars 4000。脚本输出已过滤 tool/system/cron/通知，仅保留 user + assistant 最终回复。若无新内容：回复 Telegram 通知，第一行必须是 memory-hourly ok；随后给出 stats；最多 3 条 bullet。若有新内容：将关键信号 append 到 memory/YYYY-MM-DD.md（按主题/时间，小而精的 bullet）；必要时更新 MEMORY.md（仅长期偏好/关键决策）；最后回复 Telegram 通知：第一行 memory-hourly ok，然后 stats，然后最多 3 条 bullet（本次新增最重要的记忆点）。规则：不要把工具输出写进记忆；不要把自己的通知写进记忆；不要总结任何以 memory- 开头的 ok 消息。
```

**设计要点**：
- Hourly 的“幂等性”来自 `scan_sessions_hourly.json`（offset 游标），不再使用 session-id 列表或注释头
- 输出给 Telegram 的通知是“运营面板”，不是记忆正文（扫描器会自动忽略，避免套娃）

## Layer 2: Daily Sync

**目标**：结构化蒸馏。把“自上次 daily 以来”的新增对话整理成当天的结构化日志，并归档旧日志。

**推荐 prompt（单行，直接可用）**：

```
[cron:memory-daily] 你是每日记忆蒸馏 agent。禁止调用 sessions_list/sessions_history。请用 exec 运行增量扫描脚本获取自上次 daily 以来的新对话：python3 ~/.openclaw/workspace/scripts/scan_sessions_incremental.py --state-file ~/.openclaw/workspace/memory/_state/scan_sessions_daily.json --format md --max-chars 8000。脚本输出已过滤 tool/system/cron/通知，仅保留 user + assistant 最终回复。将今天的重要内容整理为结构化日志写入 memory/YYYY-MM-DD.md（按主题：关键决策/结论、重要信息/偏好、待办/后续行动）。将超过 7 天的 daily log 移到 memory/archive/YYYY/。最后发送 Telegram 通知：第一行 memory-daily ok；随后 stats；最多 5 条 bullet（今天最重要的新增记忆/决策）。规则：不要把工具输出写进记忆；不要把自己的通知写进记忆；不要总结任何以 memory- 开头的 ok 消息。
```

**设计要点**：
- Daily 的扫描游标与 Hourly 分离（各自维护 `scan_sessions_daily.json`），避免互相抢游标导致漏读
- Daily 更适合“结构化整理”，细节不必全部塞进 `MEMORY.md`（细节靠 QMD 召回）

## Layer 3: Weekly Tidy

**目标**：长期记忆巩固。聚合本周 daily logs，剪枝并更新 `MEMORY.md`，写周摘要。

**推荐 prompt（单行，直接可用）**：

```
[cron:memory-weekly] 你是每周记忆巩固 agent。聚合本周记忆，精简 MEMORY.md。步骤：1) 读取本周所有 memory/YYYY-MM-DD.md 日志；2) 读取当前 MEMORY.md；3) 提取本周新的偏好、决策、项目状态、技术配置、人物关系、重要教训；4) 更新 MEMORY.md：合并新信息到对应分类，剪枝过时/已失效信息，保持精简（软上限约200行），更新最后更新时间；5) 将本周压缩摘要写入 memory/weekly/YYYY-WXX.md（XX=周数）；6) 最后发送 Telegram 通知：第一行 memory-weekly ok；随后小 stats；最多 5 条 bullet（本周最重要的记忆点）。规则：不要把自己的通知写进记忆；不要总结任何以 memory- 开头的 ok 消息。
```

**设计要点**：
- Weekly 不扫描 session 文件：只消费已经落盘的 daily logs + MEMORY.md
- “剪枝”是关键：让 MEMORY.md 保持可读、可加载、可维护

## 模型选择

> 💡 **实践经验**：三个 cron job 建议统一使用与主力模型相同的模型。
>
> 之前尝试 hourly 用便宜模型（gemini-flash），但不够稳定。统一用主力模型反而更省心——hourly 大多数时候"无事退出"消耗极少，真正有事时需要足够的理解能力。

## 自定义 Prompt 建议

你可以根据自己的需求调整 prompt：

### 添加特定领域关注点

在 prompt 末尾追加：
```
特别关注：代码架构决策、用户反馈、Bug 修复记录
```

### 调整信号过滤阈值

```
跳过无意义 session（<3条 role=user 消息）
```

### 修改 Cron Prompt

```bash
# 查看现有 job
openclaw cron list

# 用 job ID 修改 message
openclaw cron edit <job-id> --message '新的 prompt 内容'

# 手动触发测试
openclaw cron run <job-id>
```
