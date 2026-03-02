# OpenClaw Memory Fusion（中文版）

> 完整文档见 [README.md](README.md)。这里是“快读版”。

## 这是什么？

一套基于 OpenClaw 原生能力的三层记忆系统（hourly / daily / weekly），解决“默认记忆写入靠模型自觉”的不确定性。

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
# 1) 安装 QMD（推荐 npm 预编译）
npm install -g @tobilu/qmd

# 2) 初始化索引
cd ~/.openclaw/workspace
qmd collection add .
qmd embed   # 可选

# 3) 配置 openclaw.json（参考 examples/ 与 README.md）

# 4) 一键安装脚本与 cron jobs
bash scripts/setup.sh --tz Asia/Shanghai

# 5) 重启 gateway
openclaw gateway restart
```

## 文档导航

- 设计决策：`docs/design-decisions.md`
- Prompt 模板：`docs/cron-prompts.md`
- 故障排除：`docs/troubleshooting.md`
