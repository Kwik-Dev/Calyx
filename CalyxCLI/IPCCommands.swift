//
//  IPCCommands.swift
//  CalyxCLI
//
//  CLI interface for Calyx IPC peer communication.
//  Each subcommand calls the Calyx MCP server via IPCClient.
//

import ArgumentParser
import Foundation

// MARK: - IPCCommand

struct IPCCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ipc",
        abstract: "Calyx IPC peer communication commands",
        subcommands: [
            IPCRegisterPeer.self,
            IPCListPeers.self,
            IPCSend.self,
            IPCBroadcast.self,
            IPCReceiveMessages.self,
            IPCAckMessages.self,
            IPCStatus.self,
        ]
    )
}

// MARK: - register-peer

struct IPCRegisterPeer: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "register-peer",
        abstract: "Register this CLI instance as a peer in the Calyx IPC mesh"
    )

    @Option(name: .long, help: "Peer display name")
    var name: String = ProcessInfo.processInfo.hostName

    @Option(name: .long, help: "Peer role (e.g. planner, worker, reviewer)")
    var role: String = "cli-agent"

    func run() throws {
        let client = try IPCClient.fromStateFile()
        let (peerID, message) = try client.registerPeer(name: name, role: role)
        print(peerID)
        fputs("\(message)\n", stderr)
    }
}

// MARK: - list-peers

struct IPCListPeers: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-peers",
        abstract: "List all registered peers"
    )

    func run() throws {
        let client = try IPCClient.fromStateFile()
        // Initialize first so we exist as a peer
        _ = try client.call(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "calyx-cli", "version": "1.0.0"],
        ])
        _ = try? client.call(method: "notifications/initialized", params: [:])

        let result = try client.call(method: "tools/call", params: [
            "name": AnyCodableHelper.wrap("list_peers"),
        ])

        print(result)
    }
}

// MARK: - send

struct IPCSend: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send a message to a specific peer"
    )

    @Option(name: .long, help: "Sender peer ID")
    var from: String

    @Option(name: .long, help: "Target peer ID")
    var to: String

    @Option(name: .long, help: "Message content")
    var content: String

    func run() throws {
        let client = try IPCClient.fromStateFile()
        let result = try client.call(method: "tools/call", params: [
            "name": AnyCodableHelper.wrap("send_message"),
            "arguments": AnyCodableHelper.wrap([
                "from": from,
                "to": to,
                "content": content,
            ]),
        ])
        print(result)
    }
}

// MARK: - broadcast

struct IPCBroadcast: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "broadcast",
        abstract: "Broadcast a message to all other peers"
    )

    @Option(name: .long, help: "Sender peer ID")
    var from: String

    @Option(name: .long, help: "Message content")
    var content: String

    func run() throws {
        let client = try IPCClient.fromStateFile()
        let result = try client.call(method: "tools/call", params: [
            "name": AnyCodableHelper.wrap("broadcast"),
            "arguments": AnyCodableHelper.wrap([
                "from": from,
                "content": content,
            ]),
        ])
        print(result)
    }
}

// MARK: - receive-messages

struct IPCReceiveMessages: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "receive-messages",
        abstract: "Receive pending messages for a peer"
    )

    @Option(name: .long, help: "Your peer ID")
    var from: String

    func run() throws {
        let client = try IPCClient.fromStateFile()
        let result = try client.call(method: "tools/call", params: [
            "name": AnyCodableHelper.wrap("receive_messages"),
            "arguments": AnyCodableHelper.wrap([
                "peer_id": from,
            ]),
        ])
        print(result)
    }
}

// MARK: - ack-messages

struct IPCAckMessages: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ack-messages",
        abstract: "Acknowledge and delete received messages"
    )

    @Option(name: .long, help: "Your peer ID")
    var from: String

    @Option(name: .long, parsing: .upToNextOption, help: "Message IDs to acknowledge")
    var messageIds: [String] = []

    func run() throws {
        guard !messageIds.isEmpty else {
            throw ValidationError("At least one --message-ids value is required")
        }
        let client = try IPCClient.fromStateFile()
        let result = try client.call(method: "tools/call", params: [
            "name": AnyCodableHelper.wrap("ack_messages"),
            "arguments": AnyCodableHelper.wrap([
                "peer_id": from,
                "message_ids": messageIds,
            ]),
        ])
        print(result)
    }
}

// MARK: - status

struct IPCStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Get status information for a specific peer"
    )

    @Option(name: .long, help: "Peer ID to check")
    var peerId: String

    func run() throws {
        let client = try IPCClient.fromStateFile()
        let result = try client.call(method: "tools/call", params: [
            "name": AnyCodableHelper.wrap("get_peer_status"),
            "arguments": AnyCodableHelper.wrap([
                "peer_id": peerId,
            ]),
        ])
        print(result)
    }
}