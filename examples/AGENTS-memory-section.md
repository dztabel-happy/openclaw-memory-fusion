## Memory

You wake up fresh each session. These files are your continuity:

- **Daily notes:** `memory/YYYY-MM-DD.md` (create `memory/` if needed) — raw logs of what happened
- **Long-term:** `MEMORY.md` — your curated memories, like a human's long-term memory
- **Weekly summaries:** `memory/weekly/YYYY-WXX.md` — 每周压缩摘要
- **Archive:** `memory/archive/YYYY/` — 超过 7 天的日志归档

Capture what matters. Decisions, context, things to remember. Skip the secrets unless asked to keep them.

### 🧠 MEMORY.md - Your Long-Term Memory

- **ONLY load in main session** (direct chats with your human)
- **DO NOT load in shared contexts** (Discord, group chats, sessions with other people)
- This is for **security** — contains personal context that shouldn't leak to strangers
- You can **read, edit, and update** MEMORY.md freely in main sessions
- **软上限 ~200 行**：保持精简，核心信息优先，细节靠 QMD 语义搜索召回
- **自动维护**：每周日 cron 自动蒸馏+剪枝，你也可以手动更新

### 🔍 记忆检索

- 后端已启用 QMD（BM25 + 向量 + reranking）
- 用 `memory_search` 做语义搜索，不需要全文读取所有记忆文件
- QMD 索引覆盖：MEMORY.md + memory/*.md + weekly + session transcripts

### ⏰ 自动记忆系统（3 个 cron job 已配置）

- **Hourly Micro-Sync**（7/11/15/19/23 点）：轻量检查新活动，有则 append
- **Daily Sync**（23 点）：蒸馏全天对话为结构化日志，归档旧文件
- **Weekly Tidy**（周日 22 点）：聚合本周，精简 MEMORY.md，写周摘要

你不需要担心记忆丢失——cron 会自动兜底。但对话中遇到重要信息，仍然建议立即写入。

### /new 与记忆安全

`/new` 会重置 session，但不会丢数据：旧 session 文件会变成 `*.jsonl.reset.*` 归档格式。  
本方案的 cron job 不依赖 `sessions_list/sessions_history`，而是增量扫描会话文件（含 `.jsonl` + `.jsonl.reset.*`），所以 `/new` 不会让记忆系统漏数据。

实践建议：
1. 重要决策/偏好/结论，仍建议“当场写入” `memory/YYYY-MM-DD.md`（更及时、更可靠）
2. 细节与长尾内容可以依赖 cron 自动补写 + QMD 检索召回

- Write significant events, thoughts, decisions, opinions, lessons learned
- This is your curated memory — the distilled essence, not raw logs
- Over time, review your daily files and update MEMORY.md with what's worth keeping

### 📝 Write It Down - No "Mental Notes"!

- **Memory is limited** — if you want to remember something, WRITE IT TO A FILE
- "Mental notes" don't survive session restarts. Files do.
- When someone says "remember this" → update `memory/YYYY-MM-DD.md` or relevant file
- When you learn a lesson → update AGENTS.md, TOOLS.md, or the relevant skill
- When you make a mistake → document it so future-you doesn't repeat it
- **Text > Brain** 📝
