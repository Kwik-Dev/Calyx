// GrokConfigManager.swift
// Calyx
//
// Manages reading/writing ~/.grok/config.toml for the Calyx IPC MCP
// server. Grok's MCP client config is TOML, like Codex's, but its
// remote-server headers live in a `[mcp_servers.<name>.headers]`
// sub-table rather than Codex's inline `http_headers` / `env_http_headers`
// keys, and Grok expands `${VAR}` / `${VAR:-default}` inside every
// `[mcp_servers.*]` string field at load time, so the surface and
// session identities are interpolated from the environment directly
// instead of through a separate env-header mapping table.

import Foundation

// MARK: - GrokConfigError

enum GrokConfigError: Error, LocalizedError {
    case directoryNotFound
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .directoryNotFound:
            return "The ~/.grok/ directory does not exist"
        case .writeFailed(let reason):
            return "Failed to write config file: \(reason)"
        }
    }
}

// MARK: - GrokConfigManager

struct GrokConfigManager: Sendable {

    // MARK: - Public API

    /// Replaces any existing `[mcp_servers.calyx-ipc]` entry (its
    /// `[mcp_servers.calyx-ipc.headers]` sub-table included) with a
    /// freshly built one for `port`/`token`, preserving everything else
    /// in the file verbatim.
    ///
    /// The replacement is keyed on the section header alone, with no
    /// Calyx ownership marker: a `[mcp_servers.calyx-ipc]` entry a user
    /// (or an earlier experiment) wrote by hand is adopted and rewritten
    /// into the managed shape rather than duplicated. The entry name is
    /// Calyx's own, so nothing else can legitimately own it.
    ///
    /// Throws `.directoryNotFound` when `configPath`'s parent directory
    /// does not exist: Grok not being installed must never make Calyx
    /// create `~/.grok` on the user's behalf.
    static func enableIPC(port: Int, token: String, configPath: String? = nil) throws {
        let path = try ConfigFileUtils.resolveConfigPath(configPath ?? defaultConfigPath)
        let parentDir = (path as NSString).deletingLastPathComponent

        guard ConfigFileUtils.directoryExists(at: parentDir) else {
            throw GrokConfigError.directoryNotFound
        }

        let content: String
        if FileManager.default.fileExists(atPath: path) {
            content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        } else {
            content = ""
        }

        let cleaned = removeSections(from: content)

        let section = """
        [mcp_servers.calyx-ipc]
        url = "http://127.0.0.1:\(port)/mcp"

        [mcp_servers.calyx-ipc.headers]
        Authorization = "Bearer \(token)"
        X-Calyx-Agent-Kind = "\(AgentEntry.grokKind)"
        X-Calyx-Session-ID = "${CALYX_SESSION_ID:-}"
        X-Calyx-Surface-ID = "${CALYX_SURFACE_ID:-}"
        """

        var result = cleaned
        if !result.isEmpty && !result.hasSuffix("\n\n") {
            if !result.hasSuffix("\n") {
                result += "\n"
            }
            result += "\n"
        }
        result += section + "\n"

        guard let data = result.data(using: .utf8) else {
            throw GrokConfigError.writeFailed("UTF-8 encoding failed")
        }
        try ConfigFileUtils.atomicWrite(data: data, to: path)
    }

    /// Removes every `[mcp_servers.calyx-ipc]` entry (sub-tables
    /// included) from `configPath`, leaving the rest of the file
    /// untouched. A no-op when the file does not exist, is unreadable,
    /// or carries no such entry.
    static func disableIPC(configPath: String? = nil) throws {
        let path = try ConfigFileUtils.resolveConfigPath(configPath ?? defaultConfigPath)

        guard FileManager.default.fileExists(atPath: path) else { return }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        let cleaned = removeSections(from: content)

        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        guard cleaned != normalized else { return }

        guard let data = cleaned.data(using: .utf8) else {
            throw GrokConfigError.writeFailed("UTF-8 encoding failed")
        }
        try ConfigFileUtils.atomicWrite(data: data, to: path)
    }

