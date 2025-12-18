# Claude Island 日志系统文档

## 概述

Claude Island 应用采用多层次的日志系统，记录从 Neovim RPC 通信到 Swift 端会话管理的所有关键操作。本文档详细说明了日志系统的架构、实现和使用方法。

## 日志系统架构

### 1. Lua 端日志 (Neovim 插件)

**文件位置**: `~/.claude-island-rpc.log`

**实现方式**: 在 `~/.vim/plugged/claudecode.nvim/lua/claudecode/island_rpc.lua` 中使用 `file_log()` 函数

```lua
local function file_log(level, trace_id, message)
  local timestamp = os.date("%Y-%m-%d %H:%M:%S")
  local log_msg = string.format("[%s] [%s] [%s] %s", level, timestamp, trace_id, message)

  -- Write to log file only - DO NOT use vim.notify to avoid polluting RPC response
  local log_path = os.getenv("HOME") .. "/.claude-island-rpc.log"
  local file = io.open(log_path, "a")
  if file then
    file:write(log_msg .. "\n")
    file:flush()
    file:close()
  end
end
```

**日志级别**:
- `INFO`: 重要操作信息
- `DEBUG`: 调试详细信息
- `WARNING`: 警告信息
- `ERROR`: 错误信息

**使用场景**:
- Neovim RPC action 处理 (`list_terminals`, `send_text`)
- 终端检测和匹配过程
- 错误和异常情况

**示例日志**:
```bash
[INFO] [2025-12-18 20:01:44] [5BE65C19] Handling list_terminals action
[DEBUG] [2025-12-18 20:01:49] [5BE65C19] Found 4 terminal buffers
[DEBUG] [2025-12-18 20:01:49] [5BE65C19] Terminal: bufnr=11, channel=13, name=term://.../96036:claude --dangerously-skip-permissions, is_claude_code=true
[INFO] [2025-12-18 20:02:22] [499FB476] Using specified target_bufnr: 11
```

**监控命令**:
```bash
tail -f ~/.claude-island-rpc.log
```

---

### 2. Swift 端日志 (应用层)

#### 2.1 当前实现: os.log

**系统**: macOS Unified Logging System

**实现方式**: 使用 `os.log.OSLog` 和 `Logger`

```swift
import os.log

private static let logger = Logger(subsystem: "com.claudeisland", category: "NeovimBridge")

Self.logger.info("sendText with targetBufnr: \(targetBufnr ?? -1) for session \(sessionState.sessionId.prefix(8))")
```

**日志路径**: 系统日志 (需要通过 `log stream` 查看)

**日志级别**:
- `debug`: 调试信息
- `info`: 一般信息
- `warning`: 警告信息
- `error`: 错误信息

**使用场景**:
- NeovimBridge 方法调用
- SessionStore 状态变更
- 错误和异常处理

**查看命令**:
```bash
# 查看所有日志
log stream --predicate 'subsystem == "com.claudeisland"' --info

# 查看特定类别日志
log stream --predicate 'subsystem == "com.claudeisland" AND category == "NeovimBridge"' --info

# 查看最近5分钟日志
log show --predicate 'subsystem == "com.claudeisland"' --last 5m --info
```

#### 2.2 历史实现: FileLogger (已删除)

**提交**: fc9ef7f (2025-12-18 00:55) - "refactor(logging): 移除调试日志记录"

**删除原因**: 清理调试阶段代码，保留系统日志用于生产环境

**删除的文件**:
- `ClaudeIsland/Utils/FileLogger.swift` (116行)
- NeovimBridge.swift 中的 28 行日志调用
- NeovimHealthChecker.swift 中的 12 行日志调用
- ChatView.swift 中的 33 行日志调用

**总计删除**: 189 行代码

**特点**:
- 专用文件日志系统
- 写入路径: `~/Library/Logs/ClaudeIsland/debug.log` 或项目目录 `/log/debug.log`
- 每次应用启动时清空日志文件
- 线程安全的文件写入

