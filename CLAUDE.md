# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

**Claude Island** 是一个 macOS 菜单栏应用，为 Claude Code CLI 提供 Dynamic Island 风格的实时监控界面。该应用通过 Unix 套接字与 Claude Code 的钩子通信，实现：

- 动态 Notch UI 显示（类似 MacBook 的 Dynamic Island）
- 实时监控多个 Claude Code 会话
- 工具执行权限审批（可直接在 notch 中批准/拒绝）
- 聊天历史查看（支持 Markdown 渲染）
- 自动安装钩子

## 项目架构

### 模块结构

项目采用清晰的模块化架构：

```
ClaudeIsland/
├── App/                    # 应用入口和生命周期管理
│   ├── ClaudeIslandApp.swift      # 主应用入口
│   ├── AppDelegate.swift          # App 委托
│   ├── WindowManager.swift        # 窗口管理
│   └── ScreenObserver.swift       # 屏幕变化观察
│
├── Core/                   # 核心域和状态管理
│   ├── Settings.swift             # 用户设置（声音、清理等）
│   ├── NotchGeometry.swift        # Notch 几何布局
│   ├── NotchViewModel.swift       # Notch 视图模型
│   ├── NotchActivityCoordinator.swift  # 活动协调
│   ├── ScreenSelector.swift       # 屏幕选择
│   ├── SoundSelector.swift        # 声音选择
│   └── Ext+NSScreen.swift         # NSScreen 扩展
│
├── Services/               # 外部集成和业务服务
│   ├── Hooks/              # 钩子安装和套接字服务
│   ├── Session/            # 会话监控和解析
│   ├── State/              # 状态管理和事件处理
│   ├── Tmux/               # Tmux 集成
│   ├── Neovim/             # Neovim 桥接
│   ├── Chat/               # 聊天历史管理
│   ├── Screenshot/         # 截图服务
│   ├── Window/             # 窗口管理
│   ├── IDE/                # IDE RPC 服务
│   └── Update/             # 更新管理（Sparkle）
│
├── UI/                     # SwiftUI 视图和组件
│   ├── Views/              # 主视图
│   ├── Components/         # 可复用组件
│   └── Window/             # 窗口和控制器
│
├── Models/                 # 数据模型
│   ├── SessionEvent.swift         # 会话事件
│   ├── SessionState.swift         # 会话状态
│   ├── SessionPhase.swift         # 会话阶段
│   ├── ChatMessage.swift          # 聊天消息
│   ├── ToolResultData.swift       # 工具结果
│   └── ...
│
└── Utilities/              # 工具类和辅助功能
```

### 关键架构模式

**1. 事件驱动架构**
- 所有状态变化通过 `SessionEvent` 枚举统一处理
- `SessionStore` 作为状态管理中心
- 通过 Combine 框架实现响应式数据流

**2. 服务分层**
- `ClaudeSessionMonitor` 负责 UI 绑定和监控生命周期
- `HookSocketServer` 处理与 Claude Code 的通信
- 各服务模块独立，负责特定功能域

**3. SwiftUI 架构**
- 视图保持简单，状态管理在视图模型中
- 使用 `@MainActor` 确保 UI 线程安全
- 通过 `@Published` 和 `ObservableObject` 实现数据绑定

## 常用开发命令

### 构建和运行

```bash
# 在 Xcode 中打开
open ClaudeIsland.xcodeproj

# Debug 构建（CLI）
xcodebuild -scheme ClaudeIsland -configuration Debug build

# Release 构建（CLI）
xcodebuild -scheme ClaudeIsland -configuration Release build

# 直接运行
xcodebuild -scheme ClaudeIsland run
```

### 发布和部署

```bash
# 构建并导出应用（到 build/export/）
./scripts/build.sh

# 创建发布包和 DMG（需要 Apple 签名凭据）
./scripts/create-release.sh

# 生成 Sparkle 签名密钥（一次性，密钥存储在 .sparkle-keys/，勿提交）
./scripts/generate-keys.sh
```

### 调试和日志

```bash
# 查看应用日志
log show --predicate 'process == "Claude Island"' --info

# 清除应用数据（重置设置）
rm ~/Library/Preferences/com.celestial.ClaudeIsland.plist

# 重置屏幕录制权限
tccutil reset ScreenCapture com.celestial.ClaudeIsland
```

## 第三方依赖

项目使用 Swift Package Manager 管理依赖：

- **Mixpanel** - 匿名使用分析
- **Sparkle** - 自动更新框架
- **Markdown** - Markdown 文本渲染

依赖在 `project.pbxproj` 中配置为 package product dependencies。

## 代码风格规范

- 遵循 Swift API 设计指南
- 使用 4 空格缩进，无尾随空格
- 类型/协议：`UpperCamelCase`
- 方法/变量：`lowerCamelCase`
- SwiftUI 视图命名：`SomethingView.swift`
- 扩展命名：`Ext+Type.swift`
- 偏好小而专注的类型，保持视图简单

## 核心工作流程

### 1. 会话监控流程

```
Claude Code 执行 → Hook 事件 → HookSocketServer → SessionStore.process(event) → UI 更新
```

### 2. 权限审批流程

```
工具执行请求 → Notch 展开 → 用户批准/拒绝 → 套接字响应 → 工具执行
```

### 3. 文件同步流程

```
JSONL 文件更新 → ConversationParser → FileUpdatePayload → SessionStore → 聊天历史更新
```

## 关键文件

- `Services/Hooks/HookInstaller.swift` - 自动安装 Claude 钩子
- `Services/Hooks/HookSocketServer.swift` - 套接字服务器，处理通信
- `Services/Session/SessionStore.swift` - 状态管理中心
- `Models/SessionEvent.swift` - 统一事件类型定义
- `UI/Views/NotchView.swift` - 主 Notch 视图
- `Core/Settings.swift` - 用户设置管理

## 测试指南

当前项目**没有专门的测试目标**。如需添加测试：

- 使用 `XCTest` 创建 `ClaudeIslandTests` 目标
- 测试命名约定：`test_<behavior>`
- UI 变更需包含手动 QA 清单（如"多显示器"、"notch 开关"、"审批流程"）

## 提交和 PR 规范

- 提交信息：简短、祈使句、标题大小写（如"Fix window leak on screen changes"）
- PR 应包含：
  - What/Why 摘要和测试步骤
  - UI 变更的截图或录屏
  - 版本/更新行为等影响发布的说明

## 重要注意事项

1. **钩子位置** - 应用在 `~/.claude/hooks/` 下安装/使用 Claude 钩子，修改钩子行为需文档化迁移步骤

2. **签名和公证** - 发布脚本会修改签名/公证状态，在 `build/` 和 `releases/` 中创建构件，除非明确配置，否则不要在 CI 中运行

3. **Sparkle 密钥** - 存储在 `.sparkle-keys/` 目录，**永远不要提交**到版本控制

4. **权限管理** - 应用需要屏幕录制权限才能正常工作

5. **多显示器支持** - Notch 可以在不同显示器间移动，支持主屏幕选择

## 版本和更新

- 版本号在 `project.pbxproj` 中配置
- 使用 Sparkle 进行自动更新
- 更新检查通过 Sparkle 的 `NotchUserDriver` 处理

## 日志和调试

- 使用 `DebugFileLogger` 进行文件日志记录
- 日志位置：`~/Library/Logs/com.celestial.ClaudeIsland/`
- 支持会话级别的详细日志跟踪
