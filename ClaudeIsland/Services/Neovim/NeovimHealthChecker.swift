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
    func startMonitoring() async {
        guard !isMonitoring else {
            await MainActor.run {
            }
            return
        }

        isMonitoring = true
        await MainActor.run {
        }

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
    func stopMonitoring() async {
        guard isMonitoring else { return }

        isMonitoring = false
        monitoringTask?.cancel()
        monitoringTask = nil
        await MainActor.run {
        }
    }

    /// Check a specific session's Neovim connection
    func checkSession(_ sessionId: String) async {
        guard let session = await SessionStore.shared.session(for: sessionId) else {
            await MainActor.run {
            }
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

        await MainActor.run {
        }

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

        await MainActor.run {
        }

        // Dispatch checking status event
        await SessionStore.shared.process(.neovimStatusChanged(
            sessionId: sessionId,
            status: .checking
        ))

        await MainActor.run {
        }

        do {
            let isConnected = try await NeovimBridge.shared.checkConnection(
                listenAddress: session.nvimListenAddress,
                nvimPid: session.nvimPid
            )

            let newStatus: NeovimConnectionStatus = isConnected ? .connected : .disconnected

            await MainActor.run {
            }

            await SessionStore.shared.process(.neovimStatusChanged(
                sessionId: sessionId,
                status: newStatus
            ))

            if isConnected {
                await MainActor.run {
                }
            } else {
                await MainActor.run {
                }
            }
        } catch {
            await MainActor.run {
            }

            await SessionStore.shared.process(.neovimStatusChanged(
                sessionId: sessionId,
                status: .disconnected
            ))
        }
    }
}
