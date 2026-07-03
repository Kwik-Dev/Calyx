# Spec: Pi Coding Agent IPC Support

**PR label:** `ipc`, `pi`
**Depends on:** `00-generic-ipc-discovery-and-cli`
**Related:** `02-crush-agent-support`

## Motivation

Pi (`@earendil-works/pi-coding-agent`) has **no built-in MCP client**.
Unlike Claude Code, Codex, OpenCode, or Hermes, pi cannot be taught about a
remote MCP server by writing a standard JSON/YAML config entry.  Pi is extended
through [skills](https://agentskills.io/specification) — self-contained
Markdown directories loaded on demand by the agent.

To let pi instances running inside Calyx terminal tabs participate in the IPC
peer mesh, Calyx installs a **pi skill** that teaches pi how to use the
`calyx ipc` CLI (from `00-generic-ipc-discovery-and-cli`) to register as a peer
and send/receive messages.

## Changes

### 1. PiConfigManager (`Calyx/Features/IPC/PiConfigManager.swift`)

| Aspect | Detail |
|---|---|
| Skill directory | `~/.pi/agent/skills/calyx-ipc/` |
| Skill file | `SKILL.md` |
| Enable | Creates (or replaces) the directory, writes `SKILL.md` atomically |
| Disable | Removes `~/.pi/agent/skills/calyx-ipc/` if present |
| Is-enabled check | Returns `true` iff `SKILL.md` exists and contains both BEGIN/END Calyx markers |
| Installed check | `~/.pi/agent/skills` directory must exist; if not, the operation is silently skipped (pi is not installed) |

**Design rationale:**
- **Global install** (`~/.pi/agent/skills/`) matches other Calyx config managers
  which write to the user's home directory, not the project.
- **Idempotent:** re-enabling removes the old directory first, then writes a
  fresh one, guaranteeing exactly one managed block.
- **No baked secrets:** the `SKILL.md` body contains only static instructions
  referencing `calyx ipc`.  Secrets live in `~/.config/calyx/ipc.json`
  (permissions `0600`, written by the server, not duplicated in the skill).
- **Symlink rejection** on both the skill directory and `SKILL.md` before any
  write, matching the security posture of every other `*ConfigManager`.

#### Skill content (SKILL.md)

```yaml
---
name: calyx-ipc
description: Connects pi to other Calyx IPC agents via the calyx CLI.
             Use when running pi inside Calyx and you need to coordinate
             with other terminal panes.
---
```

The body teaches pi to:
1. Ensure `calyx` CLI is installed (`Install CLI to PATH` in Command Palette).
2. Register once: `PEER_ID=$(calyx ipc register-peer --name "<…>" --role "…")`.
3. After significant work, check messages with
   `calyx ipc receive-messages --from "$PEER_ID"`.
4. Respond with `calyx ipc send --from "$PEER_ID" --to "$OTHER" --content "…"`.
5. Discover peers with `calyx ipc list-peers`.
6. Broadcast with `calyx ipc broadcast --from "$PEER_ID" --content "…"`.

A full CLI reference table is included.

#### Error types

```swift
enum PiConfigError: Error, LocalizedError {
    case symlinkDetected
    case writeFailed(String)
}
```

### 2. IPCConfigManager wiring

`IPCConfigManager` gained a `pi` axis alongside the existing four:

| Method | Behaviour |
|---|---|
| `enableIPC` | Calls `PiConfigManager.enableIPC()`; skipped if `~/.pi/agent/skills` missing |
| `disableIPC` | Calls `PiConfigManager.disableIPC()` |
| `isIPCEnabled` | Returns `PiConfigManager.isIPCEnabled()` as the `.pi` tuple member |

`IPCConfigResult` now carries `pi: ConfigStatus`.

### 3. UI strings (`CalyxWindowController.swift`)

| Location | Change |
|---|---|
| `configStatusMessage` | Added `"pi: …"` line |
| `isAIAgentTitle` | Added `localizedCaseInsensitiveContains("pi")` |
| "No AI Agent" alert | Lists pi |

### 4. Documentation (`README.md`)

- AI Agent IPC section: pi added to agent list.
- Diff Review Comments: pi mentioned as a target.
- IPC config paths: `~/.pi/agent/skills/calyx-ipc/SKILL.md` noted.

### 5. Tests (`CalyxTests/IPC/PiConfigManagerTests.swift`)

10 test cases covering:

| Test | What it verifies |
|---|---|
| `test_enableIPC_createsSkillDirectoryAndFile` | Directory + `SKILL.md` created with correct markers and content |
| `test_enableIPC_idempotent` | Running enable twice → exactly one BEGIN/END pair |
| `test_enableIPC_replacesStaleSkillDir` | Old content replaced, not appended |
| `test_disableIPC_removesSkillDirectory` | Directory gone after disable |
| `test_disableIPC_noDir_noOp` | Missing dir → no throw |
| `test_isIPCEnabled_trueAfterEnable` | Detection after write |
| `test_isIPCEnabled_falseBeforeEnable` | Detection when absent |
| `test_isIPCEnabled_falseAfterDisable` | Detection after cleanup |
| `test_enableIPC_symlinkSkillDirRejected` | Symlink on dir → throw |
| `test_enableIPC_symlinkSkillFileRejected` | Symlink on file → throw |

**Updated tests:**
- `IPCConfigManagerTests` extended with `onlyPi` and `allSixFail` cases for the new axis.

## Acceptance criteria

- [ ] **Enable AI Agent IPC** installs the pi skill when `~/.pi/agent/skills` exists.
- [ ] **Disable AI Agent IPC** removes the skill directory.
- [ ] `IPCConfigManager.isIPCEnabled().pi` reflects the current state.
- [ ] A pi session that loads the skill can register, list peers, send, and receive.
- [ ] Symlink paths are rejected with a descriptive error.
- [ ] All pi-specific tests pass.

## Non-goals

- Shipping an MCP client inside Calyx for pi.
- Generating a pi extension (TypeScript) — a skill is the idiomatic pi primitive.
- Project-level `.pi/skills/` installs — only global (`~/.pi/agent/skills/`) for now.