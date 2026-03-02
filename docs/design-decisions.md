# 方案调研与设计决策（同步到当前“生产可用”版本）

本 repo 的目标不是“做一个最复杂的记忆系统”，而是做一个**可长期运维、可升级、可审计、可验证**的方案。

## 我们优化的目标

- 不遗漏：跨夜、漏跑、同 session 追加都不丢
- 适配 isolated cron：不依赖 `sessions_list/sessions_history`
- 防套娃：cron session 与 cron 通知不进入记忆输入
- 高信号：只提炼 durable info，不搬运 transcript
- 快速可用：daily 让长期记忆更快可用（A′）
- 可运维：锁 + gate + 通知面板

## 事实源（source of truth）

**唯一事实源**是本地 session JSONL 文件：

- `~/.openclaw/agents/<agent>/sessions/*.jsonl`
- `~/.openclaw/agents/<agent>/sessions/*.jsonl.reset.*`

原因：isolated cron 环境下，`sessions_list/sessions_history` 可能因为 session tree 可见性限制而不可用或不完整。

## 为什么用 byte offset 增量游标

相比“最近 3 小时”这类时间窗，本方案使用 per-file byte offset：

- 不依赖时间戳完整性与排序
- 支持长时间 gap 补跑
- 支持同一会话文件持续增长
- 通过“只推进到最后一个完整换行”避免半行 JSON

## 防套娃（递归污染）

硬约束：

1) cron prompt 第一行以 `[cron:` 开头（可检测）
2) 扫描器忽略 cron session（首条 user 以 `[cron:` 开头）
3) 扫描器忽略 `memory-*.ok` / `NO_REPLY` 等通知文本

收敛验证：反复跑 hourly，最终应达到 `events: 0`。

## A′：daily 让长期记忆更快可用

问题：

- weekly 才更新 `MEMORY.md` 会太慢
- daily 直接写全量分类会太吵、难治理

决策：

- daily 维护 `MEMORY.md#近期重要更新（自动，滚动7天）`：
  - 只放最稳定、最可复用的少量条目
  - 控制上限（<=30条、最近7天、每次新增<=5）
- weekly 再把“已证实”的条目晋升进正式分类，并清理滚动区

## 并发写入：锁

daily 与 weekly 都可能写 `MEMORY.md`。

决策：

- 使用 `scripts/lockfile.py` 实现简单锁
- daily/weekly 共用同一把锁

## weekly 可靠性：at-least-once gate

“每周一次”的 cron 很容易被机器睡眠错过。

决策：

- weekly cron 设为每天固定时间触发
- 通过 `scripts/weekly_gate.py` 控制：
  - 本周（ISO week）未成功跑过 → 执行并 mark
  - 已跑过 → skipped

并且根据距离上次成功的天数动态扩大 lookback window（<=30天），避免漏巩固。

## 仍然保持轻结构 + 强提炼

我们不走完全结构化事件系统（schema-heavy），原因是复杂度高、维护成本高。

我们只引入“最小必要的可靠性机制”：

- 游标（offset）
- 锁（lockfile）
- gate（weekly at-least-once）
- 过滤（anti-recursion + de-noise）

然后让 LLM 在干净输入上做强提炼。
