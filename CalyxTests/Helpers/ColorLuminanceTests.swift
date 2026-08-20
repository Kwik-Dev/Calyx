// ColorLuminanceTests.swift
// CalyxTests
//
// Tests for ColorLuminance.
//
// ColorLuminance is a utility enum for computing relative luminance of
// NSColor values (per WCAG 2.x) and determining whether dark or light
// foreground text should be used against a given background.
//
// Coverage:
// - Relative luminance calculation (pure black, pure white)
// - Alpha-aware luminance (semi-transparent white over assumed dark base)
// - prefersDarkText decision for extreme backgrounds
// - All built-in dark presets at default glass opacity -> prefers light text
// - Light custom color at default glass opacity -> prefers dark text

import AppKit
import Testing
@testable import Calyx

// MARK: - Relative Luminance Tests

@Suite("ColorLuminance - relativeLuminance")
struct ColorLuminanceRelativeLuminanceTests {

    @Test("Pure black (alpha 1.0) has luminance approximately 0.0")
    func pureBlackLuminance() {
        let black = NSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        let luminance = ColorLuminance.relativeLuminance(black)
        #expect(
            abs(luminance - 0.0) < 0.01,
            "Pure black should have luminance ~0.0 but got \(luminance)"
        )
    }

    @Test("Pure white (alpha 1.0) has luminance approximately 1.0")
    func pureWhiteLuminance() {
        let white = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        let luminance = ColorLuminance.relativeLuminance(white)
        #expect(
            abs(luminance - 1.0) < 0.01,
            "Pure white should have luminance ~1.0 but got \(luminance)"
        )
    }

    @Test("White with alpha 0.2 has blended luminance much lower than 1.0")
    func whiteWithLowAlphaHasReducedLuminance() {
        let semiWhite = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.2)
        let luminance = ColorLuminance.relativeLuminance(semiWhite)
        // When blended over a dark base, the effective RGB values are much lower
        // so the luminance should be well below 1.0 (likely around 0.01 - 0.05)
        #expect(
            luminance < 0.5,
            "White at alpha 0.2 blended over dark base should have luminance < 0.5 but got \(luminance)"
        )
    }
}

// MARK: - prefersDarkText Tests

@Suite("ColorLuminance - prefersDarkText")
struct ColorLuminancePrefersDarkTextTests {

    @Test("prefersDarkText returns true for white background")
    func prefersDarkTextForWhite() {
        let white = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        let result = ColorLuminance.prefersDarkText(for: white)
        #expect(result == true, "White background should prefer dark text")
    }

    @Test("prefersDarkText returns false for black background")
    func prefersDarkTextForBlack() {
        let black = NSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        let result = ColorLuminance.prefersDarkText(for: black)
        #expect(result == false, "Black background should prefer light text (not dark)")
    }
}

// MARK: - Dark Presets via effectiveChromeTint Tests

@Suite("ColorLuminance - dark presets at default opacity prefer light text")
struct ColorLuminanceDarkPresetsTests {

    // Default glass opacity used by the app
    private static let defaultOpacity: Double = 0.7

    @Test("Original preset at default opacity does not prefer dark text")
    func originalPresetPrefersLightText() {
        let color = NSColor(red: 0.02, green: 0.05, blue: 0.11, alpha: 1.0)
        let effective = ColorLuminance.effectiveChromeTint(
            themeColor: color, glassOpacity: Self.defaultOpacity
        )
        let result = ColorLuminance.prefersDarkText(for: effective)
        #expect(result == false, "Original preset should prefer light text")
    }

    @Test("Red preset at default opacity does not prefer dark text")
    func redPresetPrefersLightText() {
        let color = NSColor(red: 0.11, green: 0.02, blue: 0.02, alpha: 1.0)
        let effective = ColorLuminance.effectiveChromeTint(
            themeColor: color, glassOpacity: Self.defaultOpacity
        )
        let result = ColorLuminance.prefersDarkText(for: effective)
        #expect(result == false, "Red preset should prefer light text")
    }

    @Test("Blue preset at default opacity does not prefer dark text")
    func bluePresetPrefersLightText() {
        let color = NSColor(red: 0.02, green: 0.02, blue: 0.11, alpha: 1.0)
        let effective = ColorLuminance.effectiveChromeTint(
            themeColor: color, glassOpacity: Self.defaultOpacity
        )
        let result = ColorLuminance.prefersDarkText(for: effective)
        #expect(result == false, "Blue preset should prefer light text")
    }

    @Test("Yellow preset at default opacity does not prefer dark text")
    func yellowPresetPrefersLightText() {
        let color = NSColor(red: 0.11, green: 0.10, blue: 0.02, alpha: 1.0)
        let effective = ColorLuminance.effectiveChromeTint(
            themeColor: color, glassOpacity: Self.defaultOpacity
        )
        let result = ColorLuminance.prefersDarkText(for: effective)
        #expect(result == false, "Yellow preset should prefer light text")
    }

    @Test("Purple preset at default opacity does not prefer dark text")
    func purplePresetPrefersLightText() {
        let color = NSColor(red: 0.06, green: 0.02, blue: 0.11, alpha: 1.0)
        let effective = ColorLuminance.effectiveChromeTint(
            themeColor: color, glassOpacity: Self.defaultOpacity
        )
        let result = ColorLuminance.prefersDarkText(for: effective)
        #expect(result == false, "Purple preset should prefer light text")
    }

    @Test("Black preset at default opacity does not prefer dark text")
    func blackPresetPrefersLightText() {
        let color = NSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        let effective = ColorLuminance.effectiveChromeTint(
            themeColor: color, glassOpacity: Self.defaultOpacity
        )
        let result = ColorLuminance.prefersDarkText(for: effective)
        #expect(result == false, "Black preset should prefer light text")
    }

    @Test("Gray preset at default opacity does not prefer dark text")
    func grayPresetPrefersLightText() {
        let color = NSColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1.0)
        let effective = ColorLuminance.effectiveChromeTint(
            themeColor: color, glassOpacity: Self.defaultOpacity
        )
        let result = ColorLuminance.prefersDarkText(for: effective)
        #expect(result == false, "Gray preset should prefer light text")
    }

    @Test("Ghostty preset at default opacity does not prefer dark text")
    func ghosttyPresetPrefersLightText() {
        let color = NSColor(red: 0.16, green: 0.16, blue: 0.16, alpha: 1.0)
        let effective = ColorLuminance.effectiveChromeTint(
            themeColor: color, glassOpacity: Self.defaultOpacity
        )
        let result = ColorLuminance.prefersDarkText(for: effective)
        #expect(result == false, "Ghostty preset should prefer light text")
    }
}

// MARK: - Light Custom Color Tests

@Suite("ColorLuminance - light custom color at default opacity prefers dark text")
struct ColorLuminanceLightCustomTests {

    private static let defaultOpacity: Double = 0.7

    @Test("Light custom #F0F0F0 at default opacity prefers dark text")
    func lightCustomPrefersDarkText() {
        let color = NSColor(red: 240.0/255.0, green: 240.0/255.0, blue: 240.0/255.0, alpha: 1.0)
        let effective = ColorLuminance.effectiveChromeTint(
            themeColor: color, glassOpacity: Self.defaultOpacity
        )
        let result = ColorLuminance.prefersDarkText(for: effective)
        #expect(result == true, "Light custom #F0F0F0 at default opacity should prefer dark text")
    }
}
