# Changelog

## [0.7.1] - 2026-03-24

### 与 OpenClaw 2026.3 官方行为对齐（保留 3 cron 架构）

- `scripts/setup.sh`
  - 新增 `--notify-channel/--notify-to/--notify-account`，支持显式 Telegram/频道投递
  - 三个 isolated cron job 默认加上 `--light-context`
  - 不再手动初始化“旁路 QMD collection”；改为提示使用 `openclaw memory status --agent main --index`
  - 安装总结更新为“配置热加载优先，必要时再 restart gateway”
- README / README_CN / troubleshooting / cron-prompts
  - 明确本仓库定位为“补强官方 memory/QMD”，不是替代官方 memory flush / hook
  - 补充 OpenClaw sidecar/XDG 下的 QMD 预热方式
  - 补充 `session.maintenance.resetArchiveRetention` 与显式 cron delivery 的注意事项

## [0.7.0] - 2026-03-02

### 可靠性增强与长期记忆加速

- 新增 A′：daily 维护 `MEMORY.md#近期重要更新（自动，滚动7天）`，weekly 晋升+清理。
- 新增并发写入保护：`scripts/lockfile.py`（daily/weekly 写 `MEMORY.md` 前加锁）。
- weekly 改为“每天触发 + gate”：`scripts/weekly_gate.py`，确保每周至少成功一次（ISO week）。
- `scan_sessions_incremental.py` 吞掉 `BrokenPipeError`（例如 `| head` 场景）。
- 文档全面同步：README + prompts + troubleshooting + design decisions。

## [0.6.0] - 2026-03-01

### 重构：会话获取改为“文件扫描 + 增量游标”

#### 背景
- `--session isolated` 的 cron 运行环境可能看不到主会话树，`sessions_list` / `sessions_history` 会漏数据或直接失败
- 旧方案依赖 session-id 注释或时间窗参数，容易在 `/new`、断网漏跑、同一会话持续 append 等场景下出现缺口

#### 变更
- 新增 `scripts/scan_sessions_incremental.py`：
  - 扫描 `~/.openclaw/agents/main/sessions/*.jsonl` 和 `*.jsonl.reset.*`
  - 每个文件维护 byte offset（只推进到最后一个完整换行，容忍半行 JSON）
  - 只输出“有价值信号”：user 消息 + assistant 最终回复；忽略 tool/system
- 防套娃（递归污染）：
  - cron prompt 第一行统一以 `[cron:` 开头
  - 扫描器忽略 cron 会话 + 忽略 `memory-<layer> ok` / `NO_REPLY` 通知文本
- 通知升级：面向 Telegram 群的运营面板
  - 第一行固定 `memory-<layer> ok`，后续包含 stats + 少量要点
  - 文档补充 Telegram allowlist：`channels.telegram.groupPolicy=allowlist` + `channels.telegram.groups` + `groupAllowFrom`
- 新增 `scripts/patch-openai-sse-empty-data.sh`：
  - 修复 OpenAI Responses streaming 遇到 SSE 空 `data:` 时的崩溃（给 SDK 的 `dist/streaming.*` 加 guard）
- `scripts/setup.sh` 更新：
  - 自动安装/复制 helper scripts 到 `~/.openclaw/workspace/scripts/`
  - 创建 `memory/_state/` 目录
  - Hourly 默认改为 `0 7,11,15,19,23 * * *`（Asia/Shanghai）
- `.gitignore` 增加忽略 `memory/_state` 与备份文件

## [0.5.0] - 2026-02-27

### 修复：Hourly Cron 连续超时

#### 问题
- memory-hourly 连续 5 次执行失败，错误均为 `LLM request timed out`（54 秒超时）
- memory-daily 使用相同模型和 timeout 却正常运行

#### 根因
- Hourly prompt 中 `sessions_list` **未设置 `activeMinutes` 参数**，返回所有 session 数据量过大，token 爆炸超时
- Daily prompt 设置了 `sessions_list(activeMinutes=1440)` 所以没问题

#### 修复
- Hourly prompt 的 `sessions_list` 加上 `activeMinutes=360`（6 小时窗口）
- 修复后手动测试通过：64 秒完成，consecutiveErrors 归零

#### 其他变更
- 三个 cron job 模型统一为 `anyrouter/claude-opus-4-6`（之前推荐 hourly 用便宜模型，实际统一更稳定）
- `memory.qmd.command` 确认指向 npm 版 (`~/.npm-global/bin/qmd`)，向量 embed 正常

### 经验教训
- `sessions_list` 不加范围限制会返回海量数据，在 cron prompt 中务必指定 `activeMinutes`
- 排查 cron 失败时先看 `openclaw cron list --json` 的 `state.lastError` 字段

## [0.4.0] - 2026-02-27

### 优化：归档 Session 直读 + Session-ID 真幂等

#### 背景

