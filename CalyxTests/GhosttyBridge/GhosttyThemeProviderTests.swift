// GhosttyThemeProviderTests.swift
// CalyxTests
//
// Tests for GhosttyThemeProvider.ghosttyForeground property.
//
// GhosttyThemeProvider currently exposes only `ghosttyBackground`.
// These tests verify the existence and behavior of a new
// `ghosttyForeground` property (NSColor, default .white).
// All tests will FAIL until the implementation adds this property.

import AppKit
import Testing
@testable import Calyx

@MainActor
@Suite("GhosttyThemeProvider foreground color Tests")
struct GhosttyThemeProviderTests {

    // ==================== Property Existence ====================

    @Test("ghosttyForeground property exists and returns an NSColor")
    func ghosttyForegroundPropertyExistsAndReturnsNSColor() {
        let provider = GhosttyThemeProvider.shared
        let foreground: NSColor = provider.ghosttyForeground
        #expect(foreground is NSColor,
                "ghosttyForeground must be an NSColor instance")
    }

    // ==================== Default Value ====================

    @Test("ghosttyForeground defaults to white")
    func ghosttyForegroundDefaultsToWhite() {
        let provider = GhosttyThemeProvider.shared
        let foreground = provider.ghosttyForeground

        // Compare RGBA components to avoid colorspace mismatch issues
        let expected = NSColor.white.usingColorSpace(.sRGB)!
        let actual = foreground.usingColorSpace(.sRGB)!

        #expect(
            abs(actual.redComponent - expected.redComponent) < 0.01 &&
            abs(actual.greenComponent - expected.greenComponent) < 0.01 &&
            abs(actual.blueComponent - expected.blueComponent) < 0.01,
            "ghosttyForeground should default to white (1.0, 1.0, 1.0) but got (\(actual.redComponent), \(actual.greenComponent), \(actual.blueComponent))"
        )
    }
}
