# OpenClaw Memory Fusion

> 一套基于 OpenClaw 原生能力的「永不失忆」融合记忆方案：**不漏、去噪、防套娃、可运维、可升级**。

这套方案的核心理念是：

- **事实源**来自本地 session JSONL（而不是 `sessions_list/sessions_history`）
- **提炼**来自 LLM（但只喂干净、可控的高信号输入）
- **落盘**来自 Markdown（可审计、可迁移、可被 QMD 搜索）

说明：

- OpenClaw 近版本已经提供 **pre-compaction memory flush** 与可选的 **`session-memory` hook**
- 本仓库的定位不是替代官方 memory，而是在其上补强 **deterministic 提取**、**isolated cron 可见性** 与 **Telegram 可观测运维**


## 为什么需要这个？

OpenClaw 官方现在已经提供默认的 memory flush，并且可以用 hook 在 `/new` 前做补充快照；这些能力很好，也建议保留。

本方案聚焦的是另一层问题：

- `--session isolated` 的后台任务仍可能遇到 session 可见性与上下文膨胀问题
- 你可能希望**固定时刻**运行三段记忆整理，而不是把它们并入 heartbeat
- 你可能希望**每次任务结果都投递到 Telegram 群/话题**，形成可巡检的运营面板

因此这里保留 **三层 cron**，但尽量与官方 memory / QMD / config hot reload 的当前做法对齐。

## 参考与融合来源

| 来源 | 我们采纳/改良的点 |
|---|---|
| Calicastle 三层架构 | Hourly/Daily/Weekly 分层分频 |
| Linux.do 终极记忆系统 | 去噪、剪枝、MEMORY.md 软上限思路 |
| OpenClaw 官方 | QMD 后端（BM25+向量+reranking）与 sessions transcript 索引 |

链接（仅供阅读，不影响运行）：

- Calicastle: https://x.com/calicastle/status/2021229394724102229
- Linux.do: https://linux.do/t/topic/1621623
- OpenClaw Memory/QMD: https://docs.openclaw.ai/concepts/memory

## 你会得到什么（优势）

### 1) isolated cron 下也不会“看不到主会话”

很多实现依赖 `sessions_list(activeMinutes=...)`，但在 `--session isolated` 的 cron 中，工具可见性可能被限制为“当前 session tree”，造成漏读。

当前推荐同时给 cron job 开启 `--light-context`，避免后台任务把整套 bootstrap context 带满。

本方案把 **`~/.openclaw/agents/<agent>/sessions/`** 作为唯一事实来源：

- `*.jsonl`（活跃会话持续 append）
- `*.jsonl.reset.*`（`/new` 归档）

### 2) 增量游标按 byte offset：不丢不重

- 每个文件维护一个 **byte offset cursor**（写在 `memory/_state/*.json`）
- 只推进到最后一个完整换行（容忍半行 JSON）
- 同一会话文件后续 append 不会漏
- 断网/关机漏跑是可恢复的：下一次会把 gap 补齐

### 3) 防套娃（递归污染）是“硬约束”而不是靠运气

三道保险：

1. cron prompt 第一行统一以 `[cron:` 开头（例如 `[cron:memory-hourly] ...`）
2. 扫描器忽略 cron 会话（heuristic：该 session 的首条 user 消息以 `[cron:` 开头）
3. 扫描器忽略通知文本（`memory-<layer> ok` / `NO_REPLY`）以及 `tool/system` 噪声

验证方式：重复跑 hourly，最终应收敛到 `events: 0`。

### 4) 高信噪比输入：只喂“用户 + 助手最终回复”

扫描器只输出两类信息：

- ✅ `role=user`：用户意图、决策、约束、偏好、TODO
- ✅ `role=assistant`：最终结论/方案（跳过 tool-call 与工具回显）

### 5) 长期记忆更快可用：A′ 滚动 7 天

仅 weekly 才更新 `MEMORY.md` 会太慢；daily 直接写完整分类又会太吵。

本方案引入 A′：

- daily 维护 `MEMORY.md#近期重要更新（自动，滚动7天）`（少量、可搜索、<=30条）
- weekly 再把“已证实且长期有效”的内容晋升进正式分类，并清理滚动区

### 6) 可运维：锁 + 周级 gate + 通知面板

- **锁**：daily/weekly 写 `MEMORY.md` 前先拿锁（避免并发覆盖）
- **gate**：weekly 采用“每天触发 + 每周至少成功一次”的 gate（避免机器睡眠错过周任务）
- **通知面板**：cron 最终输出投递到 Telegram 通知群，统一 `events/updated/coverage` 格式，便于肉眼巡检

### 7) 可升级：主要是脚本与提示词

绝大多数逻辑在用户空间：`scripts/*` + cron message。

OpenClaw 升级风险低。对于少数上游 SDK 边界问题（例如 OpenAI Responses SSE 空 data），提供 **可重复执行补丁脚本**（可选）。

## 架构概览

