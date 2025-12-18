//
//  DebugFileLogger.swift
//  ClaudeIsland
//
//  File-based debug logger for development diagnostics.
//

import Dispatch
import Foundation

enum DebugLogLevel: String {
    case start = "START"
    case end = "END"
    case info = "INFO"
    case debug = "DEBUG"
    case warn = "WARN"
    case error = "ERROR"
}

final class DebugFileLogger {
    static let shared = DebugFileLogger()

    private let queue = DispatchQueue(label: "com.claudeisland.debugfilelogger")
    private var startedAt: Date?
    private var didWriteEndLine = false
    private var logURL: URL {
        resolveLogDirectory()
            .appendingPathComponent("debug_log.txt", isDirectory: false)
    }

    /// Environment override to force a specific log directory.
    /// Recommended: set this to your repo root when running via Xcode.
    private let logDirEnvKey = "CLAUDE_ISLAND_DEBUG_LOG_DIR"

    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private init() {}

    func startNewLog() {
        queue.sync {
            startedAt = Date()
            didWriteEndLine = false

            let url = logURL
            let path = url.path

            prepareLogFile(at: url)

            if FileManager.default.fileExists(atPath: path) {
                do {
                    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
                    try FileManager.default.removeItem(at: url)
                    writeLine(.info, "Delete old log file", "path=\(path), size=\(size.map(String.init) ?? "unknown")")
                } catch {
                    writeLine(.warn, "Delete old log file failed", "path=\(path), error=\(String(describing: error))")
                }
            }

            do {
                FileManager.default.createFile(atPath: path, contents: nil)
                writeLine(.start, "========== 任务开始 ==========", "path=\(path)")
                writeLine(.debug, "Environment", redactAndFormatEnv(Foundation.ProcessInfo.processInfo.environment))
                writeLine(.info, "Process", "name=\(Foundation.ProcessInfo.processInfo.processName), pid=\(Foundation.ProcessInfo.processInfo.processIdentifier), cwd=\(FileManager.default.currentDirectoryPath)")
            } catch {
                writeLine(.error, "Create new log file failed", "path=\(path), error=\(String(describing: error))")
            }
        }
    }

    func endLog(success: Bool = true) {
        queue.sync {
            if didWriteEndLine {
                return
            }

            let elapsedMs: Int
            if let startedAt {
                elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            } else {
                elapsedMs = -1
            }
            let status = success ? "任务完成" : "任务失败"
            writeLine(.end, "========== \(status) | 总耗时: \(elapsedMs)ms ==========", "path=\(logURL.path)")
            didWriteEndLine = true
        }
    }

    func info(_ operation: String, _ details: String? = nil) {
        log(.info, operation, details)
    }

    func debug(_ operation: String, _ details: String? = nil) {
        log(.debug, operation, details)
    }

    func warn(_ operation: String, _ details: String? = nil) {
        log(.warn, operation, details)
    }

    func error(_ operation: String, _ details: String? = nil) {
        log(.error, operation, details)
    }

    func log(_ level: DebugLogLevel, _ operation: String, _ details: String? = nil) {
        queue.async {
            self.writeLine(level, operation, details)
        }
    }

    // MARK: - Private

    private func resolveLogDirectory() -> URL {
        // 1) Explicit override (best option)
        if let dir = Foundation.ProcessInfo.processInfo.environment[logDirEnvKey], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }

        // 2) Prefer repo root derived from source path when available on this machine
        let repoRootCandidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Utilities
            .deletingLastPathComponent() // ClaudeIsland
            .deletingLastPathComponent() // repo root
        let marker = repoRootCandidate.appendingPathComponent("ClaudeIsland.xcodeproj", isDirectory: true)
        if FileManager.default.fileExists(atPath: marker.path),
           FileManager.default.isWritableFile(atPath: repoRootCandidate.path) {
            return repoRootCandidate
        }

        // 3) Fallback to current working directory (may be `/` for GUI apps)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        if FileManager.default.isWritableFile(atPath: cwd.path) {
            return cwd
        }

        // 4) Last resort: user logs directory (always writable)
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClaudeIsland", isDirectory: true)
        return logs
    }

    private func prepareLogFile(at url: URL) {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            // If we can't create the directory, there isn't a useful place to write logs.
            return
        }
    }

    private func writeLine(_ level: DebugLogLevel, _ operation: String, _ details: String?) {
        let timestamp = timestampFormatter.string(from: Date())
        let detailPart = details.map { ": \($0)" } ?? ""
        let line = "[\(timestamp)] [\(level.rawValue)] \(operation)\(detailPart)\n"

        guard let data = line.data(using: .utf8) else { return }

        do {
            if FileManager.default.fileExists(atPath: logURL.path) == false {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Intentionally ignore file logging failures to avoid crashing the app.
        }
    }

    private func redactAndFormatEnv(_ env: [String: String]) -> String {
        let redactedKeys = ["TOKEN", "KEY", "SECRET", "PASSWORD", "AUTH", "AUTHORIZATION"]
        let sortedKeys = env.keys.sorted()
        var parts: [String] = []
        parts.reserveCapacity(sortedKeys.count)

        for key in sortedKeys {
            let value = env[key] ?? ""
            let upperKey = key.uppercased()
            let shouldRedact = redactedKeys.contains { upperKey.contains($0) }
            let safeValue = shouldRedact ? "[REDACTED]" : value
            parts.append("\(key)=\(safeValue)")
        }

        let joined = parts.joined(separator: ", ")
        if joined.count <= 2000 {
            return joined
        }
        return "count=\(parts.count), preview=\(joined.prefix(2000))..."
    }
}
