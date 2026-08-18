// IPCActivationCoordinator.swift
// Calyx
//
// Owns the exact sequencing behind "Enable AI Agent IPC" / "Disable AI
// Agent IPC": resolve the MCP endpoint, write agent CLI config files,
// install agent hooks/plugins/extensions, then report integration
// issues. Every dependency is expressed as a protocol so the sequencing
// itself is testable without a real file system, a real CalyxMCPServer,
// or any networking.
//
// Fully synchronous by design: enable() and disable() both run to
// completion on the calling thread before returning. A deferred-
// completion seam here would let a second enable/disable start while
// the first is still read-modify-writing the same agent config files,
// and would let palette_execute report a call finished before the
// underlying work actually had.

import Foundation
import Security

// MARK: - Seams

/// The running MCP server's control surface, as this coordinator needs
/// it. `port`/`token` are only meaningful once `isRunning` is true.
@MainActor
protocol IPCServerControlling {
    var isRunning: Bool { get }
    var port: Int { get }
    var token: String { get }
    func start(token: String) throws
    func stop()
}

/// Writes or removes the calyx-ipc entry in every supported agent CLI's
/// MCP client configuration file.
protocol IPCAgentConfigInstalling: Sendable {
    func enableIPC(port: Int, token: String) -> IPCConfigResult
    func disableIPC() -> IPCConfigResult
}

/// Installs or removes the calyx-agent-hook script plus each agent
/// CLI's own hook/plugin/extension wiring to it.
protocol IPCAgentHooksInstalling: Sendable {
    func install() -> AgentHooksResult
    func remove() -> AgentHooksResult
}

/// Produces the bearer token a freshly started server authenticates
/// with.
protocol IPCTokenGenerating: Sendable {
    func makeToken() throws -> String
}

/// Publishes the current set of agent integration failures to the
/// standing sidebar banner, config and hooks domains reported through
/// separate methods so one domain's write can never overwrite the
/// other's. `AgentRegistry` itself keeps the two domains as separate
/// stored properties for the same reason, since `AppDelegate`'s
/// launch-time hooks re-sync writes the hooks domain directly rather
/// than through this coordinator or this protocol.
@MainActor
protocol IPCIntegrationIssueReporting {
    func reportConfigIssues(_ issues: [String])
    func reportHooksIssues(_ issues: [String])
}

// MARK: - Reports

/// The outcome of a successful `enable()` call: the server is up
/// (freshly started or already running) and every independent
/// integration step has run exactly once.
struct IPCActivationReport: Sendable {
    let port: Int
    let wasAlreadyRunning: Bool
    let config: IPCConfigResult
    let hooks: AgentHooksResult

    /// True when at least one agent CLI is reachable through either its
    /// config file or its hooks/plugin/extension axis. pi has no config
    /// axis at all, so `hooks.anySucceeded` is its only signal here.
    var anyAgentWired: Bool { config.anySucceeded || hooks.anySucceeded }
}

enum IPCActivationOutcome: Sendable {
    case enabled(IPCActivationReport)
    case tokenGenerationFailed
    case serverStartFailed(Error)
}

struct IPCDeactivationReport: Sendable {
    let config: IPCConfigResult
    let hooks: AgentHooksResult
}

// MARK: - IPCActivationCoordinator

@MainActor
struct IPCActivationCoordinator {
    private let server: IPCServerControlling
    private let configInstaller: IPCAgentConfigInstalling
    private let hooksInstaller: IPCAgentHooksInstalling
    private let tokenGenerator: IPCTokenGenerating
    private let issueReporter: IPCIntegrationIssueReporting

    init(
        server: IPCServerControlling = LiveIPCServerControl(),
        configInstaller: IPCAgentConfigInstalling = LiveIPCAgentConfigInstaller(),
        hooksInstaller: IPCAgentHooksInstalling = LiveIPCAgentHooksInstaller(),
        tokenGenerator: IPCTokenGenerating = SecureRandomTokenGenerator(),
        issueReporter: IPCIntegrationIssueReporting = AgentRegistryIssueReporter()
    ) {
        self.server = server
        self.configInstaller = configInstaller
        self.hooksInstaller = hooksInstaller
        self.tokenGenerator = tokenGenerator
        self.issueReporter = issueReporter
    }

