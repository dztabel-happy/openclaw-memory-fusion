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
| 幂等性/去重 | Session-ID 检查避免重复处理（来自 Linux.do） |
| 防膨胀 | MEMORY.md 软上限 + 自动剪枝（来自 Linux.do + 改良） |
| 零侵入 | 全在用户空间，不动官方代码 |
| 成本可控 | 分层用模型，便宜的做轻活 |
| 断网容错 | 自愈设计，下次执行自动补上 |

## 不选择的方案及原因

- **Engram**: 每轮 LLM 提取成本高，cron 批量处理更经济
- **Mem0**: 架构太重，集成成本高，杀鸡用牛刀
- **Supermemory**: SaaS 锁定 + 隐私风险
- **硬上限 80 行**: 过于激进，改为软上限 ~200 行更灵活
