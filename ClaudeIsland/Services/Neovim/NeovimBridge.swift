//
//  NeovimBridge.swift
//  ClaudeIsland
//
//  RPC bridge to communicate with Neovim instances via nvim --server --remote-expr
//  Implements the control plane: ClaudeIsland -> Neovim -> Claude terminal injection
//

import Foundation
import os.log

/// Errors that can occur during Neovim RPC communication
enum NeovimBridgeError: Error, LocalizedError {
    case noNeovimInstance
    case noListenAddress
    case rpcFailed(String)
    case invalidResponse(String)
    case nvimNotFound
    case terminalNotReady
    case emptyText
    case unknownAction
    case jsonEncodingFailed

    var errorDescription: String? {
        switch self {
        case .noNeovimInstance:
            return "No Neovim instance found for this session"
        case .noListenAddress:
            return "Neovim instance has no listen address"
        case .rpcFailed(let msg):
            return "Neovim RPC failed: \(msg)"
        case .invalidResponse(let msg):
            return "Invalid response from Neovim: \(msg)"
        case .nvimNotFound:
            return "nvim executable not found"
        case .terminalNotReady:
            return "Claude terminal is not ready in Neovim"
        case .emptyText:
            return "Cannot send empty text"
        case .unknownAction:
            return "Unknown RPC action"
        case .jsonEncodingFailed:
            return "Failed to encode JSON payload"
        }
    }
}

/// Response from Neovim RPC call
struct NeovimRPCResponse: Codable {
    let trace_id: String
    let ok: Bool
    let error: String?
    let data: NeovimRPCData?
}

/// Data payload from Neovim RPC response
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

/// Neovim instance information
struct NeovimInstance: Codable, Equatable, Sendable {
    let pid: Int
    let listenAddress: String
    let cwd: String?
    let registeredAt: Date

    // New fields for tmux info
    let tmuxSession: String?
    let tmuxWindow: String?
    let tmuxPane: String?

    /// The registry file path
    static var registryPath: String {
        let xdgRuntime = Foundation.ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? "/tmp"
        return "\(xdgRuntime)/claude-island-nvim-registry.json"
    }

    /// Convenience initializer with tmux info
    static func createWithTmuxInfo(
        pid: Int,
        listenAddress: String,
        cwd: String?,
        tmuxSession: String?,
        tmuxWindow: String?,
        tmuxPane: String?
    ) -> NeovimInstance {
        return NeovimInstance(
            pid: pid,
            listenAddress: listenAddress,
            cwd: cwd,
            registeredAt: Date(),
            tmuxSession: tmuxSession,
            tmuxWindow: tmuxWindow,
            tmuxPane: tmuxPane
        )
    }
}

/// Registry of known Neovim instances
struct NeovimRegistry: Codable {
    var instances: [NeovimInstance]
}

