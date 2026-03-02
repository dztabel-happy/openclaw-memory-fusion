# Cron Prompts 详解（文件扫描 + 增量游标 + 防套娃 + A′ + gate）

本文档给出三层 cron job 的 prompt 设计原则与可直接使用的单行模板。

## 总原则（必须遵守）

1) **不要依赖 `sessions_list` / `sessions_history`**

在 `--session isolated` 的 cron 中，session 工具的可见性可能被限制为当前 session tree，导致漏读。

2) **唯一事实源：扫描会话文件**

扫描目录（默认）：`~/.openclaw/agents/main/sessions/`

- `*.jsonl`
- `*.jsonl.reset.*`

3) **增量游标：按文件 byte offset**

使用 `scripts/scan_sessions_incremental.py` 写状态文件（`memory/_state/*.json`）：

- 每个文件单独记录 offset
- 只推进到最后一个完整换行（避免半行 JSON）

4) **防套娃（递归污染）**

- cron prompt 第一行必须以 `[cron:` 开头
- 扫描器忽略 cron 会话 + 忽略 `memory-<layer> ok` / `NO_REPLY` + 忽略 tool/system

5) **只提取“有价值信号”**

- ✅ user 消息
- ✅ assistant 最终回复（非 tool-call）
- ❌ tool 输出 / system banner / cron 通知

6) **通知格式（推荐统一）**

cron 最终回复用于投递到通知群（运营面板），推荐固定格式：

- 第一行：`memory-<layer> ok` 或 `memory-<layer> skipped`
- 第二行：`events: N (user U / assistant A)`
- 第三行：`updated: <file#anchor|none>`
- 第四行：`coverage: pref|decision|config|incident|todo|verify|none`
- 后面最多 3~5 条 bullet

## Layer 1 — Hourly Micro-Sync

**目的**：轻量安全网。把“自上次 hourly 以来”的新增要点快速落盘。

模板：

```
[cron:memory-hourly] 你是记忆微同步 agent。禁止调用 sessions_list/sessions_history。请用 exec 运行增量扫描脚本获取新内容：python3 ~/.openclaw/workspace/scripts/scan_sessions_incremental.py --state-file ~/.openclaw/workspace/memory/_state/scan_sessions_hourly.json --format md --max-chars 4000。脚本输出已过滤 tool/system/cron/通知，仅保留 user + assistant 最终回复。若无新内容：回复通知，第一行必须是 memory-hourly ok；随后 stats；最多 3 条 bullet。若有新内容：将关键信号 append 到 memory/YYYY-MM-DD.md（按主题/时间，小而精的 bullet）；必要时更新 MEMORY.md（仅长期偏好/关键决策）；最后回复通知：memory-hourly ok + stats + bullets。规则：不要把工具输出写进记忆；不要把自己的通知写进记忆；不要总结任何以 memory- 开头的 ok 消息。
```

## Layer 2 — Daily Sync（canonical + A′）

**目的**：当天结构化日志 + 快速长期记忆（A′）。

要点：

- canonical 写入：`memory/YYYY-MM-DD.md#23:30 日级记忆（自动）`
- A′ 滚动区：`MEMORY.md#近期重要更新（自动，滚动7天）`
- 写 `MEMORY.md` 前先加锁：`scripts/lockfile.py`

模板：

```
[cron:memory-daily] 你是每日记忆蒸馏 agent。禁止调用 sessions_list/sessions_history。请用 exec 运行增量扫描脚本获取自上次 daily 以来的新对话：python3 ~/.openclaw/workspace/scripts/scan_sessions_incremental.py --state-file ~/.openclaw/workspace/memory/_state/scan_sessions_daily.json --format md --max-chars 8000。脚本输出已过滤 tool/system/cron/通知，仅保留 user + assistant 最终回复。将今天的重要内容整理为结构化日志写入 memory/YYYY-MM-DD.md（固定写入/更新：## 23:30 日级记忆（自动），按主题：关键决策/结论、重要信息/偏好、待办/后续行动、待核对）。然后维护 MEMORY.md 的滚动区（## 近期重要更新（自动，滚动7天））：先 exec 运行 python3 ~/.openclaw/workspace/scripts/lockfile.py acquire --lock ~/.openclaw/workspace/memory/_state/MEMORY.lock --timeout 120 --stale-seconds 7200；更新滚动区（<=30条，最近7天，每次新增<=5条，必须是可复用的长期偏好/关键决策/关键配置/已验证修复；不确定标注待核对）；最后 exec 运行 python3 ~/.openclaw/workspace/scripts/lockfile.py release --lock ~/.openclaw/workspace/memory/_state/MEMORY.lock。将超过 7 天的 daily log 移到 memory/archive/YYYY/。最后发送通知：memory-daily ok + stats + updated + coverage + bullets。规则：不要把工具输出写进记忆；不要把自己的通知写进记忆。
```

## Layer 3 — Weekly Tidy（gate + 晋升 + 分类治理）

**目的**：每周至少成功一次巩固，把 A′ 滚动区内容晋升到 `MEMORY.md` 正式分类并剪枝。

关键点：

- weekly cron 建议每天触发（例如 00:20），但用 gate 控制“本周只真正执行一次”。
- gate：`scripts/weekly_gate.py --mode check/mark`
- 写 `MEMORY.md` 前必须加锁（与 daily 共用锁）。

模板：

```
[cron:memory-weekly] 你是每周记忆巩固 agent。先用 exec 运行 weekly gate：python3 ~/.openclaw/workspace/scripts/weekly_gate.py --mode check --state ~/.openclaw/workspace/memory/_state/memory-weekly.json --timezone Asia/Shanghai。若 shouldRun=false：直接回复通知 memory-weekly skipped（包含 weekKey/lastWeekKey）并退出。若 shouldRun=true：读取 suggestedLookbackDays=N（<=30），加载最近 N 天的 memory/YYYY-MM-DD.md + 当前 MEMORY.md；在写 MEMORY.md 前先获取锁：python3 ~/.openclaw/workspace/scripts/lockfile.py acquire --lock ~/.openclaw/workspace/memory/_state/MEMORY.lock --timeout 120 --stale-seconds 7200；执行分类治理（偏好/约束、关键配置、常见故障修复、项目状态等），对滚动区条目做交叉验证后晋升进正式分类并清理滚动区；保存并释放锁；写入 memory/weekly/YYYY-Www.md；最后 exec 运行 python3 ~/.openclaw/workspace/scripts/weekly_gate.py --mode mark --state ~/.openclaw/workspace/memory/_state/memory-weekly.json --timezone Asia/Shanghai；最后发送通知：memory-weekly ok + stats + lookbackDays + coverage + bullets。规则：不要把自己的通知写进记忆。
```
