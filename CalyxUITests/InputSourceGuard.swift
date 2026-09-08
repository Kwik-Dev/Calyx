// InputSourceGuard.swift
// CalyxUITests
//
// XCUIApplication.typeText delivers keystrokes through the Mac's
// currently active keyboard input source. When that source is a
// non-Roman IME (e.g. Kotoeri, "あ"), keystrokes are composed rather
// than typed literally: a `'` arrives as a different character, and
// Return commits the IME's in-progress composition instead of reaching
// the app under test, so every typed pane command fails. This guard
// switches the active input source to ABC (falling back to US if ABC
// is not installed) for the duration of a test, and restores the
// developer's original input source afterward.

import Carbon

final class InputSourceGuard {
    private static let asciiCapableInputSourceIDs = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]

    private var recordedInputSource: TISInputSource?

    /// Records the current keyboard input source and, if it differs
    /// from ABC (or US, when ABC is not installed), selects that
    /// ASCII-capable source instead.
    func activate() {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        recordedInputSource = current

        guard let target = Self.asciiCapableInputSourceIDs.lazy.compactMap(Self.inputSource(withID:)).first else {
            return
        }
        guard inputSourceID(of: current) != inputSourceID(of: target) else { return }
        TISSelectInputSource(target)
    }

    /// Re-selects the input source recorded by `activate()`.
    func restore() {
        guard let recordedInputSource else { return }
        TISSelectInputSource(recordedInputSource)
    }

    private func inputSourceID(of source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func inputSource(withID sourceID: String) -> TISInputSource? {
        let properties = [kTISPropertyInputSourceID: sourceID] as CFDictionary
        guard let sources = TISCreateInputSourceList(properties, false)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        return sources.first
    }
}
