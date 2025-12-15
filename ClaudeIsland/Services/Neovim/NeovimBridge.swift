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

    /// The registry file path
    static var registryPath: String {
        let xdgRuntime = Foundation.ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? "/tmp"
        return "\(xdgRuntime)/claude-island-nvim-registry.json"
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

        let traceId = String(UUID().uuidString.prefix(8))

        // Find Neovim instance
        let instance: NeovimInstance
        do {
            instance = try await findNeovimInstance(for: sessionState)
        } catch {
            Self.logger.error("Failed to find nvim instance: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        // Build the RPC payload
        let payload: [String: Any] = [
            "trace_id": traceId,
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

        let response = try await callRPC(instance: instance, payload: payload, traceId: traceId)

        guard response.ok else {
            let errorMsg = response.error ?? "Unknown error"
            Self.logger.error("RPC response error: \(errorMsg, privacy: .public)")
            throw NeovimBridgeError.rpcFailed(errorMsg)
        }

        let injectedBytes = response.data?.injected_bytes ?? 0
        return injectedBytes
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

        throw NeovimBridgeError.noNeovimInstance
    }

    /// Find Neovim instance from registry file
    private func findFromRegistry(for sessionState: SessionState) async -> NeovimInstance? {
        let registry = await loadRegistry()
        guard let registry = registry else {
            return nil
        }

        // Try to match by CWD first
        if let match = registry.instances.first(where: { $0.cwd == sessionState.cwd }) {
            if validateInstance(match) {
                return match
            }
        }

        // If only one instance, use it
        if registry.instances.count == 1 {
            let instance = registry.instances[0]
            if validateInstance(instance) {
                return instance
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
                registeredAt: Date()
            )
        }

        return nil
    }

    /// Find Neovim instance by CWD
    private func findByCwd(for sessionState: SessionState) async -> NeovimInstance? {
        // List all running Neovim processes and check their CWD
        // This is a fallback when registry is not available

        let result = ProcessExecutor.shared.runSyncOrNil(
            "/usr/bin/pgrep",
            arguments: ["-x", "nvim"]
        )

        guard let output = result else { return nil }

        let pids = output.split(separator: "\n").compactMap { Int($0) }

        for pid in pids {
            // Check process CWD
            if let cwd = getProcessCwd(pid: pid), cwd == sessionState.cwd {
                // Get listen address
                if let listenAddr = await getNeovimListenAddress(pid: pid) {
                    return NeovimInstance(
                        pid: pid,
                        listenAddress: listenAddr,
                        cwd: cwd,
                        registeredAt: Date()
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

    /// Call Neovim RPC via nvim --server --remote-expr
    private func callRPC(instance: NeovimInstance, payload: [String: Any], traceId: String) async throws -> NeovimRPCResponse {
        let nvimPath = try await findNvimPath()

        // Serialize payload to JSON
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw NeovimBridgeError.jsonEncodingFailed
        }

        // Escape the JSON string for Vim expression
        let escapedJson = jsonString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")

        let vimExpr = "v:lua.claudecode_island_rpc('\(escapedJson)')"

        let result = await ProcessExecutor.shared.runWithResult(
            nvimPath,
            arguments: [
                "--server", instance.listenAddress,
                "--remote-expr", vimExpr
            ]
        )

        switch result {
        case .success(let processResult):
            let output = processResult.output.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let data = output.data(using: .utf8) else {
                throw NeovimBridgeError.invalidResponse("Not valid UTF-8")
            }

            do {
                let response = try JSONDecoder().decode(NeovimRPCResponse.self, from: data)
                return response
            } catch {
                throw NeovimBridgeError.invalidResponse(error.localizedDescription)
            }

        case .failure(let error):
            throw NeovimBridgeError.rpcFailed(error.localizedDescription)
        }
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

    /// Find nvim executable path
    private func findNvimPath() async throws -> String {
        if let cached = nvimPath {
            return cached
        }

        // Common paths
        let paths = [
            "/opt/homebrew/bin/nvim",
            "/usr/local/bin/nvim",
            "/usr/bin/nvim",
            Foundation.ProcessInfo.processInfo.environment["HOME"].map { "\($0)/.local/bin/nvim" }
        ].compactMap { $0 }

        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                nvimPath = path
                return path
            }
        }

        // Try which
        if let result = ProcessExecutor.shared.runSyncOrNil("/usr/bin/which", arguments: ["nvim"]) {
            let path = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if FileManager.default.isExecutableFile(atPath: path) {
                nvimPath = path
                return path
            }
        }

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
}
