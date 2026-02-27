# OpenClaw Memory Fusion（中文版）

> 完整文档请阅读 [README.md](README.md)，本文件为简要中文说明。

## 这是什么？

一套基于 OpenClaw 原生能力的「永不失忆」记忆方案。通过 3 个定时任务（cron job）自动提取、蒸馏、巩固对话记忆，解决 OpenClaw 默认"靠模型自觉写记忆"的短板。

**核心特点**：
- ✅ 零插件、零额外依赖（仅需 QMD）
- ✅ 全本地运行，数据完全可控
- ✅ 不修改任何官方代码，不影响 OpenClaw 升级
- ✅ 成本极低（约 $0.5/月）

## 三层架构

| 层级 | 频率 | 职责 |
|---|---|---|
| L1 Hourly | 白天 5 次（10/13/16/19/22 点） | 轻量检查新活动，有则 append |
| L2 Daily | 每晚 23 点 | 蒸馏全天 session 为结构化日志 |
| L3 Weekly | 每周日 22 点 | 聚合本周，精简 MEMORY.md |

## 关键设计

- **Session-ID 幂等**：HTML 注释维护已处理 ID，跨层去重
- **归档直读**：`/new` 后直接扫描 `.reset.*` 归档文件，不依赖 QMD 索引
- **QMD 兜底**：归档文件被清理后仍可从 QMD 索引搜索
- **断网自愈**：漏跑不丢数据，下次自动补上
- **`sessions_list` 必须加 `activeMinutes`**：否则返回全量数据导致 token 爆炸超时（v0.5.0 踩坑修复）

## 快速开始

```bash
# 1. 安装 QMD（推荐 npm）
npm install -g @tobilu/qmd

# 2. 初始化索引
cd ~/.openclaw/workspace
qmd collection add .
qmd embed

# 3. 配置 openclaw.json（参考 README.md 或 examples/）
# 4. 添加 3 个 cron job（参考 README.md）
# 5. 重启 gateway
openclaw gateway restart
```

## 版本历史

- **v0.5.0** (2026-02-27): 修复 hourly cron 超时（sessions_list 加 activeMinutes）
- **v0.4.0** (2026-02-27): 归档 session 直读 + Session-ID 真幂等
- **v0.3.0** (2026-02-27): 修复 QMD 索引为空导致系统完全失效
- **v0.2.0** (2026-02-26): memory_search 兜底 + /new flush 机制
- **v0.1.0** (2026-02-24): 初始版本

详见 [CHANGELOG.md](CHANGELOG.md)。

## 灵感来源

- [Calicastle 三层架构](https://x.com/calicastle/status/2021229394724102229) — 三层分频 cron 设计
- [Linux.do 终极记忆系统](https://linux.do/t/topic/1621623) — 幂等去重、信号过滤
- [OpenClaw 官方文档](https://docs.openclaw.ai/concepts/memory) — QMD 后端、session transcript 索引

## 详细文档

- [完整 README](README.md)
- [设计决策与方案对比](docs/design-decisions.md)
- [Cron Prompt 详解](docs/cron-prompts.md)
- [故障排除](docs/troubleshooting.md)