小涛发现 OpenClaw `/new` 的完整生命周期：
1. 产生：每次消息 append 到 `~/.openclaw/agents/<agent>/sessions/<sessionId>.jsonl`
2. `/new` 时：旧文件重命名为 `<sessionId>.jsonl.reset.<timestamp>`（归档，数据完整保留）
3. 新 session：生成新 sessionId，写新 `.jsonl`

这意味着归档 session 的位置是**确定的**，可以直接读取，不需要依赖 QMD 索引间接搜索。

#### 改进

1. **Hourly/Daily 数据源升级**
   - 新增归档 session 直读：扫描 `sessions/*.reset.*` 文件，按时间筛选近期归档
   - `memory_search` 从"主要兜底手段"降级为"最后保险"（仅 Daily 保留）
   - 数据源更确定、可靠、完整

2. **Session-ID 真幂等**
   - 之前：靠"检查 md 文件已有内容避免重复"（内容级去重，不可靠）
   - 现在：在 `memory/YYYY-MM-DD.md` 头部用 HTML 注释维护已处理 ID 列表
   - 格式：`<!-- processed: abc123, def456 -->`
   - Hourly 和 Daily 共享同一去重列表，彻底避免重复处理

3. **QMD 安装文档修正**
   - 之前：说 "Bun 内置 SQLite 不支持 sqlite-vec 扩展"
   - 实际：QMD 源码已做跨运行时兼容（`db.ts` 中 bun 用 `bun:sqlite` + `loadExtension`，Node.js 用 `better-sqlite3`）
   - 真正原因：`bun install -g` 从 git 安装拿到的是未编译 TypeScript 源码（无 `dist/`），需手动构建；另外 macOS 自带 SQLite 不支持扩展，需 `brew install sqlite`
   - npm registry 的包是预编译好的，开箱即用


## [0.3.0] - 2026-02-27

### 问题（严重 - 导致三层记忆系统完全失效）

1. **QMD 从未建索引** - OpenClaw 配置了 `includeDefaultMemory: true`，但并不会自动创建 QMD collection，导致 `memory_search` 永远返回空
2. **retentionDays: 0** - session transcripts 立即过期，无法被 QMD 索引
3. **向量 embed 失败** - Bun 内置 SQLite 不支持加载 sqlite-vec 扩展，向量搜索能力缺失

### 症状
- memory-hourly cron 执行了，但 `memory_search` 返回空 → 判断"无新内容" → NO_REPLY
- memory-daily cron 只能通过 `sessions_list` 直接读 session，无法通过 `memory_search` 捕获 /new 后的历史 session

### 修复

1. **手动初始化 QMD 索引**
   ```bash
   cd ~/.openclaw/workspace
   qmd collection add .
   qmd embed
   ```

2. **修复 retentionDays**
   - 将 `openclaw.json` 中的 `memory.qmd.sessions.retentionDays` 从 `0` 改为 `30`
   - 这样 session transcripts 会被保留 30 天供 QMD 索引

3. **修复向量 embed（可选，BM25 搜索已可用）**
   - 问题：Bun 内置 SQLite 不支持 `loadExtension`，导致 sqlite-vec 无法加载
   - 解决：使用 npm 安装的 qmd（Node.js + better-sqlite3）而非 bun 版
   ```bash
   npm install -g @tobilu/qmd
   # 将 openclaw.json 中的 qmd 命令从 bun 版改为 npm 版
   # "command": "<PATH_TO_QMD>"
   ```

### 验证修复
```bash
# QMD 索引状态
qmd status
# 应显示: Total: N files indexed, Vectors: M embedded

# 搜索测试
qmd search "关键词"
# 或通过 OpenClaw: memory_search(query="关键词")
```

## [0.2.0] - 2026-02-26

### 问题
- `/new` 重置会话后，cron job 通过 `sessions_list` 看不到已关闭的历史 session，导致记忆丢失

### 修复
- **memory-hourly prompt**: 新增 `memory_search` 步骤，搜索 QMD 索引覆盖已关闭的历史 session
- **memory-daily prompt**: 同上，额外搜索当天关键词捕获历史 session 内容
- **AGENTS.md 记忆章节**: 新增 `/new` 前主动 flush 规则（检测到 `/new` 意图时自动写入 memory）

### 策略
双保险：主动 flush（agent 自觉写入）+ cron `memory_search` 兜底补救

## [0.1.1] - 2026-02-24

### 修复
- `retentionDays` 改为 `0`（原以为永不过期，实际上会导致立即过期），`-1` 不被 OpenClaw schema 接受
- **注意**：此版本修复有误，v0.3.0 已修正为 `30`

## [0.1.0] - 2026-02-24

### 初始版本
- 三层自动记忆方案：Hourly (L1) / Daily (L2) / Weekly (L3)
- 一键安装脚本 `setup.sh`
- QMD 配置模板
- AGENTS.md 记忆章节模板
