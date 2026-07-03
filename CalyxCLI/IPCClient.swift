//
//  IPCClient.swift
//  CalyxCLI
//
//  HTTP client that communicates directly with the Calyx IPC MCP server.
//  Reads connection info from ~/.config/calyx/ipc.json.
//

import Foundation

struct IPCClient {
    let port: Int
    let token: String
    let url: String

    /// Read connection info from ~/.config/calyx/ipc.json
    static func fromStateFile() throws -> IPCClient {
        let stateFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/calyx/ipc.json")

        guard FileManager.default.fileExists(atPath: stateFile.path) else {
            throw CLIError.ipcNotRunning
        }

        let data = try Data(contentsOf: stateFile)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = json["port"] as? Int,
              let token = json["token"] as? String,
              let url = json["url"] as? String else {
            throw CLIError.invalidIPCStateFile
        }
        return IPCClient(port: port, token: token, url: url)
    }

    /// Call a JSON-RPC method on the IPC server and return the result text.
    func call(method: String, params: [String: Any] = [:]) throws -> String {
        // Auto-register via initialize so the peer gets an ID
        let isInitialize = method == "initialize"
        var requestID: Any = 1

        // Build JSON-RPC request
        var requestBody: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        if !isInitialize {
            requestBody["id"] = requestID
        }

        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)
        guard let bodyStr = String(data: bodyData, encoding: .utf8) else {
            throw CLIError.invalidResponse
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = [
            "-s", "--connect-timeout", "5", "--max-time", "30",
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", "Authorization: Bearer \(token)",
            "-d", bodyStr,
            url,
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw CLIError.connectionFailed("curl exit code \(proc.terminationStatus): \(errStr.prefix(200))")
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()

        // For notifications (no id), server returns 204 — treat as success
        if data.isEmpty {
            return ""
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8) ?? "(binary)"
            throw CLIError.connectionFailed("Invalid JSON-RPC response: \(raw.prefix(500))")
        }

        // Check for JSON-RPC error
        if let rpcError = json["error"] as? [String: Any],
           let msg = rpcError["message"] as? String {
            throw CLIError.toolError(msg)
        }

        // Extract result
        if let result = json["result"] as? [String: Any],
           let content = result["content"] as? [[String: Any]],
           let first = content.first,
           let text = first["text"] as? String {
            return text
        }

        // For initialize, result has peer_id in instructions
        if let result = json["result"] as? [String: Any],
           let instructions = result["instructions"] as? String {
            return instructions
        }

        throw CLIError.invalidResponse
    }

    /// Remove a peer and its inbox from the IPC store (for --cleanup on register).
    /// This is a convenience that sends a tools/call for register_peer.
    func registerPeer(name: String, role: String) throws -> (peerID: String, message: String) {
        let initResult = try call(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": [
                "name": "calyx-cli",
                "version": "1.0.0",
            ],
        ])

        // The initialize response contains the peer ID in instructions
        var peerID = ""
        if let range = initResult.range(of: "peer_id is: ") {
            let start = range.upperBound
            let end = initResult[start...].firstIndex(of: "\n") ?? initResult.endIndex
            peerID = String(initResult[start..<end]).trimmingCharacters(in: .whitespaces)
        }

        // Call register_peer to set a proper name/role
        let registerResult = try call(method: "tools/call", params: [
            "name": AnyCodableHelper.wrap("register_peer"),
            "arguments": AnyCodableHelper.wrap([
                "name": name,
                "role": role,
            ]),
        ])

        // Parse the register result JSON to get the new peer ID
        if let regData = registerResult.data(using: .utf8),
           let regJson = try? JSONSerialization.jsonObject(with: regData) as? [String: Any],
           let regPeerID = regJson["peerId"] as? String {
            peerID = regPeerID
        }

        // Also send initialized notification
        _ = try? call(method: "notifications/initialized", params: [:])

        return (peerID, "Registered as \"\(name)\" (\(role)) — peer ID: \(peerID)")
    }
}

// MARK: - AnyCodable Helper (local to CLI, mirrors MCPProtocol's pattern)

enum AnyCodableHelper {
    static func wrap(_ value: Any) -> Any {
        value
    }
}

extension CLIError {
    static let ipcNotRunning = CLIError.notRunning
    static let invalidIPCStateFile = CLIError.invalidStateFile
}