---

#### 2.3 当前实现: DebugFileLogger（开发调试文件日志）

为便于快速定位 “会话识别/过滤/动画触发” 等问题，现已重新引入一个**开发调试专用**的文件日志系统：`DebugFileLogger`。

**日志文件名（固定）**: `debug_log.txt`  
**默认存储位置**: 仓库根目录（例如 `.../claude-island/debug_log.txt`）  
**覆盖策略**: App 每次启动时删除旧文件，生成全新日志  
**编码**: UTF-8  
**时间戳**: `[YYYY-MM-DD HH:MM:SS.mmm]` 毫秒级  

**实现位置**:
- `ClaudeIsland/Utilities/DebugFileLogger.swift`
- 启动写入：`ClaudeIsland/App/AppDelegate.swift`（在单例检查前写入，保证“启动即落盘”）

**路径解析优先级**（保证 GUI App 启动时也能写入）：
1. 环境变量 `CLAUDE_ISLAND_DEBUG_LOG_DIR`（推荐：在 Xcode Scheme 里配置为项目根目录）
2. 自动推导仓库根目录（通过 `#filePath` 反推，并校验存在 `ClaudeIsland.xcodeproj`）
3. 当前工作目录（若可写）
4. 兜底：`~/Library/Logs/ClaudeIsland/`（始终可写）

**日志内容覆盖范围（示例）**：
- App 启动/退出（`[START]` / `[END]`）
- HookSocketServer 收到的 hook 事件（sessionId/event/status/pid/tty/tmuxPaneId/tool/toolUseId）
- SessionStore 处理流程（进程树、Neovim 识别、nvimPid、listenAddress 解析耗时）
- sessions 发布给 UI 的可见列表摘要（用于排查“过滤后仍触发 UI 动效”）

**敏感信息处理**：
- 环境变量日志会按 key 进行脱敏（包含 `TOKEN/KEY/SECRET/PASSWORD/AUTH/AUTHORIZATION` 的键会输出 `[REDACTED]`）
- 超长内容会截断（当前实现保留前 2000 字符预览）

**查看方式**：
```bash
tail -f debug_log.txt
```

---

## 当前日志实现详情

### Lua 端日志使用

#### 1. 在 island_rpc.lua 中添加日志

```lua
-- 在函数开始时记录
file_log("INFO", trace_id, "Handling list_terminals action")

-- 记录关键数据
file_log("DEBUG", trace_id, string.format("Found %d terminal buffers", #terminals))

-- 记录详细终端信息
for _, t in ipairs(terminals) do
  file_log("DEBUG", trace_id, string.format(
    "Terminal: bufnr=%d, channel=%d, name=%s, is_claude_code=%s",
    t.bufnr, t.channel or -1, t.name, tostring(t.is_claude_code)
  ))
end

-- 记录重要决策
file_log("INFO", trace_id, string.format("Using specified target_bufnr: %d", bufnr))
file_log("INFO", trace_id, string.format("Fallback to active terminal: %d", bufnr or -1))
```

#### 2. 日志最佳实践

**何时记录**:
- ✅ 重要操作开始/结束
- ✅ 关键数据变化
- ✅ 错误和异常
- ✅ 决策点和分支逻辑

**何时不记录**:
- ❌ 每行代码都记录
- ❌ 敏感信息 (密码、token等)
- ❌ 大量循环中的每次迭代

**日志格式**:
```lua
[LEVEL] [YYYY-MM-DD HH:MM:SS] [trace_id] message
```

### Swift 端日志使用

#### 1. 在 NeovimBridge.swift 中添加日志

```swift
import os.log

private static let logger = Logger(subsystem: "com.claudeisland", category: "NeovimBridge")

func sendText(...) async throws -> Int {
    // 记录输入参数
    Self.logger.info("sendText with targetBufnr: \(targetBufnr ?? -1) for session \(sessionState.sessionId.prefix(8))")

    // 记录错误
    guard !text.isEmpty else {
        Self.logger.warning("Attempted to send empty text for session \(sessionState.sessionId.prefix(8))")
        throw NeovimBridgeError.emptyText
    }

    // 记录结果
    Self.logger.debug("Found \(terminals.count) terminals for session \(sessionState.sessionId.prefix(8))")
}
```

