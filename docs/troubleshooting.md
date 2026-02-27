# 故障排除

## QMD 相关

### QMD 安装失败（bun build 报错）

QMD 用 TypeScript 编写，不需要 `tsc` 编译。直接用 `bun` 运行源码：

```bash
# 不要用 bun run build，直接创建 wrapper
cat > ~/.bun/bin/qmd << 'EOF'
#!/bin/bash
exec bun ~/.bun/install/global/node_modules/@tobilu/qmd/src/qmd.ts "$@"
EOF
chmod +x ~/.bun/bin/qmd
```

### QMD 命令找不到

确保 `~/.bun/bin` 在 PATH 中：

```bash
echo 'export PATH="$HOME/.bun/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### memory_search 返回空结果

#### 原因 1：QMD 从未建索引

OpenClaw 配置了 `includeDefaultMemory: true`，但**不会自动创建 QMD collection**。需要手动初始化：

```bash
cd ~/.openclaw/workspace

# 1. 创建 collection（索引所有 md 文件）
qmd collection add .

# 2. 生成向量嵌入（可选，BM25 搜索已可用）
qmd embed

# 3. 验证
qmd status
# 应显示: Total: N files indexed, Vectors: M embedded
```

#### 原因 2：向量 embed 失败（Bun SQLite 限制）

**问题**：Bun 内置 SQLite 不支持 `loadExtension`，导致 sqlite-vec 扩展无法加载。

**表现**：`qmd embed` 报错 "sqlite-vec is not available. Vector operations require a SQLite build with extension loading support."

**解决**：使用 npm 版的 qmd（Node.js + better-sqlite3）：

```bash
# 安装 npm 版 qmd
npm install -g @tobilu/qmd

# 修改 openclaw.json 配置
# 将 "command": "/Users/abel/.bun/bin/qmd" 改为：
"command": "/Users/abel/.npm-global/bin/qmd"

# 重启 gateway
openclaw gateway restart
```

#### 原因 3：session transcripts 未被索引

检查 `retentionDays` 配置：

```bash
# 检查当前值
grep retentionDays ~/.openclaw/openclaw.json

# 如果是 0，改为 30（保留 30 天）
# "memory": { "qmd": { "sessions": { "retentionDays": 30 } } }
```

**注意**：`0` 表示"立即过期"，不是"永不过期"。

## Cron 相关

### Cron job 没有执行

```bash
# 检查 job 状态
openclaw cron list

# 查看运行历史
openclaw cron runs --id <job-id>

# 手动触发测试
openclaw cron run <job-id>
```

### Cron job 执行但没写入文件

可能是模型没有正确调用工具。尝试：

1. 手动运行查看输出：`openclaw cron run <job-id>`
2. 检查模型是否有文件写入权限
3. 换一个更强的模型测试

### Cron 格式错误

OpenClaw 使用标准 5-field cron 表达式：

```
分钟 小时 日 月 星期
0    23   *  *  *      = 每天 23:00
0    22   *  *  0      = 每周日 22:00
0    10,13,16,19,22 * * * = 每天 10/13/16/19/22 点
```

## Gateway 相关

### 配置文件格式错误

```bash
# 检查配置
openclaw doctor

# 自动修复
openclaw doctor --fix
```

### gateway restart 超时

这是正常的——restart 命令有时会超时断开，但 gateway 实际已重启：

```bash
# 验证 gateway 状态
openclaw gateway status
```

## 记忆文件相关

### memory/YYYY-MM-DD.md 命名不一致

之前可能有带时间戳的文件（如 `2026-02-22-1418.md`），这是 session-memory hook 生成的。可以手动整理：

```bash
# 查看现有文件
ls ~/.openclaw/workspace/memory/

# 考虑关闭 session-memory hook 避免冲突
# 在 openclaw.json 的 hooks.internal.entries 中：
# "session-memory": { "enabled": false }
```

### MEMORY.md 超过 200 行

这是软上限，不会出错。但建议：

1. 等周日 weekly cron 自动剪枝
2. 或手动精简：移除过时信息，合并重复项
3. 细节内容靠 QMD 语义搜索召回，不需要全放 MEMORY.md

### Cron job 报 "LLM request timed out"

**问题**：cron job 执行报超时，但模型和 timeout 配置跟其他正常运行的 job 相同。

**排查步骤**：

```bash
# 查看详细错误
openclaw cron list --json | python3 -c "
import sys,json
data=json.load(sys.stdin)
for j in data.get('jobs',[]):
    s = j.get('state',{})
    if s.get('lastRunStatus') == 'error':
        print(f\"{j['name']}: {s.get('lastError')}\")"
```

**常见根因：`sessions_list` 未限制范围**

如果 cron prompt 中调用 `sessions_list` 没有指定 `activeMinutes` 参数，会返回**所有 session** 的数据，token 量可能极大，导致请求超时。

**修复**：在 prompt 中指定合理的时间范围：

```bash
# Hourly 用 360 分钟（6 小时）
sessions_list(activeMinutes=360)

# Daily 用 1440 分钟（24 小时）
sessions_list(activeMinutes=1440)
```

```bash
# 修改 cron prompt
openclaw cron edit <job-id> --message '新的 prompt 内容...'

# 手动触发验证
openclaw cron run <job-id>
```

**验证修复**：

```bash
openclaw cron list --json | python3 -c "
import sys,json
data=json.load(sys.stdin)
for j in data.get('jobs',[]):
    if j['name'] == 'memory-hourly':
        s = j.get('state',{})
        print(f\"status: {s.get('lastRunStatus')}\")
        print(f\"consecutiveErrors: {s.get('consecutiveErrors')}\")"
```
