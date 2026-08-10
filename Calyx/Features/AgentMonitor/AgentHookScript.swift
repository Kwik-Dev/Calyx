// AgentHookScript.swift
// Calyx
//
// The `calyx-agent-hook` shell script installed under
// `~/Library/Application Support/Calyx/bin/`. Forwards a Claude Code hook's
// stdin JSON to the local Calyx IPC server's /agent-event endpoint.

import Foundation

enum AgentHookScript {

    /// The script's file name, also used by `ClaudeHooksConfigManager` to
    /// recognize its own `command` entries by path.
    static let fileName = "calyx-agent-hook"

    /// Default install directory: `~/Library/Application Support/Calyx/bin`.
    static var defaultInstallDirectory: String {
        (AgentEndpointFile.defaultDirectory as NSString).appendingPathComponent("bin")
    }

    /// Both `CALYX_SURFACE_ID` and `CALYX_SESSION_ID` unset means this
    /// pane wasn't launched by Calyx at all (e.g. a plain Terminal.app
    /// tab running `claude`) — exit immediately so those instances are
    /// unaffected. `agent-endpoint.json` is re-read on every invocation
    /// (rather than baked in at install time) so a server restart or
    /// token rotation never leaves the hook posting to a stale
    /// port/token. Every exit path is `exit 0`: a failed or unreachable
    /// POST must never break the user's hook chain.
    ///
    /// `$1` is the agent kind, forwarded as the `X-Calyx-Agent-Kind`
    /// header so the server can attribute the event to the right CLI.
    /// Defaulting to `claude-code` when `$1` is unset keeps this script
    /// compatible with Claude Code's own hook `command` entries (installed
    /// by `ClaudeHooksConfigManager`), which invoke it with no arguments;
    /// `CodexHooksConfigManager` installs Codex's entries as
    /// `"<scriptPath>" codex` to pass `codex` explicitly.
    ///
    /// The `X-Calyx-Surface-ID` header value itself is
    /// `${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}`: a persistent-session
    /// pane's calyx-session ID survives ghostty surface re-creation
    /// (reconnect) while `CALYX_SURFACE_ID` does not, so `CALYX_SESSION_ID`
    /// is preferred whenever set, falling back to the ordinary
    /// `CALYX_SURFACE_ID` otherwise. The fail-open guard above checks
    /// both variables (not just `CALYX_SURFACE_ID`) so a hypothetical
    /// future caller that sets only `CALYX_SESSION_ID` still gets its
    /// event forwarded, rather than the guard silently depending on an
    /// invariant ("`CALYX_SESSION_ID` is only ever set alongside
    /// `CALYX_SURFACE_ID`") that happens to hold today but isn't
    /// enforced anywhere.
    ///
    /// Second fail-open guard, herdr environment contamination: running
    /// a herdr server from inside a Calyx pane's shell means every
    /// shell herdr itself spawns can inherit that pane's
    /// `CALYX_SURFACE_ID`/`CALYX_SESSION_ID` — the guard above alone
    /// does NOT catch this, because that inherited ID is non-empty
    /// (just stale/misattributed, not unset). The guard is implemented
    /// as `awk 'BEGIN{f=0;for(k in ENVIRON)if(k~/^HERDR_/)f=1;exit
    /// !f}'`: iterating `ENVIRON`'s KEYS only (never reading any
    /// `ENVIRON[k]` value) means only actual environment variable NAMES
    /// are ever matched against `^HERDR_`, anchoring on the trailing
    /// underscore so a hypothetical `HERDRX_...` variable (no
    /// underscore after `HERDR`) never trips this guard. An earlier
    /// `env | grep -q '^HERDR_'` form looked equivalent but was NOT:
    /// `env` prints raw `NAME=value` records with no escaping, so an
    /// unrelated variable whose VALUE happens to contain an embedded
    /// newline followed by text that merely looks like
    /// `HERDR_SOMETHING=...` renders, from grep's line-oriented point
    /// of view, as if it were its own `NAME=value` line — a false
    /// positive that silently drops a real event. `awk`'s `ENVIRON`
    /// array is built from the process's actual `environ` records, not
    /// by re-splitting printed text on newlines, so an embedded newline
    /// inside a value can never be misread as a variable-name boundary.
    /// The exact set of `HERDR_`-prefixed names herdr itself sets
    /// doesn't need to be enumerated here — any one of them is
    /// sufficient signal that this shell is running inside a
    /// herdr-managed pane, not a plain Calyx one.
    ///
    /// Known residual path (tracked, not closable by this guard):
    /// Claude Code's own MCP client config (`ClaudeConfigManager`)
    /// writes the `X-Calyx-Surface-ID` header as the literal string
    /// `${CALYX_SURFACE_ID:-}`, which Claude Code itself expands from
    /// its OWN process environment at MCP-connection time, entirely
    /// inside the agent binary — a separate code path this hook script
    /// never runs in and cannot intercept. A stale `CALYX_SURFACE_ID`
    /// inherited by a herdr-managed shell can still reach that header
    /// this way. Tracked for the herdr socket-integration stage.
    static let scriptBody: String = """
    #!/bin/sh
    #
    # calyx-agent-hook — forwards a Claude Code hook's stdin JSON to
    # Calyx's local Agent Monitor IPC endpoint. Installed and removed by
    # ClaudeHooksConfigManager / CodexHooksConfigManager.

    if [ -z "$CALYX_SURFACE_ID" ] && [ -z "$CALYX_SESSION_ID" ]; then
        exit 0
    fi

    # A herdr server started from inside a Calyx pane can spawn shells
    # that inherit that pane's CALYX_SURFACE_ID/CALYX_SESSION_ID -- any
    # HERDR_-prefixed variable NAME means this shell is herdr-managed,
    # so skip posting under that stale, misattributed surface identity.
    # Matches variable NAMES via awk's ENVIRON keys only (never a
    # value), immune to a value containing an embedded newline that
    # could otherwise fool a text-based `env | grep` scan.
    if awk 'BEGIN{f=0;for(k in ENVIRON)if(k~/^HERDR_/)f=1;exit !f}'; then
        exit 0
    fi

    kind="${1:-claude-code}"

    endpoint_file="$HOME/Library/Application Support/Calyx/agent-endpoint.json"
    if [ ! -f "$endpoint_file" ]; then
        exit 0
    fi

    port=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\\([0-9]*\\).*/\\1/p' "$endpoint_file")
    token=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$endpoint_file")

    if [ -z "$port" ] || [ -z "$token" ]; then
        exit 0
    fi

    curl -s -m 2 \\
        -X POST \\
        -H "Authorization: Bearer $token" \\
        -H "X-Calyx-Surface-ID: ${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}" \\
        -H "X-Calyx-Agent-Kind: $kind" \\
        -H "Content-Type: application/json" \\
        --data-binary @- \\
        "http://127.0.0.1:$port/agent-event" > /dev/null 2>&1

    exit 0
    """

    /// Installs the script into `toDirectory`, creating the directory if
    /// needed, and marks it executable (0755). Returns the script's
    /// absolute path.
    static func install(toDirectory directory: String) throws -> String {
        try installScript(body: scriptBody, fileName: fileName, toDirectory: directory)
    }

    /// Shared installer body: writes `body` to `fileName` inside
    /// `directory` (creating it if needed) and marks it executable
    /// (0755), returning the script's absolute path. Used by both
    /// `AgentHookScript.install(toDirectory:)` above and
    /// `ApprovalHookScript.install(toDirectory:)`, so the actual
    /// write-then-chmod logic exists in exactly one place.
    static func installScript(body: String, fileName: String, toDirectory directory: String) throws -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let scriptPath = (directory as NSString).appendingPathComponent(fileName)
        try body.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        return scriptPath
    }
}
