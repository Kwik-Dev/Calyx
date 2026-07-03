# Agent Handoff — pi support for Calyx IPC

**Date:** 2026-06-23
**Branch:** current worktree is on `gitbutler/workspace`
**Goal:** Add pi coding-agent support to Calyx's AI Agent IPC.

---

## Current status

- Explored the existing IPC integration (Claude Code / Codex / OpenCode / Hermes config managers, MCP server, CLI `calyx browser`).
- Investigated pi's extensibility model: pi has no built-in MCP client; the correct integration is a **pi skill** installed under `~/.pi/agent/skills/calyx-ipc/`.
- Created a detailed implementation plan (see below).
- Tried to create real GitHub issues with the environment PAT, but the token lacks `issue:write` to `Kwik-Dev/Calyx` (REST returned 403). GitHub GraphQL project access works, so **four draft items were added to project #4 "Calyx fork by kwiksher"** in the **Backlog** column:
  1. `Feature Request: Add pi coding agent support to AI Agent IPC`
  2. `Feature Request: Add Charm Crush agent support to AI Agent IPC`
  3. `Set up Calyx build/development environment`
  4. `Agent handoff: pi support plan & environment blockers`
- The `.pi/settings.json` already contains the GitHub orchestrator config pointing at `Kwik-Dev/Calyx` project 4.

---

## Environment blockers before coding

| Tool | Current state | Why needed |
|---|---|---|
| **Full Xcode 26+** | CLT only; `xcodebuild` reports it requires Xcode | Build/run Calyx |
| **XcodeGen** | not installed | Generate `.xcodeproj` from `project.yml` |
| **Zig** | not installed | Build `libghostty` / GhosttyKit.xcframework if needed |
| **gh CLI** | not installed | Create real issues/PRs and project-board moves (the orchestrator prefers `gh auth token`) |

`GhosttyKit.xcframework` is present and the git-lfs object has been pulled (135 MB ar archive), so building the app may work without re-running Zig.

Install path to unblock:

```bash
brew install gh && gh auth login
# Install Xcode 26+ from the App Store, then:
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -runFirstLaunch
brew install xcodegen zig
```

---

## Proposed implementation plan

### New files

- `Calyx/Features/IPC/PiConfigManager.swift` — idempotent enable/disable of the pi skill, symlink rejection.
- `CalyxCLI/IPCClient.swift` — client that reads `~/.config/calyx/ipc.json` and calls `POST /mcp` JSON-RPC.
- `CalyxCLI/IPCCommands.swift` — ArgumentParser subcommands for `calyx ipc *`.
- `CalyxTests/IPC/PiConfigManagerTests.swift` — unit tests.

### Files to modify

- `Calyx/Features/IPC/CalyxMCPServer.swift` — write/remove `~/.config/calyx/ipc.json` on start/stop.
- `Calyx/Features/IPC/IPCConfigManager.swift` — add `pi` axis to enable/disable/isIPCEnabled/result.
- `Calyx/Views/MainWindow/CalyxWindowController.swift` — add pi to status message and agent detection.
- `CalyxCLI/CalyxCLI.swift` — register the `ipc` command group.
- `README.md` — list pi alongside other supported agents.
- `CalyxTests/IPC/IPCConfigManagerTests.swift` — extend tests for the new axis.

### pi skill contents

Install path: `~/.pi/agent/skills/calyx-ipc/SKILL.md`

Frontmatter:

```yaml
---
name: calyx-ipc
description: Connects pi to other Calyx IPC agents via the calyx CLI. Use when running pi inside Calyx and you need to coordinate with other terminal panes.
---
```

Instructions:

1. Ensure Calyx's CLI is installed: run **Install CLI to PATH** in Calyx's Command Palette.
2. After starting this pi session, register once:
   ```bash
   PEER_ID=$(calyx ipc register-peer --name "<task-or-folder>" --role "coder")
   ```
3. After significant work, check for messages:
   ```bash
   calyx ipc receive-messages --from "$PEER_ID"
   ```
   Process them and respond with:
   ```bash
   calyx ipc send --from "$PEER_ID" --to "$OTHER_PEER_ID" --content "..."
   ```
4. Discover peers with `calyx ipc list-peers`.
5. Announce to all peers with `calyx ipc broadcast --from "$PEER_ID" --content "..."`.

### `calyx ipc` CLI commands

- `calyx ipc register-peer --name <name> --role <role>`
- `calyx ipc list-peers`
- `calyx ipc send --from <peer-id> --to <peer-id> --content <text>`
- `calyx ipc broadcast --from <peer-id> --content <text>`
- `calyx ipc receive-messages --from <peer-id>`
- `calyx ipc ack-messages --from <peer-id> --message-ids <id>...`
- `calyx ipc status --peer-id <peer-id>`

The CLI reads `~/.config/calyx/ipc.json` for URL/token and uses raw JSON-RPC over HTTP, matching the existing `BrowserClient` pattern.

### Acceptance criteria

- Enable AI Agent IPC installs the pi skill when `~/.pi/agent/skills` exists.
- Disable AI Agent IPC removes the skill directory.
- `IPCConfigManager.isIPCEnabled()` exposes a `pi` flag.
- A pi instance running in a Calyx terminal can follow the skill to list peers and send/receive messages.
- Unit tests cover enable/disable/idempotency/symlink rejection for the pi skill.

---

## Crush agent support (new)

Charm Crush (`charmbracelet/crush`) has native MCP client support via `http`, `stdio`, and `sse` transports in its `crush.json` config file. This makes it similar to OpenCode/Codex — Calyx can upsert a `calyx-ipc` MCP entry directly into Crush's config.

### Config target

- Primary: `~/.config/crush/crush.json`
- MCP key: `mcp.calyx-ipc`
- Entry type: `"http"`
- URL: `http://localhost:PORT/mcp`
- Headers: `{ "Authorization": "Bearer TOKEN" }`

### Implementation (mirrors Codex/OpenCode pattern)

- New file: `Calyx/Features/IPC/CrushConfigManager.swift`
- Upsert/remove the entry under the `mcp` object in `crush.json`
- Reuse `ConfigFileUtils.atomicWrite` + symlink rejection
- Add `crush` axis to `IPCConfigResult`, `IPCConfigManager`, `isAIAgentTitle`, UI labels, README
- Tests: `CalyxTests/IPC/CrushConfigManagerTests.swift`

## Next steps for the resuming session

1. Install the tools listed above.
2. Convert the project draft items into real issues (or keep them as drafts) and move the feature request to **Ready** when approved.
3. Begin coding per the implementation plan, starting with the IPC state file + CLI client, then `PiConfigManager`, then wiring it into `IPCConfigManager` and the UI, and finally tests + README.

---

## Reference IDs

- Repository: `Kwik-Dev/Calyx`
- GitHub Project: #4 — `Calyx fork by kwiksher` (`PVT_kwDOEZatVs4BbbbW`)
- Backlog Status option ID: `9ccfa644`
