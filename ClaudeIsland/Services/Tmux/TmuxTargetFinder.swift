//
//  TmuxTargetFinder.swift
//  ClaudeIsland
//
//  Finds tmux targets for Claude processes
//

import Foundation
import os.log

/// Finds tmux session/window/pane targets for Claude processes
actor TmuxTargetFinder {
    static let shared = TmuxTargetFinder()

    private let logger = Logger(subsystem: "com.claudeisland", category: "TmuxTargetFinder")

    private init() {}

    /// Find a tmux target by pane ID (e.g. "%1")
    func findTarget(forPaneId paneId: String) async -> TmuxTarget? {
        guard !paneId.isEmpty else { return nil }

        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        guard let output = await runTmuxCommand(tmuxPath: tmuxPath, args: [
            "list-panes", "-a", "-F", "#{pane_id} #{session_name}:#{window_index}.#{pane_index}"
        ]) else {
            return nil
        }

        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let listedPaneId = String(parts[0])
            guard listedPaneId == paneId else { continue }

            let targetString = String(parts[1])
            return TmuxTarget(from: targetString)
        }

        return nil
    }

    /// Find the tmux target for a given Claude PID
    func findTarget(forClaudePid claudePid: Int) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        guard let output = await runTmuxCommand(tmuxPath: tmuxPath, args: [
            "list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_pid}"
        ]) else {
            return nil
        }

        let tree = ProcessTreeBuilder.shared.buildTree()

        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2,
                  let panePid = Int(parts[1]) else { continue }

            let targetString = String(parts[0])

            if ProcessTreeBuilder.shared.isDescendant(targetPid: claudePid, ofAncestor: panePid, tree: tree) {
                return TmuxTarget(from: targetString)
            }
        }

        return nil
    }

    /// Find the tmux target for a given working directory
    func findTarget(forWorkingDirectory workingDir: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        guard let output = await runTmuxCommand(tmuxPath: tmuxPath, args: [
            "list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_current_path}"
        ]) else {
            return nil
        }

        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let targetString = String(parts[0])
            let panePath = String(parts[1])

            if panePath == workingDir {
                return TmuxTarget(from: targetString)
            }
        }

        return nil
    }

    /// Check if a session's tmux pane is currently the active pane
    func isSessionPaneActive(claudePid: Int) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return false
        }

        // Find which pane the Claude session is in
        guard let sessionTarget = await findTarget(forClaudePid: claudePid) else {
            return false
        }

        // Get the currently active pane
        guard let output = await runTmuxCommand(tmuxPath: tmuxPath, args: [
            "display-message", "-p", "#{session_name}:#{window_index}.#{pane_index}"
        ]) else {
            return false
        }

        let activeTarget = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessionTarget.targetString == activeTarget
    }

    /// Find target in all tmux sessions by working directory
    func findTargetInAllSessions(forWorkingDirectory workingDir: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        // Get all tmux session info
        let sessionsResult = await runTmuxCommand(tmuxPath: tmuxPath, args: ["list-sessions", "-F", "#{session_name}"])
        guard let sessionsOutput = sessionsResult else {
            return nil
        }

        let sessionNames = sessionsOutput.components(separatedBy: "\n").filter { !$0.isEmpty }

        for sessionName in sessionNames {
            logger.debug("Searching session: \(sessionName)")

            // Find matching pane in each session
            if let target = await findTargetInSession(sessionName: sessionName, workingDir: workingDir, tmuxPath: tmuxPath) {
                return target
            }
        }

        return nil
    }

    /// Find matching pane in a specific session
    private func findTargetInSession(sessionName: String, workingDir: String, tmuxPath: String) async -> TmuxTarget? {
        let result = await runTmuxCommand(tmuxPath: tmuxPath, args: [
            "list-panes", "-t", sessionName, "-F",
            "#{window_index}.#{pane_index} #{pane_current_path}"
        ])

        guard let output = result else {
            return nil
        }

        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let targetString = String(parts[0])
            let panePath = String(parts[1])

            if panePath == workingDir {
                return TmuxTarget(from: "\(sessionName):\(targetString)")
            }
        }

        return nil
    }

    // MARK: - Private Methods

    private func runTmuxCommand(tmuxPath: String, args: [String]) async -> String? {
        do {
            return try await ProcessExecutor.shared.run(tmuxPath, arguments: args)
        } catch {
            return nil
        }
    }
}
