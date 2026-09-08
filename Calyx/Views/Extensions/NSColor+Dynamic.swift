// NSColor+Dynamic.swift
// Calyx
//
// Shared dynamic-color builder for views that need an `NSColor` pair
// resolved against whichever `NSAppearance` is active at draw time
// (including an app-wide override), rather than a `@Environment
// (\.colorScheme)` read.

import AppKit

extension NSColor {
    /// Builds an `NSColor` that resolves to `dark` or `light` against
    /// whichever `NSAppearance` is active wherever it is drawn --
    /// `appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua` is
    /// the standard AppKit test for "is this appearance a dark one",
    /// covering vibrancy/accessibility variants of both aquas alike.
    static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}
