// ProcessSignals.swift
// Calyx
//
// Process-wide POSIX signal disposition, applied once at launch.

import Darwin

/// Ignores SIGPIPE process-wide. Calyx embeds ghostty's termio, which
/// closes a terminal by writing to a pipe it has already closed to
/// unblock its own read thread; left at its default disposition,
/// SIGPIPE would kill the process outright with no crash report.
func ignoreSIGPIPE() {
    var action = sigaction()
    action.__sigaction_u.__sa_handler = SIG_IGN
    action.sa_flags = 0
    sigemptyset(&action.sa_mask)
    sigaction(SIGPIPE, &action, nil)
}
