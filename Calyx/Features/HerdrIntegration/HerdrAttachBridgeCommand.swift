// HerdrAttachBridgeCommand.swift
// Calyx
//
// Pure function building the per-pane bridge command:
// `/usr/bin/env HERDR_SOCKET_PATH=<socketPath> <herdrBin> terminal attach
// <terminalID>` -- as opposed to HerdrAttachCommandSynthesizer's
// whole-session TUI attach command (`<herdrBin>` alone, zero arguments).
// Every VARIABLE token (socketPath, herdrBin, terminalID) goes through
// the EXISTING SessionCommandSynthesizer.shSafeToken -- never a new
// escaper -- exactly like HerdrAttachCommandSynthesizer already does;
// the literal words `/usr/bin/env`, `terminal`, `attach` are fixed
// constants and are never escaped.
//
// `terminal attach`, NOT `agent attach`: `herdr agent attach <paneID>`
// resolves its target through herdr's AGENT registry and fails outright
// for any pane with no agent running --
// {"error":{"code":"agent_not_found","message":"agent target <id> not
// found"},"id":"cli:agent:attach:resolve"} -- measured live against a
// real plain-shell pane on herdr 0.8.0. `herdr terminal attach
// <terminalID>` is the measured, WORKING replacement: verified live
// (herdr 0.8.0, a real plain-shell pane) via a pty harness -- 90892
// bytes of raw ANSI on connect (`\x1b[` present), typed input echoes
// back round-trip, and a SIGWINCH after TIOCSWINSZ produces a repaint
// (50279 bytes) -- for BOTH a plain-shell pane and an agent pane alike.
// `--takeover` is an accepted option, not required for this default,
// non-takeover attach. This command therefore now takes a herdr
// TERMINAL id, never a pane id -- see `HerdrPaneRef.isValidTerminalID`'s
// own header for where that id itself comes from (`session.snapshot`'s
// `panes[].terminal_id`, or `pane.get`'s `pane.terminal_id` -- NOT
// `layout.export`, whose pane nodes carry no terminal id at all).
//
// build(herdrBin:socketPath:terminalID:) returns `String?`: it gates on
// HerdrPaneRef.isValidTerminalID(terminalID) first and returns nil for
// anything that validator rejects, so a command is never synthesized
// around a terminalID shaped like a shell injection attempt, regardless
// of how well shSafeToken would have escaped it in practice.
//
// WHY `/usr/bin/env` (mirrors HerdrAttachCommandSynthesizer.swift's own
// header verbatim): ghostty wraps whatever `command` a surface
// configures as `/bin/bash --noprofile --norc -c "exec -l <command>"`
// (SessionCommandSynthesizer.swift's own header). By the time that
// string is parsed, `exec -l` has already claimed the command-word
// position for the `exec` builtin itself, so a bare
// `HERDR_SOCKET_PATH=<token> <token> terminal attach <token>` (no
// `/usr/bin/env` in front) would put `HERDR_SOCKET_PATH=...` in `exec`'s
// own next-argument position, which `exec`'s builtin argument parsing
// treats as the program to run, not as an environment assignment.
// Routing through the hardcoded absolute path `/usr/bin/env` fixes it
// exactly as it does there.
//
// No I/O, no actor isolation required.

import Foundation

enum HerdrAttachBridgeCommand {
    /// Builds `/usr/bin/env HERDR_SOCKET_PATH=<socketPath> <herdrBin>
    /// terminal attach <terminalID>`. `nil` when `terminalID` fails
    /// HerdrPaneRef.isValidTerminalID -- see this file's header.
    static func build(herdrBin: String, socketPath: String, terminalID: String) -> String? {
        guard HerdrPaneRef.isValidTerminalID(terminalID) else { return nil }
        return "/usr/bin/env HERDR_SOCKET_PATH=" + SessionCommandSynthesizer.shSafeToken(socketPath)
            + " " + SessionCommandSynthesizer.shSafeToken(herdrBin)
            + " terminal attach " + SessionCommandSynthesizer.shSafeToken(terminalID)
    }
}
