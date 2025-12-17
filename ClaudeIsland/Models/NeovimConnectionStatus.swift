//
//  NeovimConnectionStatus.swift
//  ClaudeIsland
//
//  Real-time Neovim connection status for sessions running inside Neovim terminal.
//

import SwiftUI

/// Represents the connection status between Claude Island and Neovim terminal
enum NeovimConnectionStatus: String, Sendable, Equatable, Codable {
    /// Initial state, connection not yet checked
    case unknown
    /// Currently checking the connection
    case checking
    /// Connected and terminal is ready
    case connected
    /// Connection failed or terminal not ready
    case disconnected

    // MARK: - Display Properties

    /// SF Symbol name for this status
    var displayIcon: String {
        switch self {
        case .unknown:
            return "questionmark.circle"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .connected:
            return "checkmark.circle.fill"
        case .disconnected:
            return "xmark.circle"
        }
    }

    /// Color for this status
    var displayColor: Color {
        switch self {
        case .unknown:
            return Color.gray.opacity(0.5)
        case .checking:
            return Color.orange
        case .connected:
            return TerminalColors.green
        case .disconnected:
            return Color.red.opacity(0.8)
        }
    }

    /// Human-readable description
    var displayText: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .checking:
            return "Checking..."
        case .connected:
            return "Connected"
        case .disconnected:
            return "Disconnected"
        }
    }

    /// Tooltip text for UI
    var tooltipText: String {
        switch self {
        case .unknown:
            return "Neovim: Status unknown"
        case .checking:
            return "Neovim: Checking connection..."
        case .connected:
            return "Neovim: Connected to Claude Code terminal"
        case .disconnected:
            return "Neovim: Disconnected - will retry"
        }
    }
}
