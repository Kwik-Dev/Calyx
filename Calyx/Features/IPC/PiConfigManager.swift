// PiConfigManager.swift
// Calyx
//
// Manages installing/removing a Calyx IPC skill for the pi coding agent.
// Pi has no built-in MCP client; this manager writes a pi skill directory
// under ~/.pi/agent/skills/calyx-ipc/ that teaches pi how to use the
// `calyx ipc` CLI to join the Calyx IPC peer mesh.

import Foundation

// MARK: - PiConfigError

enum PiConfigError: Error, LocalizedError {
    case symlinkDetected
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .symlinkDetected:
            return "A pi skill path is a symlink, which is not allowed for security reasons"
        case .writeFailed(let reason):
            return "Failed to write pi skill: \(reason)"
        }
    }
}

// MARK: - PiConfigManager

struct PiConfigManager: Sendable {

    // MARK: - Constants

    private static let skillDirName = "calyx-ipc"
    private static let skillFileName = "SKILL.md"

    /// BEGIN/END markers for the managed block so we can detect and self-heal.
    private static let beginDelimiter = "<!-- BEGIN CALYX IPC (managed by Calyx, do not edit) -->"
    private static let endDelimiter = "<!-- END CALYX IPC -->"

    /// Pi skill frontmatter.
    private static let skillFrontmatter = """
    ---
    name: calyx-ipc
    description: Connects pi to other Calyx IPC agents via the calyx CLI. Use when running pi inside Calyx and you need to coordinate with other terminal panes.
    ---

    """

    /// Static body — no secrets. The `calyx ipc` CLI reads ~/.config/calyx/ipc.json.
    private static let skillBody = """
    # Calyx IPC

    You are running inside a [Calyx](https://github.com/yuuichieguchi/Calyx) terminal tab.
    Other AI agents (Claude Code, Codex, OpenCode, Hermes, Crush) in other Calyx panes may
    be available as IPC peers. Use the `calyx ipc` CLI to discover and communicate with them.

    ## Setup

    Ensure the Calyx CLI is on your PATH. In Calyx, open the Command Palette
    (`Cmd+Shift+P`) and run **Install CLI to PATH**.

    ## Usage

    Immediately after starting this session, register as a peer **once**:

    ```bash
    PEER_ID=$(calyx ipc register-peer --name "<task-or-directory>" --role "coder")
    ```

    After completing any significant task, check for messages from other peers:

    ```bash
    calyx ipc receive-messages --from "$PEER_ID"
    ```

    Process any messages and respond with:

    ```bash
    calyx ipc send --from "$PEER_ID" --to "$OTHER_PEER_ID" --content "your response"
    ```

    Discover other connected instances:

    ```bash
    calyx ipc list-peers
    ```

    Broadcast announcements to all peers:

    ```bash
    calyx ipc broadcast --from "$PEER_ID" --content "I finished the auth module"
    ```

    ## CLI Reference

    | Command | Description |
    |---------|-------------|
    | `calyx ipc register-peer --name <n> --role <r>` | Register this instance as a peer |
    | `calyx ipc list-peers` | List all currently active peers |
    | `calyx ipc send --from <id> --to <id> --content <text>` | Send a message to a peer |
    | `calyx ipc broadcast --from <id> --content <text>` | Broadcast to all peers |
    | `calyx ipc receive-messages --from <id>` | Check for pending messages |
    | `calyx ipc ack-messages --from <id> --message-ids <id>...` | Acknowledge messages |
    | `calyx ipc status --peer-id <id>` | Check a peer's status |
    """

    // MARK: - Public API

    /// Installs the Calyx IPC skill directory.
    ///
    /// Creates (or replaces) the skill directory at the default pi skills path.
    /// If the pi skills directory does not exist, the operation is skipped
    /// (pi is not installed). Symlinks on the target path are rejected.
    static func enableIPC(skillsDir: String? = nil) throws {
        let dir = skillsDir ?? defaultSkillsDir

        // Check that the parent pi skills directory exists.
        guard FileManager.default.fileExists(atPath: dir) else {
            // pi not installed — silently skip, matching other agents.
            return
        }

        let skillDir = dir + "/" + skillDirName
        let skillFile = skillDir + "/" + skillFileName

        // Preflight: symlink rejection
        if ConfigFileUtils.isSymlink(at: skillDir) {
            throw PiConfigError.symlinkDetected
        }
        if ConfigFileUtils.isSymlink(at: skillFile) {
            throw PiConfigError.symlinkDetected
        }

        // Remove old skill directory if present (but not if it's a symlink).
        if FileManager.default.fileExists(atPath: skillDir) {
            try FileManager.default.removeItem(atPath: skillDir)
        }

        // Create fresh directory.
        try FileManager.default.createDirectory(
            atPath: skillDir,
            withIntermediateDirectories: false
        )

        // Write SKILL.md with wrapped markers.
        let content = beginDelimiter + "\n\n" + skillFrontmatter + skillBody + "\n" + endDelimiter + "\n"
        guard let data = content.data(using: .utf8) else {
            throw PiConfigError.writeFailed("UTF-8 encoding failed")
        }

        try ConfigFileUtils.atomicWrite(
            data: data,
            to: skillFile
        )
    }

    /// Removes the Calyx IPC skill directory.
    /// Missing directory is a no-op. Symlinks are rejected.
    static func disableIPC(skillsDir: String? = nil) throws {
        let dir = skillsDir ?? defaultSkillsDir
        let skillDir = dir + "/" + skillDirName

        guard FileManager.default.fileExists(atPath: skillDir) else { return }

        if ConfigFileUtils.isSymlink(at: skillDir) {
            throw PiConfigError.symlinkDetected
        }

        try FileManager.default.removeItem(atPath: skillDir)
    }

    /// Returns true if the Calyx IPC skill SKILL.md exists and contains the
    /// Calyx managed-block markers.
    static func isIPCEnabled(skillsDir: String? = nil) -> Bool {
        let dir = skillsDir ?? defaultSkillsDir
        let skillFile = dir + "/" + skillDirName + "/" + skillFileName

        guard FileManager.default.fileExists(atPath: skillFile),
              let content = try? String(contentsOfFile: skillFile, encoding: .utf8) else {
            return false
        }

        return content.contains(beginDelimiter) && content.contains(endDelimiter)
    }

    // MARK: - Private

    private static var defaultSkillsDir: String {
        NSHomeDirectory() + "/.pi/agent/skills"
    }
}