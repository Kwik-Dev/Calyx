// AgentHooksCoordinator.swift
// Calyx
//
// Coordinates installing/removing calyx-agent-hook plus each agent CLI's
// own hook/plugin wiring (Claude Code's hooks.json, Codex's config.toml
// managed block, OpenCode's plugin file) across the three tools Phase 2
// supports, collecting results independently so one tool's failure does
// not block the others. Mirrors IPCConfigManager's shape (ConfigStatus per
// tool, directory-existence-based skip).

import Foundation

// MARK: - AgentHooksResult

struct AgentHooksResult: Sendable {
    let claudeCode: ConfigStatus
    let codex: ConfigStatus
    let openCode: ConfigStatus

    /// One `"<name>: <localizedDescription>"` line per `.failed` tool,
    /// for `AgentRegistry.hooksIssues`'s persistent sidebar banner. `[]`
    /// when every tool installed successfully (or was skipped) --
    /// `AgentStatusView` only renders the banner when this is non-empty.
    /// Shared by every `AgentHooksCoordinator.install()`/`.remove()`/
    /// `.resyncInstalled()` caller that feeds
    /// `AgentRegistry.shared.setHooksIssues(_:)`
    /// (`CalyxWindowController.enableIPC` and `AppDelegate`'s own
    /// launch-time re-sync, respectively), rather than each recomputing it.
    var issueMessages: [String] {
        [
            ("Claude Code hooks", claudeCode),
            ("Codex hooks", codex),
            ("OpenCode plugin", openCode),
        ].compactMap { name, status in
            guard case .failed(let error) = status else { return nil }
            return "\(name): \(error.localizedDescription)"
        }
    }
}

// MARK: - AgentHooksCoordinator

struct AgentHooksCoordinator: Sendable {

    // MARK: - Public API

    /// Installs `calyx-agent-hook` and `calyx-approval-hook` once, then
    /// wires each tool's own hook/plugin configuration to invoke them
    /// (Claude Code, Codex) or to POST directly (OpenCode). Either
    /// script's install failure only marks Claude Code / Codex `.failed`
    /// when that tool is actually installed (its config directory
    /// exists) — an uninstalled tool reports `.skipped` exactly as it
    /// would have regardless of the script error, rather than a
    /// misleading `.failed`. Does not block OpenCode, whose plugin talks
    /// to the IPC endpoint over `fetch` rather than through the shared
    /// shell scripts.
    static func install() -> AgentHooksResult {
        let scriptPath: String
        let approvalScriptPath: String
        do {
            scriptPath = try AgentHookScript.install(toDirectory: AgentHookScript.defaultInstallDirectory)
            approvalScriptPath = try ApprovalHookScript.install(toDirectory: AgentHookScript.defaultInstallDirectory)
        } catch {
            return AgentHooksResult(
                claudeCode: scriptFailureStatus(error, directory: AgentToolPaths.claudeConfigDirectory),
                codex: scriptFailureStatus(error, directory: AgentToolPaths.codexConfigDirectory),
                openCode: installOpenCode()
            )
        }

        return AgentHooksResult(
            claudeCode: installClaudeCode(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath),
            codex: installCodex(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath),
            openCode: installOpenCode()
        )
    }

    /// Removes each tool's hook/plugin configuration. Each tool is
    /// `.skipped` up front when it isn't installed at all, rather than
    /// running its (no-op-when-absent) removal and reporting a
    /// misleadingly generic `.success`.
    static func remove() -> AgentHooksResult {
        AgentHooksResult(
            claudeCode: removeClaudeCode(),
            codex: removeCodex(),
            openCode: removeOpenCode()
        )
    }

    /// Re-installs each tool's hook/plugin configuration, but ONLY for a
    /// tool that already has Calyx's own hooks/plugin installed --
    /// `install()`'s counterpart for an unattended launch-time resync,
    /// where wiring up a tool the user never opted into (`install()`'s
    /// own directory-existence-only gate) would be silent, unrequested
    /// scope creep: enabling IPC for one CLI must never spread Calyx's
    /// hooks to a second CLI the user only installed afterward, and a
    /// user who removed Calyx's entries from one tool by hand must never
    /// have them silently reinstated by the next launch. Each tool is
    /// independently checked (`areHooksInstalled`/`isInstalled`) and
    /// `.skipped` when it isn't already present, exactly like `remove()`
    /// above.
    ///
    /// When none of the three tools already have Calyx's hooks, returns
    /// every tool `.skipped` WITHOUT installing the shared
    /// `calyx-agent-hook`/`calyx-approval-hook` scripts at all -- a user
    /// who has never opted into IPC for any tool must never get hook
    /// files written to disk on their behalf just from this running.
    static func resyncInstalled() -> AgentHooksResult {
        let claudeInstalled = ClaudeHooksConfigManager.areHooksInstalled()
        let codexInstalled = CodexHooksConfigManager.areHooksInstalled()
        let openCodeInstalled = OpenCodePluginManager.isInstalled()

        guard claudeInstalled || codexInstalled || openCodeInstalled else {
            let skipped = ConfigStatus.skipped(reason: "not installed")
            return AgentHooksResult(claudeCode: skipped, codex: skipped, openCode: skipped)
        }

        let scriptPath: String
        let approvalScriptPath: String
        do {
            scriptPath = try AgentHookScript.install(toDirectory: AgentHookScript.defaultInstallDirectory)
            approvalScriptPath = try ApprovalHookScript.install(toDirectory: AgentHookScript.defaultInstallDirectory)
        } catch {
            return AgentHooksResult(
                claudeCode: resyncScriptFailureStatus(error, alreadyInstalled: claudeInstalled),
                codex: resyncScriptFailureStatus(error, alreadyInstalled: codexInstalled),
                openCode: resyncOpenCode(alreadyInstalled: openCodeInstalled)
            )
        }

        return AgentHooksResult(
            claudeCode: resyncClaudeCode(
                alreadyInstalled: claudeInstalled, scriptPath: scriptPath, approvalScriptPath: approvalScriptPath
            ),
            codex: resyncCodex(
                alreadyInstalled: codexInstalled, scriptPath: scriptPath, approvalScriptPath: approvalScriptPath
            ),
            openCode: resyncOpenCode(alreadyInstalled: openCodeInstalled)
        )
    }

