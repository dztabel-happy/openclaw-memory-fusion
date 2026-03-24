# OpenClaw Memory Fusion（中文版）

> 完整文档见 [README.md](README.md)。这里是“快读版”。

## 这是什么？

一套基于 OpenClaw 原生能力的三层记忆系统（hourly / daily / weekly），重点补强 deterministic 提取、isolated cron 场景与 Telegram 运维可见性。

说明：

- OpenClaw 近版本已经有 pre-compaction memory flush，也可以配合 `session-memory` hook
- 本仓库不是替代官方 memory，而是在其上做更强的自动提取与可观测运维

## 核心优势（一句话版）

- **不漏**：以 session JSONL 文件为事实源 + byte offset 增量游标
- **去噪**：只保留 user + assistant 最终回复
- **防套娃**：忽略 `[cron:*]` 会话 + 忽略 `memory-*.ok` 通知
- **更快可用**：daily 维护 `MEMORY.md` 的滚动 7 天区（A′）
- **更可靠**：`MEMORY.md` 写入锁 + weekly gate（每周至少成功一次）

## 三层设计（推荐调度）

| 层级 | 频率 | 职责 |
|---|---:|---|
| L1 Hourly | 7/11/15/19/23 点 | 微同步：有价值才落盘 |
| L2 Daily | 23:30 | 当天 canonical + A′ 滚动区 |
| L3 Weekly | 00:20（每天触发但 gate） | 巩固 + 晋升 + 分类治理 |

## 快速开始

```bash
# 1) 安装 QMD（macOS 上继续用 npm 版通常最省心）
npm install -g @tobilu/qmd

# 2) 配置 openclaw.json（参考 examples/ 与 README.md）
#    注意 retentionDays 与 resetArchiveRetention

# 3) 验证 OpenClaw 实际使用的 memory/QMD 状态
openclaw memory status --agent main --index

# 4) 一键安装脚本与 cron jobs（推荐显式指定 Telegram 话题）
bash scripts/setup.sh --tz Asia/Shanghai --notify-to '<TELEGRAM_CHAT_ID>:topic:<TOPIC_ID>'

# 5) 大多数配置会热加载；只有状态没跟上时再考虑 restart
openclaw gateway restart   # fallback
```

## 文档导航

- 设计决策：`docs/design-decisions.md`
- Prompt 模板：`docs/cron-prompts.md`
- 故障排除：`docs/troubleshooting.md`
