// LastWindowCloseDoesNotQuitE2ETests.swift
// CalyxUITests
//
// End-to-end coverage for the window-lifetime redesign: closing Calyx's
// LAST window (the red button) no longer quits the app at all, matching
// Ghostty's own behavior. This file used to cover the OPPOSITE, now-
// removed behavior (closing the last window routed through
// `CalyxWindowController.windowShouldClose`, which called the real
// `AppDelegate.confirmQuitIfNeeded()` -- a genuine `NSAlert.runModal()`
// -- and, once confirmed, quit the app for real; see git history for
// that version if the old rationale is ever needed again). That whole
// path is gone: `windowShouldClose`'s override was deleted entirely (so
// AppKit's own default -- always allow the close, no confirmation --
// applies), and `AppDelegate.applicationShouldTerminateAfterLastWindowClosed`
// now always returns `false`. This file is rewritten from scratch to
// verify the NEW contract instead of the deleted one.
//
// THIS FILE COVERS (all three, as one sequential round trip, mirroring
// this directory's established one-scenario-per-file style, e.g.
// `SessionPersistenceE2ETests`):
//   1. Closing the app's only window via its red close button shows NO
//      confirm-quit dialog (that confirmation was removed from every
//      close path; only Cmd+Q / the "Quit Calyx" menu item keep theirs
//      -- unchanged, and NOT this file's concern).
//   2. The app process is still running afterward (with zero windows
//      open), not terminated.
//   3. From that zero-window state, the user can still open a new
//      window (File > New Window, Cmd+N) and keep working.
//
// THIS FILE DELIBERATELY DOES NOT COVER:
//   - Session persistence / restore-on-relaunch. That is
//     `SessionPersistenceE2ETests`'s job (quitting via the "Quit Calyx"
//     menu item, which still exists and still saves/restores exactly as
//     before) -- duplicating that coverage here, for a close path that
//     no longer even terminates the app, would test nothing new.
//   - Whether a persistent-session pane's daemon-side session is killed
//     vs. detached when the last window closes this way (a production
//     policy decision this task's brief made, but not one of the three
//     points requested for this file's rewrite).
//   - Cmd+Q / "Quit Calyx" menu confirm-quit dialog itself: unchanged,
//     and every other E2E suite in this directory already launches
//     with `--uitesting`, which short-circuits it anyway (see e.g.
//     `SessionPersistenceE2ETests.quitAppViaMenu()`'s own doc comment).
//   - The Dock-icon "reopen" path (`AppDelegate
//     .applicationShouldHandleReopen`), a SEPARATE new entry point
//     (also part of this redesign) from the one this file exercises
//     (File > New Window / `createNewWindow()`). XCUITest can drive a
//     literal Dock-icon click (`XCUIApplication(bundleIdentifier:
//     "com.apple.dock")`), but no suite in this directory does so
//     today, and it is unrelated to the specific "the app still
//     responds and can still create windows" property point 3 asks
//     for -- File > New Window proves that property through an
//     already-established, reliable menu-driven mechanism instead. See
//     this suite's handoff notes for this gap.
//
// WHY THE BUSY-PANE STEP (`sleep 300`) IS KEPT, EVEN THOUGH THE OLD
// CONFIRM-QUIT GATE IS GONE: a deliberately long-running foreground
// command, pasted into the pane and left running (never awaited)
// before closing, is what used to force ghostty's `needsConfirmQuit()`
// true and reliably trigger the OLD dialog (see this suite's git
// history for the full investigation into ghostty's
// `cursorIsAtPrompt()`/shell-integration timing). Keeping it here makes
// point 1's "no dialog" assertion meaningful rather than vacuous: an
// idle pane alone would also show no dialog under a PARTIAL regression
// that reintroduced a `needsConfirmQuit()`-conditioned check on this
// path (an idle shell's `needsConfirmQuit()` is false regardless, so
// that hypothetical bug would slip through an idle-only test). Uses
// `panePasteAndReturn` (`PaneCLIExec.swift`) exactly as before; unlike
// the old version, this suite does NOT enable persistent sessions or
// touch the calyx-session daemon/ledger at all, since none of the three
// points under test need it -- `panePasteAndReturn` works identically
// against an ordinary, non-persistent pane, and dropping the daemon
// machinery (HOME override, `CALYX_SESSION_BIN`, ledger polling)
// removes an entire, unrelated axis of E2E flakiness this rewrite has
// no reason to keep paying for.