    // MARK: - Private: Claude Code

    private static func installClaudeCode(scriptPath: String, approvalScriptPath: String) -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: AgentToolPaths.claudeConfigDirectory) else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath)
        }
    }

    private static func removeClaudeCode() -> ConfigStatus {
        // Unlike installClaudeCode's directory-existence guard ("is the
        // tool present"), removal must check whether Calyx's own hooks are
        // actually installed — the tool itself being present says nothing
        // about that, and removeHooks() is a silent no-op either way, so a
        // directory-existence guard here would report a misleading
        // `.success` ("removed") when nothing was ever installed.
        guard ClaudeHooksConfigManager.areHooksInstalled() else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try ClaudeHooksConfigManager.removeHooks()
        }
    }

    /// `resyncInstalled()`'s Claude Code leg: `alreadyInstalled` is
    /// `resyncInstalled()`'s own pre-captured `areHooksInstalled()`
    /// snapshot, not re-queried here, so it stays consistent with the
    /// value that decided whether the shared scripts were installed at
    /// all.
    private static func resyncClaudeCode(
        alreadyInstalled: Bool, scriptPath: String, approvalScriptPath: String
    ) -> ConfigStatus {
        guard alreadyInstalled else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath)
        }
    }

    // MARK: - Private: Codex

    private static func installCodex(scriptPath: String, approvalScriptPath: String) -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: AgentToolPaths.codexConfigDirectory) else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath)
        }
    }

    private static func removeCodex() -> ConfigStatus {
        // See removeClaudeCode's comment: removal must check whether
        // Calyx's managed block is actually installed, not just whether
        // ~/.codex exists.
        guard CodexHooksConfigManager.areHooksInstalled() else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try CodexHooksConfigManager.removeHooks()
        }
    }

    /// `resyncInstalled()`'s Codex leg -- see `resyncClaudeCode`'s own
    /// doc comment for why `alreadyInstalled` is a pre-captured snapshot
    /// rather than a fresh `areHooksInstalled()` call.
    private static func resyncCodex(
        alreadyInstalled: Bool, scriptPath: String, approvalScriptPath: String
    ) -> ConfigStatus {
        guard alreadyInstalled else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath)
        }
    }

    // MARK: - Private: OpenCode

    private static func installOpenCode() -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: AgentToolPaths.openCodeConfigDirectory) else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            _ = try OpenCodePluginManager.install()
        }
    }

    private static func removeOpenCode() -> ConfigStatus {
        guard OpenCodePluginManager.isInstalled() else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try OpenCodePluginManager.remove()
        }
    }

    /// `resyncInstalled()`'s OpenCode leg -- see `resyncClaudeCode`'s own
    /// doc comment for why `alreadyInstalled` is a pre-captured snapshot
    /// rather than a fresh `isInstalled()` call. Runs independently of
    /// whether the shared `calyx-agent-hook` scripts installed cleanly:
    /// OpenCode's plugin POSTs to the IPC endpoint directly rather than
    /// through them (see `install()`'s own doc comment).
    private static func resyncOpenCode(alreadyInstalled: Bool) -> ConfigStatus {
        guard alreadyInstalled else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            _ = try OpenCodePluginManager.install()
        }
    }

    // MARK: - Private: Helpers

    /// Runs `body`, mapping a thrown error to `.failed` and a clean return
    /// to `.success`. Shared by every install/remove path above so the
    /// `do { try ... ; return .success } catch { return .failed(error) }`
    /// boilerplate exists in exactly one place.
    private static func captureStatus(_ body: () throws -> Void) -> ConfigStatus {
        do {
            try body()
            return .success
        } catch {
            return .failed(error)
        }
    }

    /// Status for Claude Code / Codex when the shared `calyx-agent-hook`
    /// script itself failed to install: `.skipped` if the tool isn't even
    /// installed (its config directory is absent — it would have been
    /// skipped regardless of the script error), `.failed(error)` only when
    /// the tool is installed and would otherwise have been wired up.
    private static func scriptFailureStatus(_ error: Error, directory: String) -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: directory) else {
            return .skipped(reason: "not installed")
        }
        return .failed(error)
    }

    /// `resyncInstalled()`'s counterpart to `scriptFailureStatus` above:
    /// `.skipped` when this tool didn't already have Calyx's hooks (it
    /// would have stayed skipped regardless of the script error),
    /// `.failed(error)` only when it did and would otherwise have been
    /// refreshed.
    private static func resyncScriptFailureStatus(_ error: Error, alreadyInstalled: Bool) -> ConfigStatus {
        guard alreadyInstalled else {
            return .skipped(reason: "not installed")
        }
        return .failed(error)
    }
}
