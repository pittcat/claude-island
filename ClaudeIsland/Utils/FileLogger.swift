//
//  FileLogger.swift
//  ClaudeIsland
//
//  Unified file logging system for debugging
//

import Foundation
import OSLog

/// Thread-safe file logger for debugging
/// Logs are written to ~/Library/Logs/ClaudeIsland/debug.log
/// Log file is cleared on each app launch
@MainActor
class FileLogger {
    static let shared = FileLogger()

    private let logFileURL: URL
    private let fileHandle: FileHandle?

    private init() {
        // Set log directory path
        let logsDir = URL(fileURLWithPath: "/Users/pittcat/Dev/swift/claude-island/log")

        // Create logs directory if it doesn't exist
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // Set log file path (fixed filename: debug.log)
        self.logFileURL = logsDir.appendingPathComponent("debug.log")

        // Clear previous log file on startup
        try? "".write(to: logFileURL, atomically: true, encoding: .utf8)

        // Create file handle for appending
        self.fileHandle = try? FileHandle(forWritingTo: logFileURL)

        // Write startup marker
        let startupMessage = """
        \n=== Claude Island Debug Log Started at \(Date()) ===\n\n
        """
        writeToLog(startupMessage)
    }

    deinit {
        fileHandle?.closeFile()
    }

    /// Write a debug log message with timestamp
    func debug(_ message: String, category: String = "General") {
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        let logMessage = "[\(timestamp)] [DEBUG] [\(category)] \(message)\n"
        writeToLog(logMessage)
    }

    /// Write a warning log message with timestamp
    func warning(_ message: String, category: String = "General") {
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        let logMessage = "[\(timestamp)] [WARNING] [\(category)] \(message)\n"
        writeToLog(logMessage)
    }

    /// Write an error log message with timestamp
    func error(_ message: String, category: String = "General") {
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        let logMessage = "[\(timestamp)] [ERROR] [\(category)] \(message)\n"
        writeToLog(logMessage)
    }

    /// Write info log message with timestamp
    func info(_ message: String, category: String = "General") {
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        let logMessage = "[\(timestamp)] [INFO] [\(category)] \(message)\n"
        writeToLog(logMessage)
    }

    /// Internal method to write to file (thread-safe)
    private func writeToLog(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }

        // Write to file handle if available
        if let fileHandle = fileHandle {
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
        } else {
            // Fallback: append to file directly
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: logFileURL.path) {
                let fileHandle = try? FileHandle(forWritingTo: logFileURL)
                fileHandle?.seekToEndOfFile()
                fileHandle?.write(data)
                fileHandle?.closeFile()
            } else {
                try? data.write(to: logFileURL)
            }
        }

        // Also write to Console for immediate visibility
        os_log("%{public}s", log: OSLog(subsystem: "codes.pittscraft.claudeisland", category: "FileLogger"), message)
    }

    /// Get the log file URL
    func getLogFileURL() -> URL {
        return logFileURL
    }
}

/// DateFormatter extension for consistent timestamp formatting
extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()
}
