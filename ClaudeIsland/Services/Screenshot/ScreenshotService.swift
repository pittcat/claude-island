//
//  ScreenshotService.swift
//  ClaudeIsland
//
//  Service for handling screenshot capture using screencapture
//

import Foundation
import os.log
import AppKit

/// Errors that can occur during screenshot capture
enum ScreenshotError: Error, LocalizedError {
    case directoryCreationFailed(path: String, underlying: Error)
    case screenshotFailed(underlying: ProcessExecutorError)
    case permissionDenied
    case cancelled
    case fileNotCreated
    case unexpectedError(String)

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let path, let underlying):
            return "Failed to create screenshot directory at \(path): \(underlying.localizedDescription)"
        case .screenshotFailed(let underlying):
            return "Screenshot failed: \(underlying.localizedDescription)"
        case .permissionDenied:
            return "Screen recording permission denied"
        case .cancelled:
            return "Screenshot cancelled by user"
        case .fileNotCreated:
            return "Screenshot file was not created"
        case .unexpectedError(let message):
            return "Unexpected error: \(message)"
        }
    }
}

/// Result type for screenshot capture
struct ScreenshotResult: Sendable {
    let fileURL: URL
    let filePath: String
    let timestamp: Date
}

/// Protocol for screenshot capture operations
protocol ScreenshotCapturing: Sendable {
    func captureInteractive() async throws -> ScreenshotResult
    func cleanupOldScreenshots(keeping count: Int) async throws
}

/// Service for handling screenshot capture
actor ScreenshotService: ScreenshotCapturing {
    private let processExecutor: ProcessExecuting
    private let logger = Logger(subsystem: "com.claudeisland", category: "ScreenshotService")
    
    private let screenshotDirectory: URL
    private let maxScreenshotCount: Int
    
    init(processExecutor: ProcessExecuting = ProcessExecutor.shared, maxScreenshotCount: Int = 50) {
        self.processExecutor = processExecutor

        // Save screenshots to Desktop
        let desktopDir = FileManager.default.urls(for: .desktopDirectory,
                                                   in: .userDomainMask).first!
        self.screenshotDirectory = desktopDir
        self.maxScreenshotCount = maxScreenshotCount
    }
    
    /// Capture an interactive screenshot
    func captureInteractive() async throws -> ScreenshotResult {
        // Ensure directory exists
        try await ensureDirectoryExists()
        
        // Generate unique file path
        let timestamp = Date()
        let fileName = "screenshot_\(Self.formatTimestamp(timestamp)).png"
        let fileURL = screenshotDirectory.appendingPathComponent(fileName)
        let filePath = fileURL.path
        
        logger.info("Starting screenshot capture to \(filePath, privacy: .public)")
        
        // Execute screencapture command
        let arguments = [
            "-i",           // Interactive
            "-x",           // No sound
            "-t", "png",    // PNG format
            filePath        // Output path
        ]
        
        do {
            try await processExecutor.run("/usr/sbin/screencapture", arguments: arguments)
        } catch let error as ProcessExecutorError {
            // Check if file was actually created despite error (user cancellation)
            if FileManager.default.fileExists(atPath: filePath) {
                let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
                if let fileSize = attributes[.size] as? Int64, fileSize > 0 {
                    logger.info("Screenshot captured successfully despite error")
                    return ScreenshotResult(fileURL: fileURL, filePath: filePath, timestamp: timestamp)
                }
            }
            
            // Handle specific error cases
            if isPermissionDeniedError(error) {
                logger.warning("Screen recording permission denied")
                throw ScreenshotError.permissionDenied
            } else if isCancellationError(error) {
                logger.info("Screenshot cancelled by user")
                throw ScreenshotError.cancelled
            } else {
                logger.error("Screenshot failed: \(error.localizedDescription, privacy: .public)")
                throw ScreenshotError.screenshotFailed(underlying: error)
            }
        }
        
        // Verify file was created and has content
        // Note: If screencapture succeeds (exit code 0) but no file is created,
        // it means user cancelled the screenshot (pressed Esc or clicked outside)
        guard FileManager.default.fileExists(atPath: filePath) else {
            logger.info("Screenshot cancelled by user (no file created)")
            throw ScreenshotError.cancelled
        }
        
        let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
        guard let fileSize = attributes[.size] as? Int64, fileSize > 0 else {
            logger.error("Screenshot file is empty")
            try FileManager.default.removeItem(at: fileURL)
            throw ScreenshotError.fileNotCreated
        }
        
        logger.info("Screenshot captured successfully at \(filePath, privacy: .public)")
        
        // Cleanup old screenshots
        do {
            try await cleanupOldScreenshots(keeping: maxScreenshotCount)
        } catch {
            logger.warning("Failed to cleanup old screenshots: \(error.localizedDescription, privacy: .public)")
            // Don't fail the main operation if cleanup fails
        }
        
        return ScreenshotResult(fileURL: fileURL, filePath: filePath, timestamp: timestamp)
    }
    
    /// Clean up old screenshots, keeping only the most recent ones
    func cleanupOldScreenshots(keeping count: Int) async throws {
        let fileManager = FileManager.default
        
        // Get all screenshot files
        let contents = try fileManager.contentsOfDirectory(
            at: screenshotDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        
        // Filter to only PNG files
        let pngFiles = contents.filter { $0.pathExtension == "png" }
        
        guard pngFiles.count > count else {
            return // No need to cleanup
        }
        
        // Sort by modification date (newest first)
        let sortedFiles = try pngFiles.sorted { file1, file2 in
            let date1 = try file1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date.distantPast
            let date2 = try file2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date.distantPast
            return date1 > date2
        }
        
        // Remove files beyond the keep count
        let filesToRemove = sortedFiles.dropFirst(count)
        for file in filesToRemove {
            do {
                try fileManager.removeItem(at: file)
                logger.info("Removed old screenshot: \(file.lastPathComponent, privacy: .public)")
            } catch {
                logger.warning("Failed to remove old screenshot \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func ensureDirectoryExists() async throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: screenshotDirectory.path) {
            do {
                try fileManager.createDirectory(
                    at: screenshotDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                logger.info("Created screenshot directory: \(self.screenshotDirectory.path, privacy: .public)")
            } catch {
                logger.error("Failed to create screenshot directory: \(error.localizedDescription, privacy: .public)")
                throw ScreenshotError.directoryCreationFailed(
                    path: screenshotDirectory.path,
                    underlying: error
                )
            }
        }
    }
    
    private func isPermissionDeniedError(_ error: ProcessExecutorError) -> Bool {
        // screencapture returns specific exit codes for permission issues
        // We need to check stderr for specific indicators
        if case .executionFailed(_, _, let stderr) = error {
            if let stderr = stderr, !stderr.isEmpty {
                return stderr.localizedCaseInsensitiveContains("denied") ||
                       stderr.localizedCaseInsensitiveContains("permission") ||
                       stderr.localizedCaseInsensitiveContains("auth")
            }
        }
        return false
    }

    private func isCancellationError(_ error: ProcessExecutorError) -> Bool {
        // User cancellation: exit code 1 with empty or no stderr
        // This is the most common case when user presses Esc
        if case .executionFailed(_, let exitCode, let stderr) = error {
            if exitCode == 1 {
                // If stderr is empty or nil, it's likely a user cancellation
                let stderrEmpty = stderr?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
                return stderrEmpty
            }
        }
        return false
    }
    
    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss_SSS"
        return formatter.string(from: date)
    }
}
