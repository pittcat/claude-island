//
//  ClaudeProjectPath.swift
//  ClaudeIsland
//
//  Shared helpers for mapping a working directory to Claude Code's
//  ~/.claude/projects/<projectDir>/ naming scheme.
//

import Foundation

struct ClaudeProjectPath {
    static func projectDirName(forWorkingDirectory cwd: String) -> String {
        cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }

    static func sessionFilePath(sessionId: String, cwd: String) -> String {
        let projectDir = projectDirName(forWorkingDirectory: cwd)
        return NSHomeDirectory() + "/.claude/projects/" + projectDir + "/" + sessionId + ".jsonl"
    }

    static func agentFilePath(agentId: String, cwd: String) -> String {
        let projectDir = projectDirName(forWorkingDirectory: cwd)
        return NSHomeDirectory() + "/.claude/projects/" + projectDir + "/agent-" + agentId + ".jsonl"
    }
}

