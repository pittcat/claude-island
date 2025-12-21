//
//  SessionStalePruner.swift
//  ClaudeIsland
//
//  Deletes stale sessions that appear disconnected and no longer have a running PID.
//

import Foundation

actor SessionStalePruner {
    static let shared = SessionStalePruner()

    private let checkInterval: TimeInterval = 30.0

    private var monitoringTask: Task<Void, Never>?
    private var isMonitoring = false

    private init() {}

    func startMonitoring() async {
        guard !isMonitoring else { return }
        isMonitoring = true

        monitoringTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                await self.performSweep()
                try? await Task.sleep(nanoseconds: UInt64(self.checkInterval * 1_000_000_000))
            }
        }
    }

    func stopMonitoring() async {
        guard isMonitoring else { return }
        isMonitoring = false
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    private func performSweep() async {
        let minutes = AppSettings.staleSessionCleanupMinutes
        let thresholdSeconds = TimeInterval(minutes * 60)

        let sessions = await SessionStore.shared.allSessions()
        guard !sessions.isEmpty else { return }

        let tree = ProcessTreeBuilder.shared.buildTree()
        let now = Date()

        for session in sessions {
            let pidMissing: Bool = {
                guard let pid = session.pid else { return false }
                return tree[pid] == nil
            }()

            let isCandidate =
                session.isInNeovim &&
                session.neovimConnectionStatus == .disconnected &&
                pidMissing

            await SessionStore.shared.process(.staleCleanupCandidateEvaluated(
                sessionId: session.sessionId,
                isCandidate: isCandidate,
                evaluatedAt: now,
                thresholdSeconds: thresholdSeconds
            ))
        }
    }
}