#### 2. 在 SessionStore.swift 中添加日志

```swift
private func processUpdateNeovimTarget(...) async {
    // 记录状态变更
    Self.logger.info("Updated Neovim terminal target for session \(sessionId.prefix(8)): bufnr=\(bufnr), channel=\(channel), name=\(name ?? "nil"))")

    // 记录成功/失败
    Self.logger.info("Associated session \(session.sessionId.prefix(8)) with terminal bufnr=\(terminal.bufnr)")
    Self.logger.error("Failed to associate session \(session.sessionId.prefix(8)) with terminal: \(error.localizedDescription)")
}
```

#### 3. 日志记录手法 (Logging Patterns)

##### 3.1 过滤和条件逻辑日志

当实现条件过滤逻辑时，需要清晰记录过滤的原因和结果：

```swift
// ✅ 清晰说明过滤逻辑
private var sortedInstances: [SessionState] {
    // Filter out sessions running directly in neovim terminal (not via RPC)
    // Keep sessions that:
    // 1. Are in tmux
    // 2. Are connected via neovim RPC (claude code.nvim plugin)
    // 3. Are not in neovim at all
    let filteredInstances = sessionMonitor.instances.filter { session in
        // Only filter out if in neovim AND has no RPC connection (direct terminal usage)
        !(session.isInNeovim && session.nvimListenAddress == nil)
    }
}
```

**关键点**:
- 在过滤代码上方添加详细注释说明过滤目的
- 在条件判断中添加内联注释解释逻辑
- 避免只记录 `debug` 级别的过滤结果 (除非调试特定问题)

##### 3.2 状态检测和元数据日志

记录状态检测过程，帮助理解为什么某个会话被过滤或保留：

```swift
// 在 SessionStore.swift 中
if let nvimPid = ProcessTreeBuilder.shared.findNeovimParent(pid: pid, tree: tree) {
    session.isInNeovim = true
    session.nvimPid = nvimPid
    Self.logger.info("🟢 Detected Neovim environment - session=\(sessionId.prefix(8)), neovimPid=\(nvimPid)")
} else {
    Self.logger.debug("📥 Not running in Neovim")
}
```

**使用表情符号作为视觉标识**:
- 🟢: 检测到 neovim 环境
- 📥: 一般信息/输入
- 🔍: 搜索/查找操作
- ❌: 错误/失败
- ✅: 成功/通过

##### 3.3 决策点日志

在代码的关键决策点记录日志，帮助追踪程序流程：

```swift
// ❌ 不明确
if session.isInNeovim && session.nvimListenAddress == nil {
    continue
}

// ✅ 明确说明决策逻辑
// Only filter out if in neovim AND has no RPC connection (direct terminal usage)
if session.isInNeovim && session.nvimListenAddress == nil {
    // Skip showing sessions that are directly running in neovim terminal
    continue
}
```

##### 3.4 批量操作日志

对集合进行过滤或转换时，记录统计信息：

```swift
let filteredInstances = sessionMonitor.instances.filter { session in
    !(session.isInNeovim && session.nvimListenAddress == nil)
}

// 在 debug 级别记录过滤结果 (可选)
Self.logger.debug("Filtered \(sessionMonitor.instances.count) sessions to \(filteredInstances.count) visible sessions")
```

##### 3.5 内联注释式日志

在复杂的布尔逻辑旁边添加解释性注释：

```swift
// ✅ 清晰的内联注释
let shouldFilter = !(session.isInNeovim && session.nvimListenAddress == nil)
// Only filter neovim terminal sessions without RPC connection

if shouldFilter {
    continue
}

// ❌ 模糊的注释
let filtered = filterLogic(session)
// Apply filter logic
```

