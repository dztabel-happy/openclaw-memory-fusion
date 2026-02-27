# Cron Prompts 详解

本文档详细解释 3 个 cron job 的 prompt 设计思路，方便自定义调整。

## Layer 1: Hourly Micro-Sync

**目标**：安全网，确保重要内容不丢失。覆盖活跃 session 和已被 `/new` 关闭的归档 session。

```
你是记忆微同步 agent。检查最近是否有新的有价值内容。

数据源（按优先级）：
1. 用 sessions_list 查看当前活跃 session
2. 用 exec 扫描归档 session：
   ls -lt ~/.openclaw/agents/main/sessions/*.reset.* 2>/dev/null | head -10
   筛选最近几小时内新归档的文件（按文件修改时间判断）
3. 对筛选出的归档文件，用 read 读取 jsonl 内容
   （每行是一条消息 JSON，提取 role 和 content 字段）

处理规则：
1. 先读 memory/YYYY-MM-DD.md（今天日期），解析第一行的
   <!-- processed: id1, id2 --> 注释获取已处理的 session ID 列表
2. 跳过已处理的 session ID
   （从文件名中提取 ID，即 .jsonl 前的 UUID 部分）
3. 跳过无意义 session（<2条 role=user 的消息）
4. 没有新的有意义内容直接回复 NO_REPLY
5. 有新内容则提取关键信息 append 到 memory/YYYY-MM-DD.md
   格式：## HH:MM 简短标题
         - 要点1
         - 要点2
6. 更新文件第一行的 <!-- processed: ... --> 注释，
   加入本次处理的 session ID
7. 完成后回复 NO_REPLY
```

**设计要点**：
- **归档直读**：直接扫描 `.reset.*` 文件，不再依赖 `memory_search` 做兜底。数据源确定、可靠、完整
- **Session-ID 幂等**：在 md 文件头部用 HTML 注释维护已处理 ID 列表，实现 ID 级去重而非内容级去重
- "没有新的有意义对话直接 NO_REPLY" → 大多数执行零成本
- "<2条用户消息" → 信号过滤，跳过系统消息/误触
- 用最便宜的模型（如 gemini-flash），因为大多数时候只是检查然后退出

## Layer 2: Daily Sync

**目标**：将零散的对话蒸馏为结构化日志。全量覆盖今天的活跃和归档 session。

```
你是每日记忆蒸馏 agent。将今天所有对话蒸馏为结构化日志。

数据源（全量覆盖）：
1. 用 sessions_list(activeMinutes=1440) 获取今天活跃的 session
2. 用 exec 扫描今天的归档 session：
   ls -lt ~/.openclaw/agents/main/sessions/*.reset.* 2>/dev/null
   筛选今天日期的归档文件
3. 对活跃 session 用 sessions_history 获取内容；
   对归档文件用 read 读取 jsonl
4. QMD 兜底：用 memory_search 搜索今天的关键词，
   捕获可能遗漏的内容

幂等性（Session-ID 去重）：
1. 读 memory/YYYY-MM-DD.md 第一行的
   <!-- processed: id1, id2 --> 注释
2. 跳过已处理的 session ID
3. 处理完后更新该注释

蒸馏规则：
1. 跳过无意义 session（<2条 role=user 的消息）
2. 蒸馏为结构化格式写入 memory/YYYY-MM-DD.md：
   ## 主题标题
   - 关键决策/结论
   - 重要信息/偏好
   - 待办/后续行动
3. 将超过 7 天的 daily log 移动到 memory/archive/YYYY/ 目录
4. 完成后回复 NO_REPLY
```

**设计要点**：
- **归档直读**：直接扫描 `.reset.*` 文件获取被 `/new` 关闭的 session，不再仅依赖 `memory_search` 兜底
- **Session-ID 幂等**：HTML 注释维护已处理 ID 列表，与 Hourly 共享同一去重机制，避免 Hourly 和 Daily 重复处理
- `activeMinutes=1440` = 24 小时，覆盖全天活跃 session
- ">=2条用户消息" → 过滤无意义 session
- "移动到 archive" → 自动清理，保持 memory/ 目录整洁
- 用中等模型，需要理解对话内容做摘要

## Layer 3: Weekly Tidy

**目标**：长期记忆巩固，MEMORY.md 精炼。

```
你是每周记忆巩固 agent。聚合本周记忆，精简 MEMORY.md。

步骤：
1. 读取本周所有 memory/YYYY-MM-DD.md 日志
2. 读取当前 MEMORY.md
3. 提取本周新的偏好、决策、项目状态、技术配置、人物关系、重要教训
4. 更新 MEMORY.md：
   - 合并新信息到对应分类
   - 剪枝过时/已失效信息
   - 保持精简（软上限约200行）
   - 更新底部最后更新时间戳
5. 将本周日志压缩摘要写入 memory/weekly/YYYY-WXX.md（XX=周数）
6. 完成后回复 NO_REPLY
```

**设计要点**：
- 用最好的模型，需要理解全局并做信息精炼决策
- "剪枝过时/已失效信息" → 防止 MEMORY.md 无限膨胀
- "软上限约200行" → 不硬卡，但引导精简
- "写入 weekly/YYYY-WXX.md" → 周摘要独立保存，QMD 可索引

## 自定义 Prompt 建议

你可以根据自己的需求调整 prompt：

### 添加特定领域关注点

```
... 特别关注以下类型的信息：
- 代码架构决策和技术选型
- 用户反馈和产品需求
- Bug 修复和踩坑记录
```

### 添加多语言支持

```
... 输出使用与用户对话相同的语言。如果对话混合使用多种语言，优先使用中文。
```

### 调整信号过滤阈值

```
... 没有新的有意义对话（<3条用户消息或对话时长<2分钟）直接回复 NO_REPLY
```

## 修改 Cron Prompt

```bash
# 查看现有 job
openclaw cron list --json

# 用 job ID 修改 message
openclaw cron edit <job-id> --message '新的 prompt 内容'
```
