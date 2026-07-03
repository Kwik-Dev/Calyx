// CrushConfigManager.swift
// Calyx
//
// Manages reading/writing Charm Crush's config file for the Calyx IPC MCP server.
//
// Crush uses `~/.config/crush/crush.json` with an `mcp` key containing named
// MCP server entries. Calyx upserts a `calyx-ipc` entry of type `http`
// with Bearer-token Authorization.

import Foundation

// MARK: - CrushConfigError

enum CrushConfigError: Error, LocalizedError {
    case invalidJSON
    case symlinkDetected
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "The crush.json file contains invalid JSON"
        case .symlinkDetected:
            return "A Crush config path is a symlink, which is not allowed for security reasons"
        case .writeFailed(let reason):
            return "Failed to write Crush config: \(reason)"
        }
    }
}

// MARK: - CrushConfigManager

struct CrushConfigManager: Sendable {

    private static let mcpKey = "mcp"
    private static let calyxIPCKey = "calyx-ipc"

    // MARK: - Public API

    /// Upserts a `calyx-ipc` MCP entry into Crush's config.
    static func enableIPC(port: Int, token: String, configDir: String? = nil) throws {
        let dir = configDir ?? defaultConfigDir
        let configPath = dir + "/crush.json"

        // Ensure the config directory exists (Crush may not have run yet).
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        guard !ConfigFileUtils.isSymlink(at: configPath) else {
            throw CrushConfigError.symlinkDetected
        }

        var config: [String: Any]

        if fm.fileExists(atPath: configPath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            if data.isEmpty {
                config = [:]
            } else {
                guard let parsed = try? JSONSerialization.jsonObject(with: data),
                      let dict = parsed as? [String: Any] else {
                    throw CrushConfigError.invalidJSON
                }
                config = dict
            }
        } else {
            config = [:]
        }

        // Build the calyx-ipc entry
        let calyxEntry: [String: Any] = [
            "type": "http",
            "url": "http://localhost:\(port)/mcp",
            "headers": [
                "Authorization": "Bearer \(token)",
            ],
        ]

        var mcp = config[mcpKey] as? [String: Any] ?? [:]
        mcp[calyxIPCKey] = calyxEntry
        config[mcpKey] = mcp

        let outputData = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )

        try ConfigFileUtils.atomicWrite(
            data: outputData,
            to: configPath,
            lockPath: configPath + ".lock"
        )
    }

    /// Removes the `calyx-ipc` entry from Crush's config.
    static func disableIPC(configDir: String? = nil) throws {
        let dir = configDir ?? defaultConfigDir
        let configPath = dir + "/crush.json"
        let fm = FileManager.default

        guard fm.fileExists(atPath: configPath) else { return }

        guard !ConfigFileUtils.isSymlink(at: configPath) else {
            throw CrushConfigError.symlinkDetected
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        guard !data.isEmpty else { return }

        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              var config = parsed as? [String: Any] else {
            throw CrushConfigError.invalidJSON
        }

        guard var mcp = config[mcpKey] as? [String: Any] else { return }

        mcp.removeValue(forKey: calyxIPCKey)

        if mcp.isEmpty {
            config.removeValue(forKey: mcpKey)
        } else {
            config[mcpKey] = mcp
        }

        let outputData = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )

        try ConfigFileUtils.atomicWrite(
            data: outputData,
            to: configPath,
            lockPath: configPath + ".lock"
        )
    }

    /// Returns whether the `calyx-ipc` MCP entry is present in Crush's config.
    static func isIPCEnabled(configDir: String? = nil) -> Bool {
        let dir = configDir ?? defaultConfigDir
        let configPath = dir + "/crush.json"

        guard FileManager.default.fileExists(atPath: configPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let config = parsed as? [String: Any],
              let mcp = config[mcpKey] as? [String: Any] else {
            return false
        }

        return mcp[calyxIPCKey] != nil
    }

    // MARK: - Private

    private static var defaultConfigDir: String {
        NSHomeDirectory() + "/.config/crush"
    }
}