##### 3.6 早期返回模式日志

在函数开始处记录进入条件和早期返回的原因：

```swift
func processSession(_ session: SessionState) {
    // 记录输入
    Self.logger.debug("Processing session \(session.sessionId.prefix(8))")

    // 早期返回检查
    guard !session.isInNeovim || session.nvimListenAddress != nil else {
        Self.logger.debug("Skipping session \(session.sessionId.prefix(8)): direct neovim terminal usage")
        return
    }

    // 主要逻辑
    // ...
}
```

#### 4. 日志最佳实践

**日志类别 (category)**:
- `NeovimBridge`: Neovim 通信相关
- `Session`: 会话管理相关
- `HealthCheck`: 健康检查相关
- `UI`: 用户界面相关
- `Filter`: 过滤逻辑相关 (新增)

**日志级别使用**:
- `debug`: 详细的调试信息 (默认不显示)
- `info`: 一般信息性消息
- `warning`: 警告信息 (可能的问题)
- `error`: 错误信息 (需要关注的问题)

---

## 调试指南

### 1. 启用详细日志

#### Lua 端
Lua 端日志默认启用，所有 `file_log()` 调用都会写入文件。

#### Swift 端
默认情况下，`debug` 级别的日志不会显示。启用方法：

```bash
# 启用所有级别日志
log stream --predicate 'subsystem == "com.claudeisland"' --level debug

# 只显示错误和警告
log stream --predicate 'subsystem == "com.claudeisland"' --level error
```

### 2. 实时监控

#### 监控所有日志
```bash
# 开终端1: 监控 Lua 端日志
tail -f ~/.claude-island-rpc.log

# 开终端2: 监控 Swift 端日志
log stream --predicate 'subsystem == "com.claudeisland"' --info
```

#### 过滤特定日志
```bash
# 只显示 NeovimBridge 相关
log stream --predicate 'subsystem == "com.claudeisland" AND category == "NeovimBridge"' --info

# 只显示错误
log stream --predicate 'subsystem == "com.claudeisland" AND level >= error' --info

# 只显示过滤相关日志
log stream --predicate 'subsystem == "com.claudeisland" AND category == "Filter"' --info
```

### 3. 分析日志

#### 查看历史日志
```bash
# 查看最近1小时日志
log show --predicate 'subsystem == "com.claudeisland"' --last 1h --info

# 保存日志到文件
log show --predicate 'subsystem == "com.claudeisland"' --last 1h --info > /tmp/claude-island-logs.txt
```

#### 搜索特定内容
```bash
# 搜索包含 "target_bufnr" 的日志
grep "target_bufnr" ~/.claude-island-rpc.log

# 搜索包含 "ERROR" 的 Swift 日志
log show --predicate 'subsystem == "com.claudeisland" AND level >= error' --last 1h --info

# 搜索过滤相关的日志
log show --predicate 'subsystem == "com.claudeisland" AND category == "Filter"' --last 1h --info
```

---

## 故障排除

### 问题 1: Swift 端日志不显示

**症状**: `log stream` 没有输出或输出很少

**可能原因**:
1. 日志级别限制 (debug 默认不显示)
2. 系统隐私设置阻止日志输出
3. 应用权限问题

**解决方案**:
```bash
# 1. 指定日志级别
log stream --predicate 'subsystem == "com.claudeisland"' --level debug --info

# 2. 检查日志系统状态
sudo log config --mode level:debug --subsystem com.claudeisland

# 3. 重启日志系统
sudo killall -HUP syslogd
```

### 问题 2: Lua 端日志不更新

**症状**: `~/.claude-island-rpc.log` 没有新内容

**可能原因**:
1. Neovim RPC 调用未发生
2. 文件权限问题
3. 文件被意外清空

**解决方案**:
```bash
# 1. 检查文件权限
ls -la ~/.claude-island-rpc.log

# 2. 检查 Neovim 是否运行
ps aux | grep nvim

# 3. 手动测试 RPC 调用
# 在 Neovim 中运行 :lua require('claudecode.island_rpc').handle_rpc({action="ping"})
```

