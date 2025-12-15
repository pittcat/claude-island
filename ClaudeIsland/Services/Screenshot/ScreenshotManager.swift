//
//  ScreenshotManager.swift
//  ClaudeIsland
//
//  Unified manager for all screenshot-related functionality
//

import Foundation
import os.log
import AppKit
import Combine

/// Unified manager for screenshot operations
@MainActor
final class ScreenshotManager: ObservableObject {
    private let logger = Logger(subsystem: "com.claudeisland", category: "ScreenshotManager")
    
    private let screenshotService: ScreenshotCapturing
    private let notificationService: ScreenshotNotifying
    private let clipboardService: ClipboardManaging
    private let hotkeyService: ScreenshotHotkeyManaging
    
    @Published var isCapturing = false
    @Published var lastScreenshotPath: String?
    @Published var errorMessage: String?
    
    init(
        screenshotService: ScreenshotCapturing? = nil,
        notificationService: ScreenshotNotifying? = nil,
        clipboardService: ClipboardManaging? = nil,
        hotkeyService: ScreenshotHotkeyManaging? = nil
    ) {
        self.screenshotService = screenshotService ?? ScreenshotService()
        self.notificationService = notificationService ?? ScreenshotNotificationService()
        self.clipboardService = clipboardService ?? ClipboardService()
        self.hotkeyService = hotkeyService ?? ScreenshotHotkeyService.shared

        // Setup hotkey service callback
        if let hotkeyService = self.hotkeyService as? ScreenshotHotkeyService {
            hotkeyService.setScreenshotHandler { [weak self] in
                await self?.captureScreenshot()
            }
        }

        logger.info("ScreenshotManager initialized")
    }
    
    /// Capture a screenshot and copy path to clipboard
    func captureScreenshot() async {
        logger.info("Starting screenshot capture")
        
        isCapturing = true
        errorMessage = nil
        
        do {
            // Capture screenshot
            let result = try await screenshotService.captureInteractive()
            
            // Copy path to clipboard with @ prefix for file mention
            let pathWithMention = "@\(result.filePath)"
            let success = clipboardService.copyToClipboard(pathWithMention)
            
            if success {
                lastScreenshotPath = result.filePath
                
                // Show success notification
                notificationService.showScreenshotCopiedNotification(path: result.filePath)
                
                logger.info("Screenshot captured and path copied: \(result.filePath, privacy: .public)")
            } else {
                // Clipboard copy failed but screenshot succeeded
                lastScreenshotPath = result.filePath
                notificationService.showErrorAlert(.unexpectedError("Screenshot saved but failed to copy path to clipboard"))
            }
            
        } catch let error as ScreenshotError {
            handleScreenshotError(error)
        } catch {
            logger.error("Unexpected error during screenshot: \(error.localizedDescription, privacy: .public)")
            notificationService.showErrorAlert(.unexpectedError(error.localizedDescription))
        }
        
        isCapturing = false
    }
    
    /// Capture screenshot and show detailed success alert
    func captureScreenshotWithAlert() async {
        await captureScreenshot()
        
        // Show additional success alert after capture
        if let path = lastScreenshotPath {
            notificationService.showSuccessAlert(path: path)
        }
    }
    
    /// Register global hotkey
    func registerHotkey() -> Bool {
        guard let hotkeyService = hotkeyService as? ScreenshotHotkeyService else {
            logger.warning("Hotkey service is not ScreenshotHotkeyService type")
            return false
        }
        
        let result = hotkeyService.registerHotkey()
        
        switch result {
        case .success:
            logger.info("Global hotkey registered successfully")
            return true
        case .alreadyRegistered:
            logger.info("Global hotkey already registered")
            return true
        case .failed(let message):
            logger.error("Failed to register global hotkey: \(message, privacy: .public)")
            return false
        }
    }
    
    /// Unregister global hotkey
    func unregisterHotkey() {
        hotkeyService.unregisterHotkey()
        logger.info("Global hotkey unregistered")
    }
    
    /// Check if hotkey is registered
    var isHotkeyRegistered: Bool {
        return hotkeyService.isHotkeyRegistered()
    }
    
    /// Clean up old screenshots manually
    func cleanupOldScreenshots() async {
        do {
            try await screenshotService.cleanupOldScreenshots(keeping: 50)
            logger.info("Manual cleanup of old screenshots completed")
        } catch {
            logger.error("Failed to cleanup old screenshots: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    // MARK: - Private Methods
    
    private func handleScreenshotError(_ error: ScreenshotError) {
        switch error {
        case .permissionDenied:
            notificationService.showPermissionDeniedAlert()
            errorMessage = "Screen recording permission denied"
            
        case .cancelled:
            // Silent cancellation - no error message
            logger.info("Screenshot cancelled by user")
            
        case .directoryCreationFailed(let path, let underlying):
            notificationService.showErrorAlert(.directoryCreationFailed(path: path, underlying: underlying))
            errorMessage = "Failed to create screenshot directory"
            
        case .screenshotFailed(let underlying):
            notificationService.showErrorAlert(.screenshotFailed(underlying: underlying))
            errorMessage = "Screenshot failed"
            
        case .fileNotCreated:
            notificationService.showErrorAlert(.fileNotCreated)
            errorMessage = "Screenshot file was not created"
            
        case .unexpectedError(let message):
            notificationService.showErrorAlert(.unexpectedError(message))
            errorMessage = message
        }
        
        logger.error("Screenshot error: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - Global Instance

extension ScreenshotManager {
    /// Shared instance of ScreenshotManager
    @MainActor static let shared = ScreenshotManager()
}

// MARK: - Convenience Methods

extension ScreenshotManager {
    /// Get the screenshot directory path
    var screenshotDirectoryPath: String {
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, 
                                                   in: .userDomainMask).first!
        return appSupportDir
            .appendingPathComponent("ClaudeIsland")
            .appendingPathComponent("Screenshots")
            .path
    }
    
    /// Get recent screenshots (most recent 10)
    var recentScreenshots: [URL] {
        let fileManager = FileManager.default
        let screenshotDir = URL(fileURLWithPath: screenshotDirectoryPath)
        
        guard let contents = try? fileManager.contentsOfDirectory(
            at: screenshotDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        
        let pngFiles = contents.filter { $0.pathExtension == "png" }
        
        return (try? pngFiles.sorted { file1, file2 in
            let date1 = try file1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date.distantPast
            let date2 = try file2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date.distantPast
            return date1 > date2
        })?.prefix(10).map { $0 } ?? []
    }
}