import XCTest

final class LastWindowCloseDoesNotQuitE2ETests: CalyxUITestCase {

    /// Mirrors every sibling E2E suite's own private copy exactly (see
    /// e.g. `SessionPersistenceE2ETests.countMainWindows()`): the title
    /// filter is inert here (this suite never opens the session
    /// browser) but kept for consistency.
    private func countMainWindows() -> Int {
        app.windows.matching(NSPredicate(format: "NOT (title == %@)", "Sessions")).count
    }

    /// Full round trip for all three points this file covers (see this
    /// file's header): the app's only window closes with no confirm
    /// dialog, the app itself survives with zero windows open, and a
    /// fresh window can still be opened afterward.
    func test_closingLastWindow_showsNoConfirmDialog_appStaysRunning_newWindowCanStillBeOpened() {
        let initialWindow = app.windows.firstMatch
        XCTAssertTrue(waitFor(initialWindow), "App window did not appear after launch.")
        XCTAssertEqual(countMainWindows(), 1, "Expected exactly one window at launch.")

        // Force what USED to trigger the old confirm-quit dialog (see
        // this file's header, "WHY THE BUSY-PANE STEP IS KEPT"): a
        // long-running foreground command, never awaited, so the pane
        // is provably not idle at the moment of close.
        panePasteAndReturn("sleep 300")

        // Close the app's only window via its red close button -- NOT
        // `app.terminate()` (SIGTERM, bypasses AppKit's close/termination
        // flow entirely) and NOT the "Quit Calyx" menu item (a
        // deliberately different, still-confirming path this file does
        // not cover, see its header).
        initialWindow.buttons[XCUIIdentifierCloseWindow].click()

        // POINT 1: no confirm-quit dialog.
        XCTAssertFalse(
            app.dialogs.firstMatch.waitForExistence(timeout: 3),
            "Closing the last window's red button must never show a confirm-quit dialog any " +
            "more -- that confirmation was removed from every close path (only Cmd+Q / the " +
            "\"Quit Calyx\" menu item keep theirs) -- even with a long-running foreground " +
            "command making the pane provably busy, which used to force the old dialog to " +
            "appear unconditionally."
        )

        // With no dialog blocking it, the window itself must have
        // actually closed (AppKit's own default windowShouldClose,
        // now that CalyxWindowController's override is gone, always
        // allows the close).
        waitForNonExistence(initialWindow, timeout: 5)
        XCTAssertEqual(
            countMainWindows(), 0,
            "The window should have closed immediately with nothing blocking it, but at least " +
            "one main window is still present."
        )

        // POINT 2: the app process itself survives.
        XCTAssertFalse(
            app.wait(for: .notRunning, timeout: 5),
            "Calyx must stay running after its last window closes, matching Ghostty's own " +
            "last-window-doesn't-quit behavior, but the app process exited."
        )
        XCTAssertNotEqual(
            app.state, .notRunning,
            "Calyx's app state reports not-running after its last window closed; it must stay " +
            "alive with zero windows open until the user explicitly quits or reopens a window."
        )

        // POINT 3: the app still responds and can open a new window
        // from the zero-window state (File > New Window / Cmd+N,
        // `AppDelegate.createNewWindow()`). Proves more than mere
        // process liveness: the app's own menu bar and window-creation
        // pipeline are still fully functional, not merely resident in
        // memory.
        menuAction("File", item: "New Window")
        XCTAssertTrue(
            waitFor(app.windows.firstMatch, timeout: 8),
            "No window appeared after File > New Window (Cmd+N) while Calyx had zero windows " +
            "open -- the app must still be able to create a new window from that state."
        )
        XCTAssertEqual(
            countMainWindows(), 1,
            "Expected exactly one window after opening a new one from the zero-window state, " +
            "got \(countMainWindows())."
        )
    }
}
