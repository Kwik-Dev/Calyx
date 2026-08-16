// AgentToolPaths.swift
// Calyx
//
// Centralizes the on-disk config-root directory for each agent CLI Phase 2
// wires up, so `AgentHooksCoordinator`, `OpenCodePluginManager`,
// `CodexHooksConfigManager`, `IPCConfigManager`, and `OpenCodeConfigManager`
// all derive the same path from exactly one place rather than re-deriving
// `NSHomeDirectory() + "/..."` independently.

import Foundation

enum AgentToolPaths {

    /// Claude Code's config root: `~/.claude`.
    static var claudeConfigDirectory: String {
        NSHomeDirectory() + "/.claude"
    }

    /// Codex's config root: `~/.codex`.
    static var codexConfigDirectory: String {
        NSHomeDirectory() + "/.codex"
    }

    /// OpenCode's config root: `~/.config/opencode`.
    static var openCodeConfigDirectory: String {
        NSHomeDirectory() + "/.config/opencode"
    }

    /// Grok's config root: `~/.grok`. Holds both `config.toml`
    /// (`GrokConfigManager`'s `[mcp_servers.calyx-ipc]` entry) and
    /// `hooks/calyx.json` (`GrokHooksConfigManager`'s Calyx-owned hook
    /// file).
    static var grokConfigDirectory: String {
        NSHomeDirectory() + "/.grok"
    }

    /// pi's agent root: `~/.pi/agent`, the directory holding the
    /// `extensions/` folder `PiExtensionManager` writes into. The path
    /// reaches down to `agent` rather than stopping at `~/.pi` so an
    /// unrelated `~/.pi` directory cannot be read as an installed pi.
    static var piConfigDirectory: String {
        NSHomeDirectory() + "/.pi/agent"
    }
}