    /// Resolves the MCP endpoint, then always runs both the agent config
    /// write and the agent hooks install -- neither step is gated on the
    /// other's result, since pi's only integration path is the hooks
    /// install and it has no config axis at all. Never stops the server:
    /// `CalyxMCPServer` also serves the LSP proxy, cockpit tools,
    /// command-log tools and any hand-configured MCP client, none of
    /// which depend on an agent CLI config file. herdr panes reach Calyx
    /// over their own transport, independent of this server entirely.
    func enable() -> IPCActivationOutcome {
        let port: Int
        let token: String
        let wasAlreadyRunning: Bool

        if server.isRunning {
            // Reuse the live endpoint. CalyxMCPServer.start(token:)
            // stops a running server before starting a new one, which
            // deletes agent-endpoint.json, resets the Agents sidebar,
            // and expires pending approvals -- restarting here would do
            // that to every already-connected agent just to re-run
            // config/hooks install.
            port = server.port
            token = server.token
            wasAlreadyRunning = true
        } else {
            do {
                token = try tokenGenerator.makeToken()
            } catch {
                return .tokenGenerationFailed
            }
            do {
                try server.start(token: token)
            } catch {
                return .serverStartFailed(error)
            }
            // Read back after start() returns: the server resolves its
            // actual listening port during start, not before.
            port = server.port
            wasAlreadyRunning = false
        }

        let config = configInstaller.enableIPC(port: port, token: token)
        let hooks = hooksInstaller.install()
        issueReporter.reportConfigIssues(config.issueMessages)
        issueReporter.reportHooksIssues(hooks.issueMessages)

        return .enabled(IPCActivationReport(port: port, wasAlreadyRunning: wasAlreadyRunning, config: config, hooks: hooks))
    }

    /// Stops the server (this type's only stop call site), then removes
    /// the agent config entries and agent hooks independently of each
    /// other. Removal failures are surfaced only in the returned report,
    /// not as a standing banner -- both banner domains are cleared here
    /// instead, since a config/hook entry that no longer matters once
    /// IPC is off should not keep warning the user.
    func disable() -> IPCDeactivationReport {
        server.stop()
        let config = configInstaller.disableIPC()
        let hooks = hooksInstaller.remove()
        issueReporter.reportConfigIssues([])
        issueReporter.reportHooksIssues([])
        return IPCDeactivationReport(config: config, hooks: hooks)
    }
}

// MARK: - Live adapters

@MainActor
struct LiveIPCServerControl: IPCServerControlling {
    var isRunning: Bool { CalyxMCPServer.shared.isRunning }
    var port: Int { CalyxMCPServer.shared.port }
    var token: String { CalyxMCPServer.shared.token }

    func start(token: String) throws {
        try CalyxMCPServer.shared.start(token: token)
    }

    /// The server's own stop reports completion through a handle this
    /// coordinator has no use for; discarding it keeps enable/disable
    /// fully synchronous end to end.
    func stop() {
        _ = CalyxMCPServer.shared.stop()
    }
}

struct LiveIPCAgentConfigInstaller: IPCAgentConfigInstalling {
    func enableIPC(port: Int, token: String) -> IPCConfigResult {
        IPCConfigManager.enableIPC(port: port, token: token)
    }

    func disableIPC() -> IPCConfigResult {
        IPCConfigManager.disableIPC()
    }
}

struct LiveIPCAgentHooksInstaller: IPCAgentHooksInstalling {
    func install() -> AgentHooksResult {
        AgentHooksCoordinator.install()
    }

    func remove() -> AgentHooksResult {
        AgentHooksCoordinator.remove()
    }
}

/// Thrown by `SecureRandomTokenGenerator.makeToken()` when
/// `SecRandomCopyBytes` reports a non-success status. The presenter
/// renders a fixed message for `.tokenGenerationFailed` regardless of
/// the underlying status, so this carries it only for diagnostics.
enum TokenGenerationError: Error, Sendable {
    case secureRandomFailed(OSStatus)
}

struct SecureRandomTokenGenerator: IPCTokenGenerating {
    func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw TokenGenerationError.secureRandomFailed(status)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
struct AgentRegistryIssueReporter: IPCIntegrationIssueReporting {
    func reportConfigIssues(_ issues: [String]) {
        AgentRegistry.shared.setConfigIssues(issues)
    }

    func reportHooksIssues(_ issues: [String]) {
        AgentRegistry.shared.setHooksIssues(issues)
    }
}
