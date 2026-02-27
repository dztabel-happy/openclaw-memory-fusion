# Changelog

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
   # "command": "/Users/abel/.npm-global/bin/qmd"
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
