//
//  IDERPCServer.swift
//  ClaudeIsland
//
//  Unix domain socket RPC server for IDE integrations (Neovim, etc.)
//  Handles file mentions and commands from IDE plugins
//

import Foundation
import os.log

/// Logger for IDE RPC server
private let logger = Logger(subsystem: "com.claudeisland", category: "IDERPC")

/// Request from IDE (e.g., Neovim plugin)
struct IDERPCRequest: Codable, Sendable {
    let method: String
    let sessionId: String?
    let filePath: String?
    let lineStart: Int?
    let lineEnd: Int?
    let content: String?
    let metadata: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case method
        case sessionId = "session_id"
        case filePath = "file_path"
        case lineStart = "line_start"
        case lineEnd = "line_end"
        case content
        case metadata
    }
}

/// Response to IDE
struct IDERPCResponse: Codable {
    let success: Bool
    let message: String?
    let data: [String: AnyCodable]?
}

/// IDE RPC Server - handles requests from Neovim and other IDE plugins
actor IDERPCServer {
    static let shared = IDERPCServer()

    private var serverSocket: Int32 = -1
    private var isRunning = false
    private var acceptTask: Task<Void, Never>?

    /// Socket path for IDE communication
    private let socketPath: String

    private init() {
        // Use XDG_RUNTIME_DIR if available, otherwise use /tmp
        let runtimeDir = Foundation.ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? "/tmp"
        socketPath = "\(runtimeDir)/claude-island-ide.sock"
    }

    /// Start the IDE RPC server
    func start() async throws {
        guard !isRunning else {
            logger.info("IDE RPC server already running")
            return
        }

        logger.info("Starting IDE RPC server...")

        // Remove existing socket file if it exists
        try? FileManager.default.removeItem(atPath: socketPath)
        logger.info("Removed old socket file if exists: \(self.socketPath, privacy: .public)")

        // Create Unix domain socket
        self.serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard self.serverSocket >= 0 else {
            logger.error("Failed to create socket (errno: \(errno))")
            throw NSError(domain: "IDERPCServer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create socket"
            ])
        }
        logger.info("Unix socket created: fd=\(self.serverSocket)")

        // Set socket options
        var reuseAddr: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))
        logger.info("Socket options set (SO_REUSEADDR)")

        // Bind socket
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy socket path to sun_path
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { pathBytes in
            socketPath.utf8CString.withUnsafeBytes { sourceBytes in
                let copySize = min(sourceBytes.count, pathSize - 1)
                pathBytes.copyBytes(from: sourceBytes.prefix(copySize))
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            let err = errno
            close(serverSocket)
            logger.error("Failed to bind socket to \(self.socketPath, privacy: .public) (errno: \(err))")
            throw NSError(domain: "IDERPCServer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to bind socket to \(socketPath)"
            ])
        }
        logger.info("Socket bound to: \(self.socketPath, privacy: .public)")

        // Listen for connections
        guard listen(serverSocket, 5) == 0 else {
            let err = errno
            close(serverSocket)
            logger.error("Failed to listen on socket (errno: \(err))")
            throw NSError(domain: "IDERPCServer", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Failed to listen on socket"
            ])
        }
        logger.info("Socket listening (backlog=5)")

        // Set socket permissions (readable/writable by user and group)
        try? FileManager.default.setAttributes([.posixPermissions: 0o660], ofItemAtPath: socketPath)
        logger.info("Socket permissions set to 0660")

        isRunning = true
        logger.info("✅ IDE RPC server started successfully on \(self.socketPath, privacy: .public)")

        // Start accepting connections
        acceptTask = Task {
            await acceptConnections()
        }
        logger.info("Accept loop started")
    }

    /// Stop the IDE RPC server
    func stop() {
        guard isRunning else { return }

        isRunning = false
        acceptTask?.cancel()
        acceptTask = nil

        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }

        try? FileManager.default.removeItem(atPath: socketPath)
        logger.info("IDE RPC server stopped")
    }

    /// Get the socket path for client connections
    nonisolated func getSocketPath() -> String {
        return socketPath
    }

    // MARK: - Private Methods

    private func acceptConnections() async {
        while isRunning {
            // Accept connection (blocking)
            let clientSocket = accept(serverSocket, nil, nil)
            guard clientSocket >= 0 else {
                if isRunning {
                    logger.error("Failed to accept connection")
                }
                continue
            }

            // Handle client in separate task
            Task {
                await handleClient(socket: clientSocket)
            }
        }
    }

    private func handleClient(socket: Int32) async {
        defer {
            logger.debug("Closing client socket (fd=\(socket))")
            close(socket)
        }

        logger.info("📥 Client connected (fd=\(socket))")

        // Read request
        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = read(socket, &buffer, buffer.count)

        if bytesRead <= 0 {
            let err = errno
            logger.error("❌ Failed to read from client socket (fd=\(socket), bytes=\(bytesRead), errno=\(err))")
            return
        }

        let data = Data(buffer[0..<bytesRead])
        logger.info("📥 Received \(bytesRead) bytes from client (fd=\(socket))")
        logger.debug("📄 Raw data: \(String(data: data, encoding: .utf8) ?? "invalid utf8", privacy: .public)")

        // Parse request
        guard let request = try? JSONDecoder().decode(IDERPCRequest.self, from: data) else {
            logger.error("❌ Failed to decode IDE RPC request from \(bytesRead) bytes")
            await sendResponse(socket: socket, response: IDERPCResponse(
                success: false,
                message: "Invalid request format",
                data: nil
            ))
            return
        }

        logger.info("📨 Received IDE RPC request: method=\(request.method, privacy: .public), file_path=\(request.filePath ?? "nil", privacy: .public)")
        logger.debug("📋 Request details: \(String(describing: request), privacy: .public)")

        // Handle request
        let response = await handleRequest(request)
        logger.info("📤 Sending response: success=\(response.success), message=\(response.message ?? "nil", privacy: .public)")
        await sendResponse(socket: socket, response: response)
        logger.info("✅ Response sent to client (fd=\(socket))")
    }

    private func sendResponse(socket: Int32, response: IDERPCResponse) async {
        guard let data = try? JSONEncoder().encode(response) else {
            logger.error("❌ Failed to encode response")
            return
        }

        logger.debug("📤 Encoding response to JSON (\(data.count) bytes)")
        logger.debug("📄 Response JSON: \(String(data: data, encoding: .utf8) ?? "invalid utf8", privacy: .public)")

        let bytesWritten = data.withUnsafeBytes { ptr in
            write(socket, ptr.baseAddress, data.count)
        }

        if bytesWritten != data.count {
            logger.error("❌ Partial write: \(bytesWritten)/\(data.count) bytes written to fd=\(socket)")
        } else {
            logger.info("📤 Successfully wrote \(bytesWritten) bytes to client (fd=\(socket))")
        }
    }

    private func handleRequest(_ request: IDERPCRequest) async -> IDERPCResponse {
        switch request.method {
        case "at_mention":
            return await handleAtMention(request)

        case "send_command":
            return await handleSendCommand(request)

        case "get_sessions":
            return await handleGetSessions(request)

        case "ping":
            return IDERPCResponse(success: true, message: "pong", data: nil)
                                                        
        default:
            return IDERPCResponse(
                success: false,
                message: "Unknown method: \(request.method)",
                data: nil
            )
        }
    }

    // MARK: - Request Handlers

    private func handleAtMention(_ request: IDERPCRequest) async -> IDERPCResponse {
        logger.info("🔍 Handling at_mention request")

        guard let filePath = request.filePath else {
            logger.error("❌ Missing filePath in request")
            return IDERPCResponse(success: false, message: "Missing filePath", data: nil)
        }

        logger.info("📄 File path: \(filePath, privacy: .public)")
        if let start = request.lineStart {
            logger.info("📄 Line start: \(start)")
        }
        if let end = request.lineEnd {
            logger.info("📄 Line end: \(end)")
        }

        // Find the appropriate session to send to
        let sessions = await SessionStore.shared.allSessions()
        logger.info("📊 Found \(sessions.count) total sessions")
        for session in sessions {
            logger.debug("  - Session: \(session.sessionId, privacy: .public), phase: \(String(describing: session.phase))")
        }

        // If sessionId is provided, use that session
        let targetSession: SessionState?
        if let sessionId = request.sessionId {
            logger.info("🎯 Looking for specific session: \(sessionId, privacy: .public)")
            targetSession = sessions.first { $0.sessionId == sessionId }
        } else {
            logger.info("🎯 No specific session requested, looking for most recent active session")
            // Otherwise, find the most recent active session
            targetSession = sessions
                .filter { $0.phase != .ended }
                .sorted { $0.lastActivity > $1.lastActivity }
                .first
            if let target = targetSession {
                logger.info("✅ Selected most recent active session: \(target.sessionId, privacy: .public)")
            } else {
                logger.info("⚠️ No active session found")
            }
        }

        guard let session = targetSession else {
            logger.error("❌ No target session found for at_mention")
            return IDERPCResponse(
                success: false,
                message: "No active Claude session found",
                data: nil
            )
        }

        logger.info("✅ Target session found: \(session.sessionId, privacy: .public)")
        logger.info("📋 Session details: cwd=\(session.cwd, privacy: .public), phase=\(String(describing: session.phase))")

        // Send the file mention to Claude via tmux
        logger.info("🚀 Sending file to session via tmux...")
        let success = await sendFileToSession(
            session: session,
            filePath: filePath,
            lineStart: request.lineStart,
            lineEnd: request.lineEnd
        )

        if success {
            logger.info("✅ Successfully sent file to session \(session.sessionId, privacy: .public)")
            return IDERPCResponse(
                success: true,
                message: "File sent to session \(session.sessionId)",
                data: ["session_id": AnyCodable(session.sessionId)]
            )
        } else {
            logger.error("❌ Failed to send file to session \(session.sessionId, privacy: .public)")
            return IDERPCResponse(
                success: false,
                message: "Failed to send file to Claude",
                data: nil
            )
        }
    }

    private func handleSendCommand(_ request: IDERPCRequest) async -> IDERPCResponse {
        guard let content = request.content else {
            return IDERPCResponse(success: false, message: "Missing content", data: nil)
        }

        let sessions = await SessionStore.shared.allSessions()

        let targetSession: SessionState?
        if let sessionId = request.sessionId {
            targetSession = sessions.first { $0.sessionId == sessionId }
        } else {
            targetSession = sessions
                .filter { $0.phase != .ended }
                .sorted { $0.lastActivity > $1.lastActivity }
                .first
        }

        guard let session = targetSession else {
            return IDERPCResponse(
                success: false,
                message: "No active Claude session found",
                data: nil
            )
        }

        let success = await sendCommandToSession(session: session, command: content)

        return IDERPCResponse(
            success: success,
            message: success ? "Command sent" : "Failed to send command",
            data: success ? ["session_id": AnyCodable(session.sessionId)] : nil
        )
    }

    private func handleGetSessions(_ request: IDERPCRequest) async -> IDERPCResponse {
        let sessions = await SessionStore.shared.allSessions()

        let sessionData = sessions.map { session in
            [
                "session_id": AnyCodable(session.sessionId),
                "cwd": AnyCodable(session.cwd),
                "phase": AnyCodable(String(describing: session.phase)),
                "last_activity": AnyCodable(session.lastActivity.timeIntervalSince1970)
            ]
        }

        return IDERPCResponse(
            success: true,
            message: nil,
            data: ["sessions": AnyCodable(sessionData)]
        )
    }

    // MARK: - Session Communication

    private func sendFileToSession(
        session: SessionState,
        filePath: String,
        lineStart: Int?,
        lineEnd: Int?
    ) async -> Bool {
        // Build the @ mention command
        var mention = "@\(filePath)"
        if let start = lineStart, let end = lineEnd {
            mention += ":\(start)-\(end)"
        } else if let start = lineStart {
            mention += ":\(start)"
        }

        return await sendCommandToSession(session: session, command: mention)
    }

    private func sendCommandToSession(session: SessionState, command: String) async -> Bool {
        // Find the tmux pane for this session
        guard let paneId = session.tmuxPaneId else {
            logger.warning("Session \(session.sessionId, privacy: .public) has no tmux pane ID")
            return false
        }

        guard let target = await TmuxTargetFinder.shared.findTarget(forPaneId: paneId) else {
            logger.error("Failed to find tmux target for pane \(paneId, privacy: .public)")
            return false
        }

        // Send the command to the tmux pane
        // Use `send-keys -l` to send literal text without interpreting special keys
        let success = await TmuxController.shared.sendKeys(
            to: target,
            keys: command,
            literal: true
        )

        if success {
            // Also send Enter key to execute the command
            _ = await TmuxController.shared.sendKeys(
                to: target,
                keys: "Enter",
                literal: false
            )
            logger.info("Sent command to session \(session.sessionId, privacy: .public)")
        } else {
            logger.error("Failed to send command to session \(session.sessionId, privacy: .public)")
        }

        return success
    }
}