### 问题 3: 日志太多难以阅读

**解决方案**:
```bash
# 1. 按时间过滤
log show --predicate 'subsystem == "com.claudeisland"' --last 10m --info

# 2. 按级别过滤
log stream --predicate 'subsystem == "com.claudeisland" AND level >= info' --info

# 3. 使用 grep 过滤
log stream --predicate 'subsystem == "com.claudeisland"' --info | grep -E "(ERROR|WARN)"

# 4. 按类别过滤 (过滤逻辑专用)
log stream --predicate 'subsystem == "com.claudeisland" AND category == "Filter"' --info
```

### 问题 4: 过滤逻辑不工作

**症状**: neovim terminal 中的会话仍然出现在列表中

**诊断步骤**:
```bash
# 1. 启用 debug 日志查看过滤过程
log stream --predicate 'subsystem == "com.claudeisland" AND category == "Filter"' --level debug --info

# 2. 查看会话状态检测日志
log stream --predicate 'subsystem == "com.claudeisland" AND category == "Session"' --info

# 3. 检查会话的 isInNeovim 和 nvimListenAddress 值
# 在代码中添加临时日志:
Self.logger.info("Session \(sessionId): isInNeovim=\(session.isInNeovim), nvimListenAddress=\(session.nvimListenAddress ?? "nil")")
```

---

## 日志性能优化

### 1. 避免过度日志记录

**原则**:
- 只记录必要信息
- 避免在高频循环中记录
- 使用适当的日志级别

**示例**:
```swift
// ❌ 错误: 每次循环都记录
for item in items {
    Self.logger.info("Processing item: \(item)")  // 不要这样做
}

// ✅ 正确: 记录摘要
Self.logger.info("Processing \(items.count) items")

// ✅ 正确: 只在 debug 级别记录详细信息
for item in items {
    Self.logger.debug("Processing item: \(item)")  // debug 级别，默认不显示
}
```

### 2. 异步日志记录

Lua 端使用文件追加 (阻塞)，Swift 端使用系统日志 (异步)。

对于高频场景，考虑批量记录或采样记录。

### 3. 日志轮转

当前实现没有日志轮转，长时间运行可能导致文件过大。

**建议**:
- 定期清理旧日志
- 限制日志文件大小
- 压缩归档历史日志

---

## 最佳实践总结

### Do's ✅
- 使用有意义的日志消息
- 包含 trace_id 便于追踪
- 使用适当的日志级别
- 记录关键决策和状态变更
- 在错误时记录详细信息
- **在过滤逻辑中添加清晰的注释** (新增)
- **使用表情符号作为视觉标识** (新增)
- **记录批量操作的统计信息** (新增)

### Don'ts ❌
- 不要记录敏感信息
- 不要在高频循环中记录
- 不要使用日志记录用户输入 (安全风险)
- 不要忘记清理调试日志
- 不要混合使用多种日志系统
- **不要在过滤逻辑中记录过多 debug 信息** (新增)
- **不要使用模糊的注释** (新增)

### 调试工作流
1. **识别问题**: 查看错误日志
2. **重现问题**: 启用 debug 日志
3. **追踪问题**: 使用 trace_id
4. **分析日志**: 查看关键操作
5. **修复问题**: 根据日志定位代码
6. **验证修复**: 确认日志显示正常
7. **记录修复**: 在代码中添加适当的日志和注释 (新增)

---

## 参考资料

- [Apple Unified Logging Guide](https://developer.apple.com/documentation/os/logging)
- [Swift os.log Documentation](https://developer.apple.com/documentation/os/oslog)
- [Lua File I/O](https://www.lua.org/manual/5.4/manual.html#6.8)
- [Neovim Lua API](https://neovim.io/doc/user/lua.html)

---

**文档版本**: v1.0
**最后更新**: 2025-12-18
**维护者**: Claude Island 开发团队
