# Changelog

## [0.2.0] - 2025-06-27

### 问题
- `/new` 重置会话后，cron job 通过 `sessions_list` 看不到已关闭的历史 session，导致记忆丢失

### 修复
- **memory-hourly prompt**: 新增 `memory_search` 步骤，搜索 QMD 索引覆盖已关闭的历史 session
- **memory-daily prompt**: 同上，额外搜索当天关键词捕获历史 session 内容
- **AGENTS.md 记忆章节**: 新增 `/new` 前主动 flush 规则（检测到 `/new` 意图时自动写入 memory）

### 策略
双保险：主动 flush（agent 自觉写入）+ cron `memory_search` 兜底补救

## [0.1.1] - 2025-06-24

### 修复
- `retentionDays` 改为 `0`（永不过期），`-1` 不被 OpenClaw schema 接受

## [0.1.0] - 2025-06-24

### 初始版本
- 三层自动记忆方案：Hourly (L1) / Daily (L2) / Weekly (L3)
- 一键安装脚本 `setup.sh`
- QMD 配置模板
- AGENTS.md 记忆章节模板
