# 方案调研与设计决策

## 调研的方案

### 1. OpenClaw 官方记忆 + QMD 后端

- **文档**: https://docs.openclaw.ai/concepts/memory#qmd-backend-experimental
- **架构**: Markdown 文件 → QMD sidecar（BM25 + 向量 + reranking）
- **优势**: 原生集成、全本地、持续迭代
- **短板**: 记忆写入靠模型自觉，无系统级自动提取

### 2. Calicastle 三层架构

- **来源**: https://x.com/calicastle/status/2021229394724102229
- **架构**: 3 个 cron job（Hourly/Daily/Weekly）+ QMD
- **核心创新**: 用 cron + 独立 agent 做系统级自动提取
- **实测**: Mac mini 24/7 运行一周零失忆

### 3. Linux.do 终极记忆系统

- **来源**: https://linux.do/t/topic/1621623
- **架构**: 2 个 cron（4h 同步 + 凌晨整理）
- **核心创新**: Session-ID 幂等、信号过滤、MEMORY.md 硬上限 80 行/5KB
- **特点**: 4D 验证、自动备份

### 4. Engram 社区插件

- **仓库**: https://github.com/joshuaswarren/openclaw-engram
- **架构**: OpenClaw 插件，LLM 实时提取 + QMD 检索
- **特色**: 10 种记忆分类、Memory Boxes、Episode/Note 双存储
- **代价**: 每轮 LLM 调用、依赖 OpenAI API、复杂度高

### 5. Mem0

- **仓库**: https://github.com/mem0ai/mem0
- **架构**: LLM 提取 → 向量存储 + 知识图谱
- **优势**: 学术质量最高（LOCOMO +26%）、YC 孵化
- **不适合**: 与 OpenClaw 无原生集成，架构重

### 6. Supermemory

- **网站**: https://supermemory.ai
- **架构**: 知识图谱 + 语义理解，纯 SaaS
- **定价**: Free / Pro $19/月 / Scale $399/月
- **不适合**: 数据在第三方、收费、无 OC 集成

## 为什么选择融合方案

| 需求 | 融合方案如何满足 |
|---|---|
| 系统级自动提取 | 3 个 cron job 定时蒸馏（来自 Calicastle） |
| 幂等性/游标 | 增量 cursor（按文件 byte offset）避免重复处理 |
| 防膨胀 | MEMORY.md 软上限 + 自动剪枝（来自 Linux.do + 改良） |
| 零侵入 | 全在用户空间，不动官方代码 |
| 成本可控 | 分层用模型，便宜的做轻活 |
| 断网容错 | 自愈设计，下次执行自动补上 |

## 2026-03-01：核心重构（文件扫描 + 增量游标）

### 背景：isolated cron 的“可见性问题”

实测发现：cron job 使用 `--session isolated` 时，调用 `sessions_list` / `sessions_history` 可能看不到主会话树（或返回不完整）。  
这会导致“以为没有新对话”→ 记忆漏写。

因此，新设计把 **会话文件** 作为唯一事实来源（source of truth）：

- `~/.openclaw/agents/main/sessions/*.jsonl`（活跃会话持续 append）
- `~/.openclaw/agents/main/sessions/*.jsonl.reset.*`（`/new` 后归档）

### 方案：scan_sessions_incremental.py

引入 `scripts/scan_sessions_incremental.py`，用“日志 tail”方式做增量扫描：

- **每个文件一个 cursor（byte offset）**，记录在 `memory/_state/scan_sessions_*.json`
- **只推进到最后一个完整换行**，容忍最后一行半写（避免 JSON 半行导致解析失败）
- 同一会话文件后续 append 不会漏读
- 断网/关机漏跑也不会丢：下一次会把 gap 全补上

### 防套娃（递归）

cron 自己的执行会产生 session 文件。如果不处理，下一轮扫描会把 cron 的输出当作“新对话”再总结一次，形成递归污染。

新设计的三道保险：

1) cron prompt 第一行以 `[cron:` 开头（例如 `[cron:memory-hourly] ...`）  
2) 扫描器忽略“cron 会话”（heuristic：该 session 的首条 user 消息以 `[cron:` 开头）  
3) 扫描器额外忽略通知文本（`memory-<layer> ok` / `NO_REPLY`）与 `tool/system` 输出

### 信号筛选（只要有价值的部分）

记忆提取只消费两类内容：

- `role=user`：用户真实意图与输入
- `role=assistant`：最终回复（跳过 tool-call / tool 输出）

避免把工具噪音、系统 banner、执行细节写进记忆文件。

### 通知：面向 Telegram 群的“运营面板”

cron 的最终回复用于投递到一个专用 Telegram 群（便于观察系统健康状况），统一格式：

- 第一行：`memory-<layer> ok`
- 第二行：stats（sessions/messages/truncated 等）
- 后面：少量 bullet（最重要新增记忆点）

并在 `openclaw.json` 中用 allowlist 保护群聊输出范围（见 README / troubleshooting）。

### 兼容性与风险

- 本方案完全在用户空间运行，不修改 OpenClaw 核心；升级 OpenClaw 风险低
- 但如果上游 OpenAI JS SDK streaming 存在 SSE 空 data 崩溃，需要手动打补丁（已提供脚本，见 `docs/troubleshooting.md`）

## 不选择的方案及原因

- **Engram**: 每轮 LLM 提取成本高，cron 批量处理更经济
- **Mem0**: 架构太重，集成成本高，杀鸡用牛刀
- **Supermemory**: SaaS 锁定 + 隐私风险
- **硬上限 80 行**: 过于激进，改为软上限 ~200 行更灵活
