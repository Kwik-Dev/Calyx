// TabGroupColor.swift
// Calyx
//
// 10-color preset enum for tab group color identification.

import AppKit

enum TabGroupColor: String, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple

    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .mint: return .systemMint
        case .teal: return .systemTeal
        case .cyan: return .systemCyan
        case .blue: return .systemBlue
        case .indigo: return .systemIndigo
        case .purple: return .systemPurple
        }
    }

    /// UI label for this color, shown in the group color-picker menu.
    /// Deliberately independent of `rawValue`, which is the persistence
    /// key (`TabGroupSnapshot.color`): never derive one from the other.
    var displayName: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .mint: return "Mint"
        case .teal: return "Teal"
        case .cyan: return "Cyan"
        case .blue: return "Blue"
        case .indigo: return "Indigo"
        case .purple: return "Purple"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = TabGroupColor(rawValue: raw) ?? .blue
    }

    /// Visually distinct assignment order (avoids consecutive similar colors).
    private static let assignmentOrder: [TabGroupColor] = [
        .red, .blue, .yellow, .purple, .green, .orange, .indigo, .mint, .cyan, .teal,
    ]

    /// Returns the next color that avoids duplicating existing group colors.
    /// If an unused color exists, returns the first one in assignmentOrder.
    /// If all colors are used, returns the least frequently used color.
    static func nextColor(excluding usedColors: [TabGroupColor]) -> TabGroupColor {
        let usedSet = Set(usedColors)
        if let available = assignmentOrder.first(where: { !usedSet.contains($0) }) {
            return available
        }
        let counts = Dictionary(usedColors.map { ($0, 1) }, uniquingKeysWith: +)
        let minCount = counts.values.min() ?? 0
        return assignmentOrder.first(where: { counts[$0, default: 0] == minCount }) ?? .blue
    }
}
