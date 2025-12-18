# Neovim Terminal 过滤需求文档

## 需求背景

用户希望在 Claude Island 中实现智能会话过滤，根据不同的启动方式来决定是否在 Dynamic Island 会话列表中显示会话。

## 过滤需求

### 场景 1: 过滤掉 ❌
**在 neovim terminal 中直接运行 claude**
- 在 neovim 的 terminal buffer 中输入 `claude` 命令启动的会话
- 这些会话不应该出现在 Dynamic Island 的会话列表中
- 原因：用户不希望在动态岛中看到这些"内部"会话

### 场景 2: 保留 ✅
**通过 claude code.nvim 插件 RPC 方式启动的会话**
- 使用 claude code.nvim 插件启动的会话
- 通过 RPC 连接到 neovim 的会话
- 这些会话应该出现在 Dynamic Island 中，以便用户可以批准/拒绝操作

### 场景 3: 保留 ✅
**tmux 中的会话**
- 在 tmux session 中运行的 claude code
- 应该正常显示在 Dynamic Island 中

### 场景 4: 保留 ✅
**普通终端中的会话**
- 在 iTerm2、Terminal.app 等普通终端中运行的 claude code
- 应该正常显示在 Dynamic Island 中

## 实现方案

### 识别逻辑

通过会话状态中的两个关键字段来区分：

1. **`isInNeovim`**: 表示会话是否在 neovim 环境中运行
2. **`nvimListenAddress`**: 表示是否有 RPC 连接到 neovim

### 过滤条件

```swift
let filteredInstances = sessionMonitor.instances.filter { session in
    // Only filter out if in neovim AND has no RPC connection (direct terminal usage)
    !(session.isInNeovim && session.nvimListenAddress == nil)
}
```

### 逻辑解释

- **直接过滤**: `isInNeovim=true` 且 `nvimListenAddress=nil`
  - 这表示会话在 neovim terminal 中直接运行，没有 RPC 连接
  - 这种情况应该被过滤掉

- **保留**: `isInNeovim=true` 且 `nvimListenAddress!=nil`
  - 这表示会话通过 claude code.nvim 插件 RPC 启动
  - 应该保留在列表中

- **保留**: `isInNeovim=false`
  - 这表示会话不在 neovim 中运行
  - 包括 tmux、普通终端等所有其他情况
  - 应该保留在列表中

## 代码位置

**文件**: `ClaudeIsland/UI/Views/ClaudeInstancesView.swift`
**方法**: `sortedInstances` (第 43-66 行)

## 测试场景

### 测试场景 1: neovim terminal 直接运行
```bash
# 在 neovim terminal 中
:terminal
claude
```
**期望结果**: ❌ 不出现在会话列表中

### 测试场景 2: claude code.nvim 插件
```vim
" 在 neovim 中
:ClaudeCode
```
**期望结果**: ✅ 出现在会话列表中

### 测试场景 3: tmux 会话
```bash
# 在 tmux 中
claude
```
**期望结果**: ✅ 出现在会话列表中

### 测试场景 4: 普通终端
```bash
# 在 iTerm2 或 Terminal.app 中
claude
```
**期望结果**: ✅ 出现在会话列表中

## 注意事项

1. **向后兼容**: 此修改不会影响现有功能，只是添加了过滤逻辑
2. **实时生效**: 过滤在 UI 层面进行，不会影响后端会话管理
3. **性能影响**: 过滤操作在每次渲染前执行，性能开销可忽略不计
4. **可扩展性**: 如果将来需要添加更多过滤条件，可以轻松扩展此逻辑

## 相关文件

- `ClaudeIsland/UI/Views/ClaudeInstancesView.swift`: 实现过滤逻辑
- `ClaudeIsland/Models/SessionState.swift`: 定义会话状态模型
- `ClaudeIsland/Services/State/SessionStore.swift`: 会话管理服务