/// Bridge for communicating with Neovim via RPC
actor NeovimBridge {
    /// Shared instance
    static let shared = NeovimBridge()

    /// Logger
    private static let logger = Logger(subsystem: "com.claudeisland", category: "NeovimBridge")

    /// Path to nvim executable
    private var nvimPath: String?

    /// Cached registry
    private var registry: NeovimRegistry?
    private var registryLoadTime: Date?

    private init() {}

    // MARK: - Public API

    /// Send text to Neovim Claude terminal
    /// - Parameters:
    ///   - text: The text to send
    ///   - sessionState: The session state (used for routing)
    ///   - mode: Send mode ("append_only" or "append_and_enter")
    ///   - ensureTerminal: Whether to ensure terminal is visible first
    /// - Returns: The number of bytes injected
    func sendText(
        _ text: String,
        for sessionState: SessionState,
        mode: String = "append_and_enter",
        ensureTerminal: Bool = true
    ) async throws -> Int {
        guard !text.isEmpty else {
            throw NeovimBridgeError.emptyText
        }

        // Find Neovim instance
        let instance = try await findNeovimInstance(for: sessionState)

        // Build the RPC payload
        let payload: [String: Any] = [
            "trace_id": String(UUID().uuidString.prefix(8)),
            "ts_ms": Int(Date().timeIntervalSince1970 * 1000),
            "source": "claudeisland",
            "session_id": sessionState.sessionId,
            "nvim_pid": instance.pid,
            "action": "send_text",
            "payload": [
                "text": text,
                "mode": mode,
                "ensure_terminal": ensureTerminal
            ]
        ]

        let response = try await callRPC(instance: instance, payload: payload, traceId: String(UUID().uuidString.prefix(8)))

        guard response.ok else {
            let errorMsg = response.error ?? "Unknown error"
            throw NeovimBridgeError.rpcFailed(errorMsg)
        }

        return response.data?.injected_bytes ?? 0
    }

    /// Check if a Neovim instance is available for a session
    func isAvailable(for sessionState: SessionState) async -> Bool {
        do {
            let instance = try await findNeovimInstance(for: sessionState)
            let status = try await getStatus(instance: instance)
            return status.ok && (status.data?.terminal_ready ?? false)
        } catch {
            return false
        }
    }

    /// Ping a Neovim instance
    func ping(for sessionState: SessionState) async -> Bool {
        do {
            let instance = try await findNeovimInstance(for: sessionState)
            let traceId = UUID().uuidString

            let payload: [String: Any] = [
                "trace_id": traceId,
                "action": "ping"
            ]

            let response = try await callRPC(instance: instance, payload: payload, traceId: traceId)
            return response.ok && (response.data?.pong ?? false)
        } catch {
            return false
        }
    }


    /// Check connection to a Neovim instance using stored address/PID
    /// Used for health checking without requiring full SessionState
    func checkConnection(listenAddress: String?, nvimPid: Int?) async throws -> Bool {
        // Need at least a listen address to attempt connection
        guard let address = listenAddress else {
            // Try to get address from PID if available
            if let pid = nvimPid, let addr = await getNeovimListenAddress(pid: pid) {
                return try await checkConnectionDirect(address: addr, pid: pid)
            }
            throw NeovimBridgeError.noNeovimInstance
        }

        return try await checkConnectionDirect(address: address, pid: nvimPid ?? 0)
    }

    /// Direct connection check with known address
    private func checkConnectionDirect(address: String, pid: Int) async throws -> Bool {
        let instance = NeovimInstance(
            pid: pid,
            listenAddress: address,
            cwd: nil,
            registeredAt: Date(),
            tmuxSession: nil,
            tmuxWindow: nil,
            tmuxPane: nil
        )

        let traceId = UUID().uuidString
        let payload: [String: Any] = [
            "trace_id": traceId,
            "action": "ping"
        ]

        let response = try await callRPC(instance: instance, payload: payload, traceId: traceId)
        return response.ok && (response.data?.pong ?? false)
    }

    /// Get terminal status from Neovim
    func getStatus(for sessionState: SessionState) async throws -> NeovimRPCResponse {
        let instance = try await findNeovimInstance(for: sessionState)
        return try await getStatus(instance: instance)
    }

    /// Focus the Claude terminal in Neovim
    func focusTerminal(for sessionState: SessionState) async throws {
        let instance = try await findNeovimInstance(for: sessionState)
        let traceId = UUID().uuidString

        let payload: [String: Any] = [
            "trace_id": traceId,
            "action": "focus_terminal"
        ]

        let response = try await callRPC(instance: instance, payload: payload, traceId: traceId)

        guard response.ok else {
            throw NeovimBridgeError.rpcFailed(response.error ?? "Focus failed")
        }
    }

    // MARK: - Instance Discovery

    /// Find the Neovim instance for a session
    private func findNeovimInstance(for sessionState: SessionState) async throws -> NeovimInstance {
        // Strategy 1: Check registry file
        if let instance = await findFromRegistry(for: sessionState) {
            return instance
        }

        // Strategy 2: Search for Neovim by PID relationship
        if let instance = await findByPidRelation(for: sessionState) {
            return instance
        }

        // Strategy 3: Search by CWD
        if let instance = await findByCwd(for: sessionState) {
            return instance
        }

        // Strategy 4: Global tmux search
        if let instance = await findInAllTmuxSessions(for: sessionState) {
            return instance
        }

        throw NeovimBridgeError.noNeovimInstance
    }

    /// Find Neovim instance from registry file
    private func findFromRegistry(for sessionState: SessionState) async -> NeovimInstance? {
        let registry = await loadRegistry()
        guard let registry = registry else {
            return nil
        }

        // Strategy 1: Perfect match (all fields match)
        if let match = registry.instances.first(where: { instance in
            instance.cwd == sessionState.cwd &&
            (instance.tmuxSession != nil || instance.tmuxPane != nil)
        }) {
            if validateInstance(match) {
                return match
            }
        }

        // Strategy 2: Match by CWD (might be multiple)
        let cwdMatches = registry.instances.filter { $0.cwd == sessionState.cwd }
        if !cwdMatches.isEmpty {
            // If only one, use it
            if cwdMatches.count == 1 {
                let match = cwdMatches[0]
                if validateInstance(match) {
                    return match
                }
            } else {
                // Multiple matches, try to filter by tmux info
                for match in cwdMatches {
                    if match.tmuxPane != nil || match.tmuxSession != nil {
                        if validateInstance(match) {
                            return match
                        }
                    }
                }
            }
        }

        // Strategy 3: Fallback to single instance
        if registry.instances.count == 1 {
            let match = registry.instances[0]
            if validateInstance(match) {
                return match
            }
        }

        return nil
    }

    /// Find Neovim instance by PID relationship (Neovim -> Claude)
    /// Uses the nvimPid already detected by SessionStore
    private func findByPidRelation(for sessionState: SessionState) async -> NeovimInstance? {
        guard let nvimPid = sessionState.nvimPid else {
            return nil
        }

        // Validate that the process is actually running nvim
        if let processName = getProcessName(pid: nvimPid) {
            if !processName.lowercased().contains("nvim") {
                return nil
            }
        } else {
            return nil
        }

        // Get the listen address
        if let listenAddr = await getNeovimListenAddress(pid: nvimPid) {
            return NeovimInstance(
                pid: nvimPid,
                listenAddress: listenAddr,
                cwd: sessionState.cwd,
                registeredAt: Date(),
                tmuxSession: nil,
                tmuxWindow: nil,
                tmuxPane: nil
            )
        }

        return nil
    }

    /// Find Neovim instance by CWD
    private func findByCwd(for sessionState: SessionState) async -> NeovimInstance? {
        let result = ProcessExecutor.shared.runSyncOrNil(
            "/usr/bin/pgrep",
            arguments: ["-x", "nvim"]
        )

        guard let output = result else {
            return nil
        }

        let pids = output.split(separator: "\n").compactMap { Int($0) }

        for pid in pids {
            if let cwd = getProcessCwd(pid: pid), cwd == sessionState.cwd {
                if let listenAddr = await getNeovimListenAddress(pid: pid) {
                    return NeovimInstance(
                        pid: pid,
                        listenAddress: listenAddr,
                        cwd: cwd,
                        registeredAt: Date(),
                        tmuxSession: nil,
                        tmuxWindow: nil,
                        tmuxPane: nil
                    )
                }
            }
        }

        return nil
    }

    /// Validate that a Neovim instance is still running
    private func validateInstance(_ instance: NeovimInstance) -> Bool {
        let result = ProcessExecutor.shared.runSyncOrNil(
            "/bin/kill",
            arguments: ["-0", String(instance.pid)]
        )
        return result != nil
    }

    // MARK: - Registry Management

    /// Load the registry file
    private func loadRegistry() async -> NeovimRegistry? {
        // Cache for 5 seconds
        if let cache = registry, let loadTime = registryLoadTime,
           Date().timeIntervalSince(loadTime) < 5 {
            return cache
        }

        let path = NeovimInstance.registryPath

        // Check if file exists
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path) else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let registry = try decoder.decode(NeovimRegistry.self, from: data)
            self.registry = registry
            self.registryLoadTime = Date()
            return registry
        } catch {
            return nil
        }
    }

    // MARK: - RPC Communication

    /// Call Neovim RPC via direct msgpack-rpc socket communication
    /// This bypasses the --remote-expr bug in Neovim 0.9.0+
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
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
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

    /// Get terminal status from a specific instance
    private func getStatus(instance: NeovimInstance) async throws -> NeovimRPCResponse {
        let traceId = UUID().uuidString

        let payload: [String: Any] = [
            "trace_id": traceId,
            "action": "status"
        ]

        return try await callRPC(instance: instance, payload: payload, traceId: traceId)
    }

    // MARK: - Helper Functions

    /// Extract JSON from output that may contain terminal control sequences
    /// Looks for the first `{` and last `}` to extract the JSON portion
    private nonisolated static func extractJSON(from output: String) -> String {
        // Try to find JSON boundaries
        guard let jsonStart = output.firstIndex(of: "{"),
              let jsonEnd = output.lastIndex(of: "}") else {
            // No JSON found, return empty (will cause clear error)
            return "{}"
        }

        // Extract JSON portion - simply take everything between first { and last }
        let startIndex = jsonStart
        let endIndex = output.index(after: jsonEnd)

        guard startIndex < endIndex else {
            return "{}"
        }

        return String(output[startIndex..<endIndex])
    }

    /// Find nvim executable path
    private func findNvimPath() async throws -> String {
        if let cached = nvimPath {
            return cached
        }

        let home = Foundation.ProcessInfo.processInfo.environment["HOME"] ?? "/Users/pittcat"

        // Common paths (including bob, asdf, mise, etc.)
        let paths = [
            "/opt/homebrew/bin/nvim",
            "/usr/local/bin/nvim",
            "/usr/bin/nvim",
            "\(home)/.local/bin/nvim",
            "\(home)/.local/share/bob/nvim-bin/nvim",     // bob (Neovim version manager)
            "\(home)/.asdf/shims/nvim",                    // asdf
            "\(home)/.local/share/mise/shims/nvim",        // mise
            "\(home)/.nix-profile/bin/nvim",               // nix
        ]

        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                nvimPath = path
                return path
            }
        }

        // Try which as fallback
        if let result = ProcessExecutor.shared.runSyncOrNil("/usr/bin/which", arguments: ["nvim"]) {
            let path = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if FileManager.default.isExecutableFile(atPath: path) {
                nvimPath = path
                return path
            }
        }

        Self.logger.error("findNvimPath: nvim not found in any known location")
        throw NeovimBridgeError.nvimNotFound
    }

    /// Get Neovim's listen address for a PID
    private func getNeovimListenAddress(pid: Int) async -> String? {
        // Method 1: Check NVIM env via /proc or lsof
        // On macOS, we can use lsof to find the socket

        let result = ProcessExecutor.shared.runSyncOrNil(
            "/usr/bin/lsof",
            arguments: ["-p", String(pid), "-a", "-U"]
        )

        if let output = result {
            // Look for unix socket paths that look like Neovim server sockets
            // Neovim typically creates sockets like /tmp/nvim.*/0 or in $XDG_RUNTIME_DIR
            let lines = output.split(separator: "\n")
            for line in lines {
                let lineStr = String(line)
                if lineStr.contains("/nvim") || lineStr.contains("nvim.") {
                    // Extract the socket path
                    let parts = lineStr.split(separator: " ")
                    if let last = parts.last {
                        let path = String(last)
                        if path.hasPrefix("/") && (path.contains("nvim") || path.hasSuffix("/0")) {
                            return path
                        }
                    }
                }
            }
        }

        // Method 2: Check common Neovim socket locations
        let xdgRuntime = Foundation.ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? "/tmp"
        let possiblePaths = [
            "\(xdgRuntime)/nvim.\(pid).0",
            "/tmp/nvim.\(pid).0",
            "/tmp/nvim\(pid)/0"
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }

    /// Get parent process info
    private func getParentProcess(pid: Int) -> (pid: Int, name: String)? {
        let result = ProcessExecutor.shared.runSyncOrNil(
            "/bin/ps",
            arguments: ["-p", String(pid), "-o", "ppid=,comm="]
        )

        guard let output = result else { return nil }

        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1)
        guard parts.count >= 2,
              let ppid = Int(parts[0].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }

        let name = String(parts[1]).trimmingCharacters(in: .whitespaces)
        return (ppid, name)
    }

    /// Get process CWD
    private func getProcessCwd(pid: Int) -> String? {
        let result = ProcessExecutor.shared.runSyncOrNil(
            "/usr/bin/lsof",
            arguments: ["-p", String(pid), "-a", "-d", "cwd", "-Fn"]
        )

        guard let output = result else { return nil }

        let lines = output.split(separator: "\n")
        for line in lines {
            if line.hasPrefix("n") {
                return String(line.dropFirst())
            }
        }

        return nil
    }

    /// Get process name
    private func getProcessName(pid: Int) -> String? {
        let result = ProcessExecutor.shared.runSyncOrNil(
            "/bin/ps",
            arguments: ["-p", String(pid), "-o", "comm="]
        )

        guard let output = result else { return nil }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Debug Tools

    /// Debug tool: List all available Neovim instances
    func listAvailableInstances() async -> [String] {
        var instances: [String] = []

        // Get from registry
        if let registry = await loadRegistry() {
            for instance in registry.instances {
                let status = validateInstance(instance) ? "RUNNING" : "DEAD"
                let tmuxInfo = instance.tmuxSession.map { "\($0):\(instance.tmuxWindow ?? "").\(instance.tmuxPane ?? "")" } ?? "N/A"
                instances.append("PID:\(instance.pid) [\(status)] SOCKET:\(instance.listenAddress) CWD:\(instance.cwd ?? "N/A") TMUX:\(tmuxInfo)")
            }
        }

        // Get from process tree
        if let output = ProcessExecutor.shared.runSyncOrNil("/usr/bin/pgrep", arguments: ["-x", "nvim"]) {
            let pids = output.split(separator: "\n").compactMap { Int($0) }
            for pid in pids {
                if let cwd = getProcessCwd(pid: pid),
                   let listenAddr = await getNeovimListenAddress(pid: pid) {
                    if !instances.contains(where: { $0.hasPrefix("PID:\(pid)") }) {
                        instances.append("PID:\(pid) [PROCESS] SOCKET:\(listenAddr) CWD:\(cwd)")
                    }
                }
            }
        }

        return instances
    }

    /// Debug tool: Check specific session's Neovim instance
    func debugSession(_ sessionId: String) async -> [String] {
        guard let session = await SessionStore.shared.session(for: sessionId) else {
            return ["Session not found"]
        }

        var debugInfo: [String] = [
            "=== Session Debug: \(sessionId.prefix(8)) ===",
            "CWD: \(session.cwd)",
            "PID: \(session.pid.map(String.init) ?? "nil")",
            "IsInTmux: \(session.isInTmux)",
            "IsInNeovim: \(session.isInNeovim)",
            "NvimPid: \(session.nvimPid.map(String.init) ?? "nil")",
            "CanSendViaNeovim: \(session.canSendViaNeovim)",
            "",
            "=== Searching for Neovim instances ==="
        ]

        // Search all instances
        let allInstances = await listAvailableInstances()
        for instance in allInstances {
            debugInfo.append("  \(instance)")
        }

        // Try to find matching instance
        do {
            let match = try await findNeovimInstance(for: session)
            debugInfo.append("")
            debugInfo.append("=== MATCH FOUND ===")
            debugInfo.append("PID: \(match.pid)")
            debugInfo.append("Socket: \(match.listenAddress)")
            debugInfo.append("CWD: \(match.cwd ?? "nil")")
        } catch {
            debugInfo.append("")
            debugInfo.append("=== NO MATCH FOUND ===")
            debugInfo.append("Error: \(error.localizedDescription)")
        }

        return debugInfo
    }

    // MARK: - Global TMUX Search

    /// Search in all tmux sessions for a Neovim instance
    private func findInAllTmuxSessions(for sessionState: SessionState) async -> NeovimInstance? {
        // Get tmux path
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        // Strategy 4a: Find by CWD in all tmux sessions
        if let instance = await findByCwdInAllTmuxSessions(sessionState.cwd, tmuxPath: tmuxPath) {
            return instance
        }

        // Strategy 4b: Find by process tree analysis in tmux panes
        if let instance = await findByProcessTreeInTmux(sessionState, tmuxPath: tmuxPath) {
            return instance
        }

        return nil
    }

    /// Find Neovim by CWD in all tmux sessions
    private func findByCwdInAllTmuxSessions(_ cwd: String, tmuxPath: String) async -> NeovimInstance? {
        // List all panes with their CWD
        let result = await ProcessExecutor.shared.runWithResult(
            tmuxPath,
            arguments: [
                "list-panes", "-a", "-F",
                "#{session_name}:#{window_index}.#{pane_index} #{pane_pid} #{pane_current_path}"
            ]
        )

        guard case .success(let processResult) = result else {
            return nil
        }

        let lines = processResult.output.components(separatedBy: "\n")
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count >= 3,
                  let panePid = Int(parts[1]) else {
                continue
            }

            let panePath = String(parts[2])

            if panePath == cwd {
                // Check if this pane's process tree has Neovim
                if let nvimPid = await findNeovimInPaneProcessTree(panePid: panePid) {
                    if let listenAddr = await getNeovimListenAddress(pid: nvimPid) {
                        return NeovimInstance(
                            pid: nvimPid,
                            listenAddress: listenAddr,
                            cwd: panePath,
                            registeredAt: Date(),
                            tmuxSession: nil,
                            tmuxWindow: nil,
                            tmuxPane: nil
                        )
                    }
                }
            }
        }

        return nil
    }

    /// Find Neovim by process tree analysis in tmux panes
    private func findByProcessTreeInTmux(_ sessionState: SessionState, tmuxPath: String) async -> NeovimInstance? {
        // List all panes with their PID
        let result = await ProcessExecutor.shared.runWithResult(
            tmuxPath,
            arguments: [
                "list-panes", "-a", "-F",
                "#{session_name}:#{window_index}.#{pane_index} #{pane_pid}"
            ]
        )

        guard case .success(let processResult) = result else {
            return nil
        }

        let lines = processResult.output.components(separatedBy: "\n")
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count >= 2,
                  let panePid = Int(parts[1]) else {
                continue
            }

            // Check if this pane's process tree contains the session's PID
            if sessionState.pid != nil, sessionState.pid == panePid {
                // Check if Neovim is in the tree
                if let nvimPid = await findNeovimInPaneProcessTree(panePid: panePid) {
                    if let listenAddr = await getNeovimListenAddress(pid: nvimPid) {
                        let cwd = getProcessCwd(pid: panePid) ?? sessionState.cwd
                        return NeovimInstance(
                            pid: nvimPid,
                            listenAddress: listenAddr,
                            cwd: cwd,
                            registeredAt: Date(),
                            tmuxSession: nil,
                            tmuxWindow: nil,
                            tmuxPane: nil
                        )
                    }
                }
            }
        }

        return nil
    }

    /// Find Neovim in a pane's process tree
    private func findNeovimInPaneProcessTree(panePid: Int) async -> Int? {
        // Simulate building process tree (limit depth to avoid loops)
        var visited: Set<Int> = []
        var queue: [Int] = [panePid]
        var depth = 0

        while !queue.isEmpty && depth < 10 {
            let currentPid = queue.removeFirst()
            if visited.contains(currentPid) {
                continue
            }
            visited.insert(currentPid)

            // Check if current process is Neovim
            if let processName = getProcessName(pid: currentPid),
               processName.lowercased().contains("nvim") {
                return currentPid
            }

            // Get child processes
            let children = getChildProcesses(pid: currentPid)
            queue.append(contentsOf: children)

            depth += 1
        }

        return nil
    }

    /// Get all child processes for a PID
    private func getChildProcesses(pid: Int) -> [Int] {
        let result = ProcessExecutor.shared.runSyncOrNil(
            "/bin/ps",
            arguments: ["-o", "pid,ppid", "--no-headers", "-ppid", String(pid)]
        )

        guard let output = result else {
            return []
        }

        return output.components(separatedBy: "\n")
            .compactMap { line in
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
                guard parts.count >= 1,
                      let childPid = Int(parts[0]) else {
                    return nil
                }
                return childPid
            }
    }
}
