# Neovim 交互核心代码

## 1. Swift 端：NeovimBridge.swift (核心部分)

```swift
// NeovimBridge.swift - callRPC 方法
private func callRPC(instance: NeovimInstance, payload: [String: Any], traceId: String) async throws -> NeovimRPCResponse {
    // 准备 Lua 代码
    let luaCode = """
    local params = ...
    return require('claudecode.island_rpc').handle_rpc(params)
    """

    // 序列化参数为 JSON
    let paramsData = try JSONSerialization.data(withJSONObject: payload)
    let paramsJson = String(data: paramsData, encoding: .utf8)!

    // 调用 Python helper
    let helperPath = "/Users/pittcat/.vim/plugged/claudecode.nvim/scripts/rpc_helper.py"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
        helperPath,
        instance.listenAddress,
        luaCode,
        paramsJson
    ]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()

    // 等待执行完成（带超时）
    let timeoutDate = Date().addingTimeInterval(5.0)
    while process.isRunning && Date() < timeoutDate {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    if process.isRunning {
        process.terminate()
        throw NeovimBridgeError.rpcFailed("RPC call timed out after 5 seconds")
    }

    // 读取输出
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

    guard let rawOutput = String(data: outputData, encoding: .utf8) else {
        throw NeovimBridgeError.rpcFailed("Failed to decode output")
    }

    // 解析 JSON
    guard let jsonData = rawOutput.data(using: .utf8),
          let response = try? JSONDecoder().decode(NeovimRPCResponse.self, from: jsonData) else {
        throw NeovimBridgeError.rpcFailed("JSON decode failed")
    }

    return response
}
```

## 2. Python 端：rpc_helper.py

```python
#!/usr/bin/env python3
"""
Neovim RPC Helper for Claude Island
使用 pynvim 库通过 msgpack-rpc 调用 Neovim
"""
import sys
import json
from pynvim import attach

def call_rpc(servername, lua_code, args=None):
    """通过 RPC 调用 Neovim Lua 函数"""
    try:
        # 连接到 Neovim
        nvim = attach('socket', path=servername)
        
        # 执行 Lua 代码
        result = nvim.api.exec_lua(lua_code, args or [])
        
        # 输出结果
        print(json.dumps(result, ensure_ascii=False))
        return 0
        
    except Exception as e:
        # 输出错误信息
        error_result = {
            "ok": False,
            "error": str(e),
            "trace_id": args[0].get("trace_id", "unknown") if args else "unknown"
        }
        print(json.dumps(error_result, ensure_ascii=False))
        return 1

def main():
    if len(sys.argv) < 3:
        print(json.dumps({"ok": False, "error": "Usage: rpc_helper.py <servername> <lua_code> [args_json]"}))
        return 1
    
    servername = sys.argv[1]
    lua_code = sys.argv[2]
    args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None

    return call_rpc(servername, lua_code, [args] if args else None)

if __name__ == "__main__":
    sys.exit(main())
```

## 3. Lua 端：island_rpc.lua (核心部分)

```lua
---Handle RPC request from ClaudeIsland
---@param payload table JSON payload from ClaudeIsland
---@return table response table
function M.handle_rpc(payload)
  local trace_id = payload.trace_id or "unknown"
  local action = payload.action or "unknown"

  -- Dispatch based on action
  if action == "ping" then
    return {
      trace_id = trace_id,
      ok = true,
      error = nil,
      data = {
        nvim_pid = vim.fn.getpid(),
        pong = true,
      }
    }

  elseif action == "send_text" then
    local text_payload = payload.payload or {}
    local text = text_payload.text or ""
    local mode = text_payload.mode or "append_and_enter"
    local ensure_terminal = text_payload.ensure_terminal or false

    if text == "" then
      return {
        trace_id = trace_id,
        ok = false,
        error = "EMPTY_TEXT",
        data = nil
      }
    end

    -- 注入文本到终端
    local term = get_terminal_module()
    if not term then
      return {
        trace_id = trace_id,
        ok = false,
        error = "Terminal module not found",
        data = nil
      }
    end

    local bufnr = term.get_active_terminal_bufnr and term.get_active_terminal_bufnr()
    if not bufnr then
      return {
        trace_id = trace_id,
        ok = false,
        error = "No active terminal buffer",
        data = nil
      }
    end

    if not vim.api.nvim_buf_is_valid(bufnr) then
      return {
        trace_id = trace_id,
        ok = false,
        error = "Invalid terminal buffer",
        data = nil
      }
    end

    local append_enter = (mode == "append_and_enter")
    local success, injected_bytes, error_msg = inject_to_terminal(text, append_enter, trace_id, bufnr)

    return {
      trace_id = trace_id,
      ok = success,
      error = error_msg,
      data = {
        nvim_pid = vim.fn.getpid(),
        terminal_ready = success,
        injected_bytes = injected_bytes,
      }
    }

  elseif action == "status" then
    local status = get_terminal_status(trace_id)
    return {
      trace_id = trace_id,
      ok = true,
      error = nil,
      data = status
    }

  else
    return {
      trace_id = trace_id,
      ok = false,
      error = "UNKNOWN_ACTION",
      data = nil
    }
  end
end
```

## 4. 数据结构

### Swift: NeovimRPCResponse
```swift
struct NeovimRPCResponse: Codable {
    let trace_id: String
    let ok: Bool
    let error: String?
    let data: NeovimRPCData?
}

struct NeovimRPCData: Codable {
    let nvim_pid: Int?
    let terminal_ready: Bool?
    let injected_bytes: Int?
    let pong: Bool?
    let focused: Bool?
    let bufnr: Int?
    let job_channel: Int?
    let nvim_listen_address: String?
}
```

### Python: 传递给 Lua 的参数
```json
{
  "action": "send_text",
  "payload": {
    "text": "hello world",
    "mode": "append_and_enter",
    "ensure_terminal": true
  },
  "trace_id": "ABC123",
  "nvim_pid": 12345,
  "session_id": "session-123",
  "source": "claudeisland",
  "ts_ms": 1234567890
}
```

## 5. 使用方式

### Swift 调用
```swift
let payload: [String: Any] = [
    "action": "send_text",
    "payload": [
        "text": "hello",
        "mode": "append_and_enter"
    ],
    "trace_id": "ABC123"
]

let response = try await callRPC(instance, payload, "ABC123")
```

### Python 直接调用
```bash
python3 rpc_helper.py <socket_path> "return {ok=true}" '{}'
```

### Lua 测试
```lua
lua -c "
local result = require('claudecode.island_rpc').handle_rpc({
    action = 'ping',
    trace_id = 'test'
})
print(vim.json.encode(result))
"
```