    /// Whether a `[mcp_servers.calyx-ipc]` section header is present.
    /// Returns `false` rather than throwing for an unresolvable symlink
    /// chain, matching `CodexConfigManager.isIPCEnabled`.
    static func isIPCEnabled(configPath: String? = nil) -> Bool {
        guard let path = try? ConfigFileUtils.resolveConfigPath(configPath ?? defaultConfigPath) else {
            return false
        }

        guard FileManager.default.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }

        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.components(separatedBy: "\n").contains { isSectionHeader($0) }
    }

    // MARK: - Private

    static var defaultConfigPath: String {
        AgentToolPaths.grokConfigDirectory + "/config.toml"
    }

    /// Regex pattern for the `[mcp_servers.calyx-ipc]` section header.
    private static let sectionHeaderPattern = #"^[ \t]*\[mcp_servers\.calyx-ipc\][ \t]*(#.*)?$"#

    /// Regex pattern for any TOML table header, standard (`[...]`) or
    /// array-of-tables (`[[...]]`). Per TOML semantics a table header
    /// always starts a new table and therefore always ends whatever table
    /// preceded it, blank line or not.
    private static let anyTableHeaderPattern = #"^[ \t]*\["#

    /// Regex pattern for a `[mcp_servers.calyx-ipc.*]` or
    /// `[[mcp_servers.calyx-ipc.*]]` sub-table header. Per TOML's
    /// dotted-key semantics the `headers` sub-table is still part of the
    /// calyx-ipc entry, so it is removed with the rest of it rather than
    /// ending it: leaving it behind would orphan a live bearer token
    /// beside the freshly written entry. TOML does not require a
    /// sub-table to sit next to its parent, so such a header belongs to
    /// the entry wherever in the file it appears.
    private static let calyxIpcSubTableHeaderPattern = #"^[ \t]*\[\[?mcp_servers\.calyx-ipc\."#

    private static func isSectionHeader(_ line: String) -> Bool {
        line.range(of: sectionHeaderPattern, options: .regularExpression) != nil
    }

    private static func isAnyTableHeader(_ line: String) -> Bool {
        line.range(of: anyTableHeaderPattern, options: .regularExpression) != nil
    }

    private static func isCalyxIpcSubTableHeader(_ line: String) -> Bool {
        line.range(of: calyxIpcSubTableHeaderPattern, options: .regularExpression) != nil
    }

    /// Removes every `[mcp_servers.calyx-ipc]` section, its sub-tables
    /// included, from `content`, normalizing `\r\n` to `\n`. A section's
    /// body ends at the next TOML table header, never at a blank line:
    /// blank lines are ordinary TOML whitespace and can sit inside a
    /// section's body, so treating one as a terminator would leave the
    /// section's tail behind.
    ///
    /// A calyx-ipc sub-table header enters the section on its own, not
    /// only while a parent header is already in scope: a
    /// `[mcp_servers.calyx-ipc.headers]` a user (or an earlier layout)
    /// left elsewhere in the file would otherwise be preserved as
    /// foreign content, and the section `enableIPC` then appends would
    /// define that same table a second time. Two definitions of one TOML
    /// table are a parse error, which costs the user every other MCP
    /// server and setting in the file, not just Calyx's entry.
    private static func removeSections(from content: String) -> String {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var result: [String] = []
        var inSection = false

        for line in lines {
            if isSectionHeader(line) || isCalyxIpcSubTableHeader(line) {
                inSection = true
                continue
            }

            if inSection {
                if isAnyTableHeader(line) {
                    inSection = false
                    result.append(line)
                    continue
                }
                continue
            }

            result.append(line)
        }

        var output = result.joined(separator: "\n")
        while output.hasSuffix("\n\n") {
            output = String(output.dropLast())
        }
        return output
    }
}
