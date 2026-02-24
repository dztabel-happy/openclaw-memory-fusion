# OpenClaw Memory Fusion（中文版）

> 完整文档请阅读 [README.md](README.md)，本文件为简要中文说明。

## 这是什么？

一套基于 OpenClaw 原生能力的「永不失忆」记忆方案。通过 3 个定时任务（cron job）自动提取、蒸馏、巩固对话记忆，解决 OpenClaw 默认"靠模型自觉写记忆"的短板。

**核心特点**：
- ✅ 零插件、零额外依赖（仅需 QMD）
- ✅ 全本地运行，数据完全可控
- ✅ 不修改任何官方代码，不影响 OpenClaw 升级
- ✅ 成本极低（约 $0.5/月）

## 快速开始

```bash
# 一键安装
bash scripts/setup.sh --tz Asia/Shanghai

# 手动添加 memory 配置到 openclaw.json（参考 examples/openclaw-memory-config.json）
# 合并 examples/AGENTS-memory-section.md 到你的 AGENTS.md
# 重启 gateway
openclaw gateway restart
```

## 灵感来源

- [Calicastle 三层架构](https://x.com/calicastle/status/2021229394724102229) — 三层分频 cron 设计
- [Linux.do 终极记忆系统](https://linux.do/t/topic/1621623) — 幂等去重、信号过滤
- [OpenClaw 官方文档](https://docs.openclaw.ai/concepts/memory) — QMD 后端、session transcript 索引

## 详细文档

- [完整 README（英文+中文）](README.md)
- [设计决策与方案对比](docs/design-decisions.md)
- [Cron Prompt 详解](docs/cron-prompts.md)
- [故障排除](docs/troubleshooting.md)