```
L1 hourly (micro)  -> memory/YYYY-MM-DD.md  (碎片要点)
L2 daily  (canon)  -> memory/YYYY-MM-DD.md  (23:30 canonical)
                 \-> MEMORY.md (A′ rolling 7d)
L3 weekly (tidy)   -> MEMORY.md (分类治理 + 晋升 + 剪枝)
                  -> memory/weekly/YYYY-Www.md

Truth source (facts): ~/.openclaw/agents/<agent>/sessions/*.jsonl{,.reset.*}
State (cursors):      ~/.openclaw/workspace/memory/_state/*.json
```

## 三层 Cron 设计（当前推荐）

| 层级 | 名称 | 频率 | 目标 |
|---|---|---:|---|
| L1 | memory-hourly | 每天 5 次（7/11/15/19/23 点） | 微同步：有价值才落盘 |
| L2 | memory-daily | 每天 23:30 | 当天 canonical + A′ 滚动区 |
| L3 | memory-weekly | 每天 00:20（但 gate） | 每周至少一次巩固 + 分类治理 |

> weekly 的“本周”用 ISO week（周一开始）。详见 `scripts/weekly_gate.py`。

## 未来计划 / Roadmap

- `docs/roadmap.md` — L4 (knowledge organization + lookup governance)候选路线与触发条件

## Repo 内容

- `scripts/scan_sessions_incremental.py`：增量扫描器（byte offset cursors + 去噪 + 防套娃）
- `scripts/lockfile.py`：写 `MEMORY.md` 的简单锁
- `scripts/weekly_gate.py`：weekly gate（每天触发但每周只真正跑一次）
- `docs/cron-prompts.md`：三层 prompt 模板（最新版）
- `docs/design-decisions.md`：设计决策与权衡
- `docs/troubleshooting.md`：排障手册

## 快速开始

### 0) 前置条件

- 已安装 OpenClaw 并能运行 `openclaw`
- 安装 QMD
  - macOS 上继续使用 npm 版通常更省心：`npm install -g @tobilu/qmd`
  - 关键不是 bun / npm 之争，而是 **`memory.qmd.command` 指向的 `qmd` 在你的机器上稳定可用**

### 1) 配置 OpenClaw memory 使用 QMD（必做）

参考：`examples/openclaw-memory-config.json` 与 OpenClaw 官方文档。

关键点：

- `memory.qmd.sessions.retentionDays` 不要是 0（0 表示立即过期）
- 如果你依赖 `*.jsonl.reset.*` 回扫，请确认 `session.maintenance.resetArchiveRetention` 不短于你的 daily/weekly 回扫窗口
- OpenClaw 2026.3+ 会在自己的 sidecar/XDG home 中管理 QMD 索引；**不要再把裸 `qmd status` 视为唯一真相**

### 2) 验证 OpenClaw 实际使用的 memory/QMD 状态

```bash
openclaw memory status --agent main --index
```

如果你只是想确认 OpenClaw 这次会实际查哪个 index，这个命令比手动 `qmd collection add .` / `qmd status` 更靠谱。

如果你确实要手动预热 **同一个** QMD sidecar（例如首次下载模型、预先 embed），请复用 OpenClaw 的 XDG 目录：

```bash
STATE_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
export XDG_CONFIG_HOME="$STATE_DIR/agents/main/qmd/xdg-config"
export XDG_CACHE_HOME="$STATE_DIR/agents/main/qmd/xdg-cache"

qmd update
qmd embed
qmd query "test" -c memory-root --json >/dev/null 2>&1
```

### 3) 建议创建 Telegram “cron 通知群”（可选但强烈推荐）

- 把 cron 的 delivery 统一投递到一个群
- 主会话保持干净；通知群作为“运行面板”

注意：

- 群聊收消息门控由 `channels.telegram.groupPolicy/groupAllowFrom` 控制
- cron 输出投递目标由 cron job 的 `delivery.to` 控制（两者是不同维度）

配置字段请以官方文档为准（不同版本可能调整）：

- 参考：OpenClaw docs `gateway/configuration.md` 的 `groupPolicy` 段落

### 4) 一键安装脚本与 cron jobs

```bash
bash scripts/setup.sh \
  --tz Asia/Shanghai \
  --notify-channel telegram \
  --notify-to '<TELEGRAM_CHAT_ID>:topic:<TOPIC_ID>'
```

说明：

- 安装脚本会继续创建 **3 个 isolated cron jobs**
- 每个 job 默认带 `--light-context`，减少后台记忆任务的 bootstrap 上下文压力
- 如果不传 `--notify-to`，OpenClaw 会回落到 last-route announce；能跑，但不如显式指定群/话题稳定

## 可选：OpenAI Responses SSE 空 data 崩溃补丁

如果你遇到网关错误：

- `Unexpected end of JSON input`
- 且 `gateway.err.log` 同时出现 `event: response.created` 但 `data:` 为空的特征

可执行：

```bash
bash scripts/patch-openai-sse-empty-data.sh --restart
```

详见：`docs/troubleshooting.md`。
