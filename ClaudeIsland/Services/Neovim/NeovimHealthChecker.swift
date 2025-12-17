//
//  NeovimHealthChecker.swift
//  ClaudeIsland
//
//  Periodic health checker for Neovim connections.
//  Monitors sessions running inside Neovim terminals and updates their connection status.
//

import Foundation
import OSLog

/// Actor that periodically checks Neovim connection health for all relevant sessions
actor NeovimHealthChecker {
    static let shared = NeovimHealthChecker()

    private let logger = Logger(subsystem: "codes.pittscraft.claudeisland", category: "NeovimHealthChecker")

    // MARK: - Configuration

    /// How often to check connections (in seconds)
    private let checkInterval: TimeInterval = 30.0

    /// Task handle for the monitoring loop
    private var monitoringTask: Task<Void, Never>?

    /// Whether monitoring is currently active
    private var isMonitoring = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Start periodic health checking
    func startMonitoring() {
        guard !isMonitoring else {
            logger.debug("Health checker already running")
            return
        }

        isMonitoring = true
        logger.info("Starting Neovim health checker (interval: \(self.checkInterval)s)")

        monitoringTask = Task { [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled {
                await self.performHealthCheck()

                // Wait for next check interval
                try? await Task.sleep(nanoseconds: UInt64(self.checkInterval * 1_000_000_000))
            }
        }
    }

    /// Stop periodic health checking
    func stopMonitoring() {
        guard isMonitoring else { return }

        isMonitoring = false
        monitoringTask?.cancel()
        monitoringTask = nil
        logger.info("Stopped Neovim health checker")
    }

    /// Check a specific session's Neovim connection
    func checkSession(_ sessionId: String) async {
        guard let session = await SessionStore.shared.session(for: sessionId) else {
            logger.debug("Session not found for health check: \(sessionId.prefix(8))")
            return
        }

        guard session.isInNeovim else {
            return // Not a Neovim session, nothing to check
        }

        await checkSessionConnection(session)
    }

    // MARK: - Private Implementation

    /// Perform health check on all Neovim sessions
    private func performHealthCheck() async {
        let allSessions = await SessionStore.shared.allSessions()

        // Filter to only Neovim sessions
        let neovimSessions = allSessions.filter { $0.isInNeovim }

        guard !neovimSessions.isEmpty else {
            return // No Neovim sessions to check
        }

        logger.debug("Checking \(neovimSessions.count) Neovim session(s)")

        // Check each session concurrently
        await withTaskGroup(of: Void.self) { group in
            for session in neovimSessions {
                group.addTask {
                    await self.checkSessionConnection(session)
                }
            }
        }
    }

    /// Check a single session's connection and update status
    private func checkSessionConnection(_ session: SessionState) async {
        let sessionId = session.sessionId

        // Dispatch checking status event
        await SessionStore.shared.process(.neovimStatusChanged(
            sessionId: sessionId,
            status: .checking
        ))

        do {
            let isConnected = try await NeovimBridge.shared.checkConnection(
                listenAddress: session.nvimListenAddress,
                nvimPid: session.nvimPid
            )

            let newStatus: NeovimConnectionStatus = isConnected ? .connected : .disconnected

            await SessionStore.shared.process(.neovimStatusChanged(
                sessionId: sessionId,
                status: newStatus
            ))

            if isConnected {
                logger.debug("Session \(sessionId.prefix(8)): Neovim connected")
            } else {
                logger.warning("Session \(sessionId.prefix(8)): Neovim ping failed")
            }
        } catch {
            logger.warning("Session \(sessionId.prefix(8)): Health check error - \(error.localizedDescription)")

            await SessionStore.shared.process(.neovimStatusChanged(
                sessionId: sessionId,
                status: .disconnected
            ))
        }
    }
}
