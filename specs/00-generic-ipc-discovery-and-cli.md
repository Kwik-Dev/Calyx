# Spec: Generic IPC Discovery & CLI

**PR label:** `ipc`, `cli`
**Depends on:** none (foundation layer)
**Required by:** `01-pi-agent-support`, `02-crush-agent-support`

## Motivation

Before this change the Calyx IPC MCP server had no discoverability mechanism for
external tools.  Existing agents (Claude Code, Codex, OpenCode, Hermes) register
via the MCP handshake — they already know where the server lives because their
config files were written by Calyx itself.  A generic `calyx` CLI user, a pi
skill, or any other external tool had no way to find the server's **port** and
**bearer token**.

This spec adds a lightweight state-file convention (mirroring the existing
`~/.config/calyx/browser.json`) and exposes the IPC peer tools as native
`calyx ipc` CLI subcommands so anything — not just MCP-native agents — can join
the peer mesh.

## Changes

### 1. IPC state file (`CalyxMCPServer.swift`)

| Aspect | Detail |
|---|---|
| File written | `~/.config/calyx/ipc.json` |
| Written on | `CalyxMCPServer.start()` after successful port bind |
| Removed on | `CalyxMCPServer.stop()` |
| Contents | `port`, `token`, `url` ("http://localhost:PORT/mcp"), `pid` |
| Permissions | `0o600` |
| Directory | Created via `~/.config/calyx/` with intermediate directories |

**Design rationale:** One canonical location. No environment variables to leak.
The CLI (and pi skill indirectly) reads this file, so secrets never appear in
shell history or process listings.  The `url` field is pre-computed so consumers
don't need to construct it themselves.

**Code:** two new private methods on `CalyxMCPServer`:
- `writeStateFile()`
- `removeStateFile()`

### 2. IPC client (`CalyxCLI/IPCClient.swift`)

| Aspect | Detail |
|---|---|
| Type | `struct IPCClient` |
| Construction | `IPCClient.fromStateFile()` reads `~/.config/calyx/ipc.json` |
| Transport | `curl` subprocess → `POST /mcp` with `Authorization: Bearer TOKEN` |
| Protocol | JSON-RPC 2.0 (same as the MCP server expects) |
| Key method | `call(method:params:)` → sends request, returns result text |
| Convenience | `registerPeer(name:role:)` auto-initializes, registers, and returns peer ID |

**Design rationale:** Mirrors `BrowserClient` (`CalyxCLI/MCPClient.swift`).
Uses `/usr/bin/curl` (always present on macOS) rather than `URLSession` to
avoid network-entitlement complications in a CLI-tool target.  The
`registerPeer` shortcut handles the initialize→tool-call→notifications flow so
each CLI subcommand doesn't need to repeat the handshake.

### 3. IPC subcommands (`CalyxCLI/IPCCommands.swift`)

Registered as `calyx ipc` command group via `CalyxCLI.swift`.

| Subcommand | Options | Maps to MCP tool |
|---|---|---|
| `register-peer` | `--name`, `--role` | `register_peer` (via initialize) |
| `list-peers` | — | `list_peers` |
| `send` | `--from`, `--to`, `--content` | `send_message` |
| `broadcast` | `--from`, `--content` | `broadcast` |
| `receive-messages` | `--from` | `receive_messages` |
| `ack-messages` | `--from`, `--message-ids` | `ack_messages` |
| `status` | `--peer-id` | `get_peer_status` |

Each subcommand:
1. Calls `IPCClient.fromStateFile()` for connection info.
2. Sends the corresponding JSON-RPC `tools/call`.
3. Prints the result text to stdout (errors go to stderr, non-zero exit).

**Design rationale:** Flat subcommands (rather than `calyx ipc tool call …`)
match the existing `calyx browser` UX.  A human or an agent can type them
directly without remembering JSON-RPC field names.

### 4. Wiring

| File | Change |
|---|---|
| `CalyxCLI/CalyxCLI.swift` | Added `IPCCommand.self` to `subcommands` |

## Acceptance criteria

- [ ] Starting the IPC server writes `~/.config/calyx/ipc.json` with correct fields.
- [ ] Stopping the server removes the file.
- [ ] `calyx ipc register-peer --name test --role cli` prints a peer ID.
- [ ] `calyx ipc list-peers` shows the registered peer.
- [ ] Sending a message between two registered peers succeeds.
- [ ] File permissions are `0600` (owner read/write only) throughout.

## Test coverage

Covered implicitly by the existing `CalyxMCPServerTests` (which start/stop the
server without a real TCP bind in the current test suite) and by the manual
acceptance-criteria flow above.  The CLI module (`CalyxCLI`) does not have its
own unit-test target (it's built as a command-line tool); integration is
verified through the pi and crush test suites which exercise the config-manager
wiring.

## Relationship to pi / crush specs

This spec is **agent-agnostic**.  The pi skill (`specs/01-pi-agent-support.md`)
and the Crush config manager (`specs/02-crush-agent-support.md`) both rely on
the state file and CLI added here.  Without this foundation neither pi nor Crush
could discover the IPC server without manual configuration.