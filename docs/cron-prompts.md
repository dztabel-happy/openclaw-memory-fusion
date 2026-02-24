# Cron Prompts 详解

本文档详细解释 3 个 cron job 的 prompt 设计思路，方便自定义调整。

## Layer 1: Hourly Micro-Sync

**目标**：安全网，确保重要内容不丢失。

```
你是记忆微同步 agent。检查最近 session 是否有新的有价值内容。

规则：
1. 用 sessions_list 查看最近活跃 session
2. 没有新的有意义对话（<2条用户消息）直接回复 NO_REPLY
3. 有新内容则提取关键信息 append 到 memory/YYYY-MM-DD.md（今天日期）
   格式：## HH:MM 简短标题
         - 要点1
         - 要点2
4. 不要重复已记录的内容（检查文件已有内容避免重复）
5. 完成后回复 NO_REPLY
```

**设计要点**：
- "没有新的有意义对话直接 NO_REPLY" → 大多数执行零成本
- "<2条用户消息" → 信号过滤，跳过系统消息/误触
- "检查文件已有内容避免重复" → 幂等性保障
- 用最便宜的模型（如 gemini-flash），因为大多数时候只是检查然后退出

## Layer 2: Daily Sync

**目标**：将零散的对话蒸馏为结构化日志。

```
你是每日记忆蒸馏 agent。将今天所有 session 对话蒸馏为结构化日志。

步骤：
1. 用 sessions_list(activeMinutes=1440) 获取今天所有 session
2. 对每个有意义的 session（>=2条用户消息），用 sessions_history 获取内容
3. 幂等性：检查 memory/YYYY-MM-DD.md 已有内容，跳过已处理的 session
4. 蒸馏为结构化格式写入 memory/YYYY-MM-DD.md：
   ## 主题标题
   - 关键决策/结论
   - 重要信息/偏好
   - 待办/后续行动
5. 将超过 7 天的 daily log 移动到 memory/archive/YYYY/ 目录
6. 完成后回复 NO_REPLY
```

**设计要点**：
- `activeMinutes=1440` = 24 小时，覆盖全天
- ">=2条用户消息" → 过滤无意义 session
- "检查已有内容，跳过已处理" → 幂等性，hourly 已记录的不重复
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
