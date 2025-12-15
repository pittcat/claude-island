//
//  ScreenshotHotkeyService.swift
//  ClaudeIsland
//
//  Service for handling global hotkey support for screenshots (placeholder for Phase 2)
//

import Foundation
import os.log
import AppKit

/// Protocol for hotkey operations
protocol ScreenshotHotkeyManaging: Sendable {
    func registerHotkey() -> HotkeyResult
    func unregisterHotkey()
    func isHotkeyRegistered() -> Bool
    func handleHotkeyPressed()
    func setScreenshotHandler(_ handler: @escaping @Sendable () async throws -> Void)
}

/// Result type for hotkey operations
enum HotkeyResult: Sendable {
    case success
    case failed(String)
    case alreadyRegistered
}

/// Service for handling global hotkey registration and management
/// Note: Global hotkey support is planned for Phase 2
@MainActor
final class ScreenshotHotkeyService: ScreenshotHotkeyManaging {
    private let logger = Logger(subsystem: "com.claudeisland", category: "ScreenshotHotkey")

    private var isRegistered = false
    private var screenshotHandler: (@Sendable () async throws -> Void)?

    /// Register the global hotkey for screenshots (placeholder)
    func registerHotkey() -> HotkeyResult {
        // Global hotkey registration is planned for Phase 2
        logger.info("Global hotkey registration not implemented in Phase 1")
        return .failed("Global hotkey not implemented yet")
    }

    /// Unregister the global hotkey
    func unregisterHotkey() {
        isRegistered = false
        logger.info("Hotkey unregistered")
    }

    /// Check if the hotkey is currently registered
    func isHotkeyRegistered() -> Bool {
        return isRegistered
    }

    /// Handle hotkey event (called from event handler)
    func handleHotkeyPressed() {
        logger.info("Screenshot hotkey pressed")

        guard let handler = screenshotHandler else {
            logger.error("No screenshot handler set")
            return
        }

        Task {
            do {
                try await handler()
            } catch {
                logger.error("Screenshot failed from hotkey: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Set the screenshot handler (called during app initialization)
    func setScreenshotHandler(_ handler: @escaping @Sendable () async throws -> Void) {
        self.screenshotHandler = handler
    }
}

// MARK: - Global Instance

extension ScreenshotHotkeyService {
    @MainActor static let shared = ScreenshotHotkeyService()
}
