// HerdrAttachCommandSynthesizer.swift
// Calyx
//
// Pure function building the shell command string used as a ghostty
// surface's `command` when attaching to a herdr session:
// `/usr/bin/env HERDR_SOCKET_PATH=<socketPath> <herdrBin>` -- pinning
// the EXACT socket the user clicked via the environment, never a
// `--session <name>` flag. herdr's own documented resolution order
// honors HERDR_SOCKET_PATH whenever no --session flag is present, so
// this removes both the wrong-socket risk of a name having to be
// re-resolved back to a path (two candidates can share a directory
// name derived from unrelated config roots) and the flag-injection
// surface of a directory-derived name that happens to look like a CLI
// flag (e.g. one starting with `-`) -- socketPath only ever travels as
// an env var VALUE here, never as an argv word, so it has no
// flag-parsing surface to exploit at all.
//
// `herdrBin` and `socketPath` are each escaped via
// `SessionCommandSynthesizer.shSafeToken`
// (Calyx/Features/Sessions/SessionCommandSynthesizer.swift) -- reused
// verbatim, never reimplemented, exactly like
// `SessionCommandSynthesizer.remoteAttachCommand` itself already reuses
// `shSafeToken` internally instead of a second copy.
//
// WHY `/usr/bin/env`, NOT A BARE `HERDR_SOCKET_PATH=<token> <token>`:
// ghostty does not hand this string to a shell unmodified; it wraps
// whatever `command` a surface configures as `/bin/bash --noprofile
// --norc -c "exec -l <command>"` (SessionCommandSynthesizer.swift's own
// header). By the time that string is parsed, `exec -l` has ALREADY
// claimed the command-word position for the `exec` builtin itself, so a
// `NAME=value` word immediately after it is no longer in POSIX "prefix
// assignment" position -- it's just `exec`'s own next argument, and
// `exec`'s own builtin argument parsing treats it as the program to
// run, not as an environment assignment. That reproduces this
// codebase's own HOME-stamp failure verbatim (see
// `SessionCommandSynthesizerRuntimeStateDirFlagsTests`'s header),
// confirmed empirically against the real `exec -l` wrapper before this
// function was written this way. Routing through the hardcoded absolute
// path `/usr/bin/env` (always present on Darwin, so no PATH-search
// ambiguity, and never escaped -- a fixed constant, never
// attacker/user-controlled) fixes it: `exec -l` now execs `/usr/bin/env`
// directly, and `env`'s OWN argument parsing -- which runs AFTER the
// shell has already removed quotes -- is what turns the leading
// `NAME=value` word into a real environment assignment before it execs
// the shell-escaped `herdrBin` word that follows.
//
// No I/O, no actor isolation required.

import Foundation

enum HerdrAttachCommandSynthesizer {

    /// Builds `/usr/bin/env HERDR_SOCKET_PATH=<socketPath> <herdrBin>`.
    /// `herdrBin` is always invoked with zero arguments -- no
    /// `--session` flag, ever; see this file's header.
    static func attachCommand(herdrBin: String, socketPath: String) -> String {
        "/usr/bin/env HERDR_SOCKET_PATH=" + SessionCommandSynthesizer.shSafeToken(socketPath)
            + " " + SessionCommandSynthesizer.shSafeToken(herdrBin)
    }
}
