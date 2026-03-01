# OpenClaw Memory Fusion

> 一套基于 OpenClaw 原生能力的「永不失忆」融合记忆方案，零插件、零额外依赖、无侵入升级。

## 为什么需要这个？

OpenClaw 官方记忆系统有一个核心短板：**记忆写入完全依赖模型自觉**。聪明的模型会主动写记忆，但大多数模型不会——这意味着重要对话内容可能在 session compaction 后彻底丢失。

本方案通过 **3 个定时 cron job** 实现系统级自动记忆提取，融合了社区多个优秀方案的精华：

| 来源 | 采纳的设计 |
|---|---|
| [Calicastle 三层架构](https://x.com/calicastle/status/2021229394724102229) | 三层分频设计（Hourly / Daily / Weekly） |
| [Linux.do 终极记忆系统](https://linux.do/t/topic/1621623) | Session-ID 幂等、信号过滤、MEMORY.md 软上限 |
| OpenClaw 官方 | QMD 后端（BM25 + 向量 + reranking）、session transcript 索引 |

## 架构概览

```
┌──────────────────────────────────────────────────────┐
│                   OpenClaw Gateway                    │
│                                                      │
│  ┌─────────┐  ┌─────────┐  ┌──────────┐            │
│  │ Hourly  │  │  Daily  │  │  Weekly  │  ← Cron    │
│  │ Micro   │  │  Sync   │  │  Tidy   │  Jobs      │
│  │ Sync    │  │         │  │         │            │
│  └────┬────┘  └────┬────┘  └────┬─────┘            │
│       │            │            │                    │
│       ▼            ▼            ▼                    │
│  ┌─────────────────────────────────────┐            │
│  │         Markdown 文件系统            │            │
│  │                                     │            │
│  │  MEMORY.md          (长期·精华)     │            │
│  │  memory/YYYY-MM-DD.md (每日·原始)   │            │
│  │  memory/weekly/      (周·压缩)      │            │
│  │  memory/archive/     (归档·历史)    │            │
│  └──────────────┬──────────────────────┘            │
│                 │                                    │
│                 ▼                                    │
│  ┌─────────────────────────────────────┐            │
│  │    QMD 搜索引擎 (Sidecar)           │            │
│  │    BM25 + Vector + Reranking        │            │
│  │    + Session Transcript 索引        │            │
│  └─────────────────────────────────────┘            │
└──────────────────────────────────────────────────────┘
```

## 三层 Cron 设计

| 层级 | 名称 | 频率 | 模型 | 职责 |
|---|---|---|---|---|
| L1 | Hourly Micro-Sync | 每天 5 次（7/11/15/19/23 点） | 与主模型相同 | 轻量检查新活动，有则 append，无事退出 |
| L2 | Daily Sync | 每晚 23 点 | 与主模型相同 | 蒸馏全天 session 为结构化日志，归档旧文件 |
| L3 | Weekly Tidy | 每周日 22 点 | 与主模型相同 | 聚合本周，精简 MEMORY.md，写周摘要 |

### 为什么分三层？

- **Hourly** 是安全网：如果 daily 因断网/故障没跑，hourly 已经 append 了关键内容
- **Daily** 做结构化：把零散的 hourly notes 和原始对话整理成可读日志
- **Weekly** 做精炼：避免 MEMORY.md 无限膨胀，定期剪枝过时信息

## 关键设计决策（2026-03-01）

### 1. Cron 不依赖 `sessions_list` / `sessions_history`

隔离（isolated）cron 运行时可能看不到主会话树，用 `sessions_list` / `sessions_history` 会漏数据或直接失败。  
因此本方案把**会话文件**作为唯一事实来源（source of truth）。

### 2. 增量游标：按文件 byte offset 扫描（不丢不重）

扫描目录：`~/.openclaw/agents/main/sessions/` 下的：
- `*.jsonl`（活跃会话持续 append）
- `*.jsonl.reset.*`（`/new` 后归档会话）

通过 `scripts/scan_sessions_incremental.py` 维护状态文件（`memory/_state/scan_sessions_*.json`）：
- 每个文件单独记录 offset（byte offset）
- **只推进到最后一个完整换行**，容忍最后一行半写（避免 JSON 半行）
- 同一会话 append 新内容不会漏；漏跑一晚上也会在下一次补上

### 3. 防套娃（递归污染）

cron 会话本身也会写入 sessions 目录，如果不处理会被下一轮当成“新对话”再次总结。

新设计的保险：
- cron prompt 第一行以 `[cron:` 开头（例如 `[cron:memory-hourly] ...`）
- 扫描器忽略 cron 会话（heuristic：首条 user 消息以 `[cron:` 开头）
- 扫描器忽略通知文本（`memory-<layer> ok` / `NO_REPLY`）与 `tool/system` 输出

### 4. 只保留有价值信号（不记工具噪音）

记忆提取只消费两类内容：
- ✅ 用户消息（`role=user`）
- ✅ 助手最终回复（`role=assistant` 的非 tool-call 消息）

### 5. Telegram 群通知（运营面板）

cron 的最终回复用于投递到一个专用 Telegram 群，统一格式：
- 第一行：`memory-<layer> ok`
- 第二行：小 stats（sessions/messages/truncated 等）
- 后面：少量 bullet（最重要新增记忆点）

### 6. 分层存储（含状态文件）

```
workspace/
├── MEMORY.md                    # 长期精华（软上限 ~200 行）
├── memory/
│   ├── YYYY-MM-DD.md           # 每日日志（结构化）
│   ├── _state/                 # 扫描游标（增量 offset）
│   │   ├── scan_sessions_hourly.json
│   │   └── scan_sessions_daily.json
│   ├── weekly/
│   └── archive/YYYY/
└── scripts/
    ├── scan_sessions_incremental.py
    └── patch-openai-sse-empty-data.sh
```

### 7. `/new` 与断网容错

- `/new` 不会丢数据：旧会话会重命名为 `*.jsonl.reset.*`，仍会被扫描器覆盖
- 断网/关机漏跑是可恢复的：游标按 offset 前进，下次会补上 gap

## 快速开始

### 前置条件

- [OpenClaw](https://github.com/openclaw/openclaw) 已安装并运行
- [QMD](https://github.com/tobi/qmd) 已安装（`npm install -g @tobilu/qmd`，推荐 npm 版）
- 至少一个可用的 LLM provider

### 1. 安装 QMD

> ⚠️ **推荐使用 npm 安装**。虽然 QMD 源码已做了跨运行时兼容（bun 下用 `bun:sqlite`，Node.js 下用 `better-sqlite3`，两者都支持 sqlite-vec 扩展），但 `bun install -g` 从 git 安装时拿到的是**未编译的 TypeScript 源码**（没有 `dist/` 目录），需要手动构建才能运行。而 npm registry 的包是**预编译好的**，开箱即用。
>
> 此外，macOS 自带的 SQLite 不支持扩展加载，bun 环境下需额外配置 `Database.setCustomSQLite()` 指向 Homebrew 安装的 SQLite，增加了复杂度。

```bash
# 推荐：使用 npm 安装（预编译，开箱即用）
npm install -g @tobilu/qmd

# 验证
qmd --help
```

如果必须用 bun（需要额外构建步骤）：

```bash
# 安装源码
bun install -g https://github.com/tobi/qmd

# ⚠️ bun 全局安装的是 TypeScript 源码，需要创建 wrapper 用 bun 直接执行 .ts
cat > ~/.bun/bin/qmd << 'EOF'
#!/bin/bash
exec bun ~/.bun/install/global/node_modules/@tobilu/qmd/src/qmd.ts "$@"
EOF
chmod +x ~/.bun/bin/qmd

# macOS 用户还需要安装 Homebrew SQLite 以支持扩展加载
brew install sqlite

# 验证
qmd --help
```

### 2. 初始化 QMD 索引（必做）

> ⚠️ **关键步骤**：OpenClaw 配置 `includeDefaultMemory: true` 不会自动创建 QMD collection，必须手动初始化。

```bash
cd ~/.openclaw/workspace

# 创建 collection（索引所有 md 文件）
qmd collection add .

# 生成向量嵌入（可选，BM25 搜索已可用）
qmd embed

# 验证
qmd status
# 应显示: Total: N files indexed, Vectors: M embedded
```

### 3. 配置 QMD 后端

在 `~/.openclaw/openclaw.json` 中添加 `memory` 配置：

```json5
{
  // ... 其他配置 ...
  "memory": {
    "backend": "qmd",
    "citations": "auto",
    "qmd": {
      "command": "<PATH_TO_QMD>",                   // 例如：which qmd 的输出路径
      "includeDefaultMemory": true,
      "searchMode": "search",
      "update": {
        "interval": "5m",
        "debounceMs": 15000,
        "onBoot": true,
        "waitForBootSync": false
      },
      "limits": {
        "maxResults": 8,
        "timeoutMs": 5000
      },
      "sessions": {
        "enabled": true,                   // 索引 session 对话记录
        "retentionDays": 30                // ⚠️ 重要：保留 30 天，0 会立即过期
      },
      "scope": {
        "default": "deny",
        "rules": [
          { "action": "allow", "match": { "chatType": "direct" } }
        ]
      }
    }
  }
}
```

### 3.1 配置 Telegram 群 allowlist（推荐）

如果你希望 cron 的通知投递到一个专用 Telegram 群，建议开启 allowlist 并限制来源（避免群聊被其它 agent/任务刷屏）：

```json5
{
  "channels": {
    "telegram": {
      "groupPolicy": "allowlist",
      "groups": [
        { "chatId": "<YOUR_TELEGRAM_CHAT_ID>", "name": "memory-group" }
      ],
      "groupAllowFrom": ["memory-hourly", "memory-daily", "memory-weekly"]
    }
  }
}
```

> 注意：不要把真实 chatId 提交到任何仓库；用占位符即可。

### 4. 创建目录结构

```bash
mkdir -p ~/.openclaw/workspace/memory/{weekly,_state,archive/$(date +%Y)} ~/.openclaw/workspace/scripts
```

### 5. 添加 Cron Jobs

```bash
# 推荐：直接运行一键脚本（会安装/复制 helper scripts，并创建 3 个 cron jobs）
bash scripts/setup.sh --tz Asia/Shanghai

# 或手动添加（推荐参考 docs/cron-prompts.md 的最新 prompt 模板）
# 关键点：
# - prompt 第一行以 [cron:...] 开头（防套娃）
# - 不使用 sessions_list/sessions_history
# - 用 scan_sessions_incremental.py + memory/_state/*.json 做增量游标
# - 最终回复用于投递 Telegram：第一行 memory-<layer> ok

# 验证
openclaw cron list
```

### 5. 更新 AGENTS.md

将 [examples/AGENTS-memory-section.md](examples/AGENTS-memory-section.md) 中的内容合并到你的 `AGENTS.md` 的 Memory 部分。

### 6. 重启 Gateway

```bash
openclaw gateway restart
```

## 自定义

### 调整模型

Cron job 的模型可以随时替换。推荐原则：

| 层级 | 推荐 | 说明 |
|---|---|---|
| Hourly | 与主模型相同即可 | 大多数时候"无事退出"，有事需要理解对话上下文 |
| Daily | 与主模型相同即可 | 需要理解对话内容并做结构化摘要 |
| Weekly | 与主模型相同或更强 | 需要理解全局、做信息精炼和剪枝决策 |

> 💡 **实践经验**：之前尝试 hourly 用便宜模型（gemini-flash），但发现不够稳定。统一用主力模型反而更省心，因为 hourly 大多数时候"无事退出"消耗极少，真正有事时需要足够的理解能力。

修改方法：

```bash
# 查看现有 job
openclaw cron list

# 编辑模型（用 job ID）
openclaw cron edit <job-id> --model "new-provider/new-model"
```

### 调整频率

```bash
# 改为只在工作时间同步
openclaw cron edit <hourly-job-id> --cron "0 9,12,15,18 * * 1-5"

# 改为凌晨 2 点做 daily
openclaw cron edit <daily-job-id> --cron "0 2 * * *"
```

### 调整时区

```bash
openclaw cron edit <job-id> --tz "America/New_York"
```

## Token 成本估算

| 层级 | 频率 | 每次估算 | 月成本估算 |
|---|---|---|---|
| Hourly | ~150 次/月 | 大多无事退出（~100 token），有事 ~2000 token | ~$0.01-0.05（flash 价格） |
| Daily | 30 次/月 | ~5000-10000 token | ~$0.05-0.15（中等模型） |
| Weekly | 4 次/月 | ~10000-20000 token | ~$0.10-0.50（强模型） |
| **总计** | | | **~$0.15-0.70/月** |

*以上基于 2026 年初主流模型定价估算，使用免费/低价模型可以更低。*

## 与其他方案的对比

| 维度 | 本方案 | Engram 插件 | Mem0 | Supermemory |
|---|---|---|---|---|
| 与 OC 集成 | ⭐⭐⭐⭐⭐ 原生 | ⭐⭐⭐⭐⭐ 插件 | ⭐ 无 | ⭐ 无 |
| 额外依赖 | QMD only | QMD + OpenAI | Python + VectorDB | SaaS |
| 成本 | ~$0.5/月 | 更高（每轮提取） | 自托管免费 | $19+/月 |
| 本地优先 | ✅ | ✅ | ⚠️ | ❌ |
| 记忆分类 | ❌ | ✅ 10 种 | ✅ | ✅ |
| 侵入性 | 零（纯用户空间） | 中（替换 plugin） | 高（独立系统） | 高（SaaS 锁定） |
| 官方升级兼容 | ✅ 完全兼容 | ⚠️ 可能冲突 | N/A | N/A |

## 常见问题

### Q: 官方以后自带自动记忆提取怎么办？

直接关掉 cron jobs 切过去：

```bash
openclaw cron list
openclaw cron edit <job-id> --disabled
```

本方案全在用户空间，不影响任何官方功能。

### Q: 用户执行 /new 后，之前的对话会丢失吗？

不会。`/new` 只是将旧 session 文件重命名为 `<id>.jsonl.reset.<timestamp>` 归档格式，数据完整保留。

新方案的关键点是：cron 不再依赖 `sessions_list/sessions_history`，而是用扫描器同时覆盖：
- `~/.openclaw/agents/main/sessions/*.jsonl`
- `~/.openclaw/agents/main/sessions/*.jsonl.reset.*`

因此 `/new` 不会“让 cron 看不到旧会话”。另外，如果你开启了 QMD 的 session transcripts 索引，即使将来本地 session 文件被清理，仍可通过检索召回细节。

### Q: OpenAI Responses streaming 偶发崩溃（SSE 空 data）怎么办？

偶发会出现 SSE 帧 `data:` 为空字符串（keepalive），导致 SDK 内部 `JSON.parse("")` 报错。

使用本仓库提供的补丁脚本修复（升级依赖后可能需要重打）：

```bash
bash ~/.openclaw/workspace/scripts/patch-openai-sse-empty-data.sh
```

### Q: 断网/电脑关机时 cron 会丢数据吗？

不会。设计上是自愈的：每次 cron 处理的是"自上次以来的所有未处理内容"，不是固定时间窗口。漏跑几次，下次执行会自动补上。

### Q: MEMORY.md 200 行够用吗？

200 行是软上限，不是硬限制。核心信息放 MEMORY.md，细节通过 QMD 语义搜索随时召回。实际上 200 行精炼的信息量比 2000 行流水账有用得多。

### Q: 可以同时装 Engram 吗？

技术上可以但不推荐。两套系统都在写记忆文件，容易产生冲突和重复。选一个就好。

## 致谢

本方案融合了以下社区贡献者的智慧，在此表示感谢：

- **[Calicastle (@calicastle)](https://x.com/calicastle)** — 三层架构原始设计
  - 原文：[《如何给 OpenClaw 搭建一套「永不失忆」的记忆系统》](https://x.com/calicastle/status/2021229394724102229)
  - 核心贡献：三层分频 cron 设计（Hourly / Daily / Weekly）、QMD 后端配置实践
  - 转载参考：[onefly.top 镜像](https://onefly.top/posts/260211.html)

- **[Linux.do 社区 — 「OpenClaw 终极记忆系统」](https://linux.do/t/topic/1621623)** — 工程优化
  - 核心贡献：Session-ID 幂等去重、信号过滤（短会话跳过）、MEMORY.md 上限控制、4D 验证、自动备份

- **[OpenClaw](https://github.com/openclaw/openclaw)** — 基础设施
  - 官方记忆文档：[Memory Concepts](https://docs.openclaw.ai/concepts/memory)
  - QMD 后端文档：[QMD Backend (Experimental)](https://docs.openclaw.ai/concepts/memory#qmd-backend-experimental)
  - Cron 文档：[Cron Jobs](https://docs.openclaw.ai/automation/cron-jobs)

- **[QMD](https://github.com/tobi/qmd)** — 本地优先的混合搜索引擎（BM25 + 向量 + reranking）

### 调研中评估但未采纳的方案

| 方案 | 链接 | 未采纳原因 |
|---|---|---|
| openclaw-engram | [GitHub](https://github.com/joshuaswarren/openclaw-engram) | 每轮 LLM 提取成本高，cron 批量更经济 |
| Mem0 | [GitHub](https://github.com/mem0ai/mem0) | 架构太重，无 OpenClaw 原生集成 |
| Supermemory | [官网](https://supermemory.ai) | 纯 SaaS，数据不可控，收费 |

详细对比分析见 [docs/design-decisions.md](docs/design-decisions.md)。

## License

MIT
