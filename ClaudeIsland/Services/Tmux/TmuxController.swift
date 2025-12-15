//
//  TmuxController.swift
//  ClaudeIsland
//
//  High-level tmux operations controller
//

import Foundation

/// Controller for tmux operations
actor TmuxController {
    static let shared = TmuxController()

    private init() {}

    func findTmuxTarget(forClaudePid pid: Int) async -> TmuxTarget? {
        await TmuxTargetFinder.shared.findTarget(forClaudePid: pid)
    }

    func findTmuxTarget(forPaneId paneId: String) async -> TmuxTarget? {
        await TmuxTargetFinder.shared.findTarget(forPaneId: paneId)
    }

    func findTmuxTarget(forWorkingDirectory dir: String) async -> TmuxTarget? {
        await TmuxTargetFinder.shared.findTarget(forWorkingDirectory: dir)
    }

    func sendMessage(_ message: String, to target: TmuxTarget) async -> Bool {
        await ToolApprovalHandler.shared.sendMessage(message, to: target)
    }

    func approveOnce(target: TmuxTarget) async -> Bool {
        await ToolApprovalHandler.shared.approveOnce(target: target)
    }

    func approveAlways(target: TmuxTarget) async -> Bool {
        await ToolApprovalHandler.shared.approveAlways(target: target)
    }

    func reject(target: TmuxTarget, message: String? = nil) async -> Bool {
        await ToolApprovalHandler.shared.reject(target: target, message: message)
    }

    func switchToPane(target: TmuxTarget) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return false
        }

        do {
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "select-window", "-t", "\(target.session):\(target.window)"
            ])

            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "select-pane", "-t", target.targetString
            ])

            return true
        } catch {
            return false
        }
    }

    /// Send keys to a tmux pane
    /// - Parameters:
    ///   - target: The tmux target to send keys to
    ///   - keys: The keys/text to send
    ///   - literal: If true, send as literal text (using -l flag), otherwise interpret special keys
    /// - Returns: True if successful
    func sendKeys(to target: TmuxTarget, keys: String, literal: Bool = false) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return false
        }

        var args = ["send-keys", "-t", target.targetString]
        if literal {
            args.append("-l")
        }
        args.append(keys)

        do {
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: args)
            return true
        } catch {
            return false
        }
    }
}
