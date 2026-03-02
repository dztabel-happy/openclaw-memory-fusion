# 故障排除

## 1) Cron “看不到主会话 / 没写入 / 漏数据”

### 症状

- cron 执行了，但写入为空
- 或者看起来“没有新对话”

### 常见根因

- 仍在使用 `sessions_list/sessions_history` 获取对话（isolated cron 可见性受限）

### 解决

改为扫描 session JSONL：

- `~/.openclaw/agents/<agent>/sessions/*.jsonl`
- `~/.openclaw/agents/<agent>/sessions/*.jsonl.reset.*`

并用 `scripts/scan_sessions_incremental.py` + `memory/_state/*.json` 做增量游标。

## 2) 防套娃（递归污染）验证

如果你看到记忆文件里出现：

- cron prompt 本身
- `memory-hourly ok` / `memory-daily ok` / `memory-weekly ok`

说明过滤不完整。

检查：

- cron prompt 第一行是否以 `[cron:` 开头
- 扫描器是否忽略 cron sessions + 忽略 `memory-*.ok` / `NO_REPLY` + 忽略 tool/system

验证：

- 反复跑 hourly，应该最终收敛到 `events: 0`。

## 3) Telegram 群不响应 / 群里看不到 bot

### 说明

群聊“收消息”门控与 cron “投递通知”是两件事：

- 收消息：`channels.telegram.groupPolicy/groupAllowFrom/groups`
- 投递通知：cron job 的 `delivery.to`

### 官方配置参考

请以 OpenClaw 官方文档为准（不同版本字段可能调整）。配置入口在 `~/.openclaw/openclaw.json`。

示例（来自 docs 的结构风格，使用占位符）：

```json5
{
  channels: {
    telegram: {
      groupPolicy: "allowlist",
      groupAllowFrom: ["tg:<YOUR_TELEGRAM_USER_ID>", "@alice"],
      groups: {
        "<GROUP_CHAT_ID>": { enabled: true, requireMention: true }
      }
    }
  }
}
```

> 不要把真实 chat id / user id 提交到仓库里。

## 4) daily/weekly 写 `MEMORY.md` 出现覆盖/冲突

### 症状

- `MEMORY.md` 被回滚
- 两次写入互相覆盖

### 解决

使用锁：

- `scripts/lockfile.py acquire/release`
- daily 与 weekly 共用同一把锁（例如 `memory/_state/MEMORY.lock`）

并建议把 daily 与 weekly 的执行时间拉开（例如 daily 23:30，weekly 00:20）。

## 5) weekly 不稳定 / 机器睡眠错过周任务

### 解决

采用“每天触发 + gate”：

- `scripts/weekly_gate.py --mode check/mark`

weekly cron 每天触发一次，但本周如果已成功跑过就 `skipped`。错过周一也能在本周补跑。

## 6) `scan_sessions_incremental.py` 在 `| head` 下报 BrokenPipe

这是正常的：下游提前关闭 stdout。

当前版本已经吞掉 `BrokenPipeError` 并正常退出。

## 7) OpenAI Responses streaming 崩溃（SSE 空 data）

### 症状

- `Unexpected end of JSON input`
- `gateway.err.log` 同时出现 `event: response.created` 但 `data:` 为空的特征

### 解决

运行补丁脚本（升级后可能需要重打）：

```bash
bash scripts/patch-openai-sse-empty-data.sh --restart
```
