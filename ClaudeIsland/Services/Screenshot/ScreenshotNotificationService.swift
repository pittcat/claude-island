//
//  ScreenshotNotificationService.swift
//  ClaudeIsland
//
//  Service for displaying toast notifications and alerts for screenshot operations
//

import Foundation
import os.log
import AppKit

/// Protocol for notification operations
protocol ScreenshotNotifying: Sendable {
    func showScreenshotCopiedNotification(path: String)
    func showPermissionDeniedAlert()
    func showErrorAlert(_ error: ScreenshotError)
    func showSuccessAlert(path: String)
}

/// Service for handling screenshot-related notifications
@MainActor
final class ScreenshotNotificationService: ScreenshotNotifying {
    private let logger = Logger(subsystem: "com.claudeisland", category: "ScreenshotNotification")
    
    // UserDefaults key for tracking if permission alert has been shown
    private let permissionAlertShownKey = "ScreenshotPermissionAlertShown"
    
    init() {}
    
    /// Show a toast notification that screenshot path was copied
    func showScreenshotCopiedNotification(path: String) {
        // Use lightweight logging instead of NSUserNotification
        // NSUserNotification may trigger system permission dialogs
        logger.info("Screenshot captured and path copied: \(path, privacy: .public)")

        // Play a subtle sound to indicate success (optional)
        NSSound.beep()
    }
    
    /// Show permission denied alert (one-time)
    func showPermissionDeniedAlert() {
        let hasShownBefore = UserDefaults.standard.bool(forKey: permissionAlertShownKey)
        
        if !hasShownBefore {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Screen Recording Permission Required"
            alert.informativeText = """
            To capture screenshots, Claude Island needs screen recording permission.
            
            Please enable it in:
            System Settings → Privacy & Security → Screen Recording
            
            Then restart Claude Island.
            """
            alert.runModal()
            
            UserDefaults.standard.set(true, forKey: permissionAlertShownKey)
            logger.info("Displayed permission denied alert")
        } else {
            // Show a lighter notification for subsequent attempts
            let notification = NSUserNotification()
            notification.title = "Permission Required"
            notification.subtitle = "Screen recording permission is needed"
            notification.informativeText = "Check System Settings → Privacy & Security"
            
            NSUserNotificationCenter.default.deliver(notification)
            logger.info("Displayed lightweight permission notification")
        }
    }
    
    /// Show error alert with appropriate message
    func showErrorAlert(_ error: ScreenshotError) {
        switch error {
        case .permissionDenied:
            showPermissionDeniedAlert()
            
        case .cancelled:
            // Silent cancellation - no notification needed
            logger.info("Screenshot cancelled - no notification shown")
            
        case .directoryCreationFailed(let path, _):
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Screenshot Directory Error"
            alert.informativeText = "Failed to create screenshot directory:\n\(path)\n\nPlease check your permissions and try again."
            alert.runModal()
            logger.error("Displayed directory creation error alert")
            
        case .screenshotFailed(let underlying):
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Screenshot Failed"
            alert.informativeText = "An unexpected error occurred:\n\(underlying.localizedDescription)\n\nPlease try again."
            alert.runModal()
            logger.error("Displayed screenshot failed alert: \(underlying.localizedDescription, privacy: .public)")
            
        case .fileNotCreated:
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Screenshot Failed"
            alert.informativeText = "Screenshot file was not created. This might be due to insufficient disk space or permissions."
            alert.runModal()
            logger.error("Displayed file not created error alert")
            
        case .unexpectedError(let message):
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Unexpected Error"
            alert.informativeText = "An unexpected error occurred:\n\(message)\n\nPlease try again or contact support."
            alert.runModal()
            logger.error("Displayed unexpected error alert: \(message, privacy: .public)")
        }
    }
    
    /// Show success alert with screenshot details
    func showSuccessAlert(path: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Screenshot Captured Successfully"
        alert.informativeText = """
        Screenshot saved and path copied to clipboard!
        
        File: \(path)
        
        You can now paste this path in chat using ⌘V
        """
        alert.runModal()
        logger.info("Displayed success alert for \(path, privacy: .public)")
    }
}

// MARK: - Convenience Methods

extension ScreenshotNotificationService {
    /// Show a simple toast notification with custom message
    func showToast(title: String, subtitle: String? = nil, informativeText: String? = nil) {
        let notification = NSUserNotification()
        notification.title = title
        notification.subtitle = subtitle
        notification.informativeText = informativeText
        notification.soundName = nil
        
        NSUserNotificationCenter.default.deliver(notification)
        logger.info("Displayed custom toast: \(title, privacy: .public)")
    }
    
    /// Reset permission alert shown flag (useful for testing)
    func resetPermissionAlertFlag() {
        UserDefaults.standard.removeObject(forKey: permissionAlertShownKey)
        logger.info("Reset permission alert shown flag")
    }
}
