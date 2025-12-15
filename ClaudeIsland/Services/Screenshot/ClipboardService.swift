//
//  ClipboardService.swift
//  ClaudeIsland
//
//  Service for handling clipboard operations
//

import Foundation
import os.log
import AppKit

/// Protocol for clipboard operations
protocol ClipboardManaging: Sendable {
    func copyToClipboard(_ string: String) -> Bool
    func readFromClipboard() -> String?
    func clearClipboard()
}

/// Service for handling clipboard operations
@MainActor
final class ClipboardService: ClipboardManaging {
    private let logger = Logger(subsystem: "com.claudeisland", category: "Clipboard")
    
    init() {}
    
    /// Copy a string to the clipboard
    func copyToClipboard(_ string: String) -> Bool {
        let pasteboard = NSPasteboard.general
        
        // Clear existing contents
        pasteboard.clearContents()
        
        // Write the string
        let success = pasteboard.setString(string, forType: .string)
        
        if success {
            logger.info("Successfully copied to clipboard: \(string, privacy: .public)")
        } else {
            logger.error("Failed to copy to clipboard: \(string, privacy: .public)")
        }
        
        return success
    }
    
    /// Read the current clipboard contents as string
    func readFromClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        let items = pasteboard.pasteboardItems
        guard let item = items?.first else { return nil }
        
        if let string = item.string(forType: .string) {
            logger.info("Read from clipboard: \(string, privacy: .public)")
            return string
        }
        
        logger.info("No string found in clipboard")
        return nil
    }
    
    /// Clear the clipboard
    func clearClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        logger.info("Cleared clipboard")
    }
}

// MARK: - Convenience Extension

extension ClipboardService {
    /// Copy a file URL path to clipboard as POSIX path
    func copyFileURLToClipboard(_ fileURL: URL) -> Bool {
        return copyToClipboard(fileURL.path)
    }
    
    /// Copy multiple strings to clipboard
    func copyStringsToClipboard(_ strings: [String]) -> Bool {
        let combinedString = strings.joined(separator: "\n")
        return copyToClipboard(combinedString)
    }
}
