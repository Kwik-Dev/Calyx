// AgentEndpointFile.swift
// Calyx
//
// Writes/removes `agent-endpoint.json` (port + token) so the
// calyx-agent-hook script can always reach the current IPC server, even
// after a restart or token rotation.

import Foundation

enum AgentEndpointFile {

    private static let fileName = "agent-endpoint.json"

    /// Default directory: `~/Library/Application Support/Calyx`.
    static var defaultDirectory: String {
        AppSupportDirectory.path
    }

    /// Writes `agent-endpoint.json` (0600) to `directory` with the given
    /// `port` and `token`. Uses `ConfigFileUtils.atomicWrite` (temp file +
    /// rename) rather than a direct `Data.write` so a reader — the
    /// `calyx-agent-hook` script, invoked concurrently from every active
    /// pane's hooks — never observes a partially-written file.
    static func write(port: Int, token: String, directory: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let dict: [String: Any] = ["port": port, "token": token]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let filePath = (directory as NSString).appendingPathComponent(fileName)
        try ConfigFileUtils.atomicWrite(data: data, to: filePath)
    }

    /// Removes `agent-endpoint.json` from `directory`, but only when the
    /// file on disk was published by the caller: its decoded `port` and
    /// `token` must both equal the ones passed in. A `token` of `""`
    /// (the value `CalyxMCPServer.token` holds before `start()` is ever
    /// called) is treated as an unconditional mismatch, so a server that
    /// never started can never delete a file it never wrote, even if its
    /// `port` (also defaulted, to `0`) happens to coincide with the
    /// value on disk. The file is left untouched if it is absent,
    /// unreadable, not valid JSON, or missing either key.
    ///
    /// If two Calyx instances run at once, whichever started later
    /// overwrites the file with its own port+token: the earlier
    /// instance is unreachable from that write onward, before either
    /// instance's `stop()` ever runs, because every hook invocation
    /// reads this one shared file fresh. Once the later instance's own
    /// `stop()` then matches and deletes the file, hook traffic from
    /// every pane of BOTH instances goes inert. This is left unresolved
    /// on purpose: `~/.claude.json`'s MCP server config, the hook
    /// script's install location, and calyx-session are each already a
    /// single shared resource across all running instances, so
    /// self-healing only this file would imply a multi-instance story
    /// that does not exist.
    static func remove(directory: String, port: Int, token: String) {
        guard !token.isEmpty else { return }
        let filePath = (directory as NSString).appendingPathComponent(fileName)
        guard let data = FileManager.default.contents(atPath: filePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let onDiskPort = json["port"] as? Int,
              let onDiskToken = json["token"] as? String,
              onDiskPort == port, onDiskToken == token
        else { return }
        try? FileManager.default.removeItem(atPath: filePath)
    }
}
