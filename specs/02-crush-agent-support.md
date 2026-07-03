# Spec: Charm Crush Agent IPC Support

**PR label:** `ipc`, `crush`
**Depends on:** `00-generic-ipc-discovery-and-cli`
**Related:** `01-pi-agent-support`

## Motivation

[Charm Crush](https://github.com/charmbracelet/crush) (`charmbracelet/crush`)
has **native MCP client support** via `http`, `stdio`, and `sse` transport types
in its `crush.json` configuration file.  This makes Crush similar to OpenCode
and Codex — Calyx can directly upsert a `calyx-ipc` MCP server entry into
Crush's config, no skill or extension needed.

## Changes

### 1. CrushConfigManager (`Calyx/Features/IPC/CrushConfigManager.swift`)

| Aspect | Detail |
|---|---|
| Config file | `~/.config/crush/crush.json` |
| MCP key path | `mcp.calyx-ipc` |
| Entry type | `"http"` |
| URL | `http://localhost:PORT/mcp` |
| Auth | `"headers": { "Authorization": "Bearer TOKEN" }` |
| Enable | Upserts the `calyx-ipc` entry under `mcp`; creates file + directory if needed |
| Disable | Removes the `calyx-ipc` entry; drops the `mcp` key if it becomes empty |
| Is-enabled check | `true` if `mcp.calyx-ipc` exists in the parsed JSON |
| Installed check | `~/.config/crush` directory must exist; if not, the operation is silently skipped |

**Design rationale:**
- Follows the exact same pattern as `OpenCodeConfigManager` and
  `CodexConfigManager`: parse JSON → upsert key → atomic write.
- Entry type is `"http"` (not `"remote"`) because that is Crush's convention for
  HTTP-based MCP servers.
- Uses `ConfigFileUtils.atomicWrite` with `flock`-based locking and `.tmp`
  rename, matching all other config managers.
- Symlink rejection on the config path before any read or write.

#### Error types

```swift
enum CrushConfigError: Error, LocalizedError {
    case invalidJSON
    case symlinkDetected
    case writeFailed(String)
}
```

### 2. IPCConfigManager wiring

`IPCConfigManager` gained a `crush` axis:

| Method | Behaviour |
|---|---|
| `enableIPC` | Calls `CrushConfigManager.enableIPC(port:token:)`; skipped if `~/.config/crush` missing |
| `disableIPC` | Calls `CrushConfigManager.disableIPC()` |
| `isIPCEnabled` | Returns `CrushConfigManager.isIPCEnabled()` as the `.crush` tuple member |

`IPCConfigResult` now carries `crush: ConfigStatus`.

### 3. UI strings (`CalyxWindowController.swift`)

| Location | Change |
|---|---|
| `configStatusMessage` | Added `"Crush: …"` line |
| `isAIAgentTitle` | Added `localizedCaseInsensitiveContains("crush")` |
| "No AI Agent" alert | Lists Crush |

### 4. Documentation (`README.md`)

- AI Agent IPC section: Crush added to agent list.
- Diff Review Comments: Crush mentioned as a target.
- IPC config paths: `~/.config/crush/crush.json` noted.

### 5. Tests (`CalyxTests/IPC/CrushConfigManagerTests.swift`)

12 test cases covering:

| Test | What it verifies |
|---|---|
| `test_enableIPC_createsCrushJSONFromScratch` | File + entry created with `type: http` and Bearer token |
| `test_enableIPC_preservesOtherMCPServers` | Existing `other-server` survives upsert |
| `test_enableIPC_preservesOtherTopLevelKeys` | `theme`, `model` keys preserved |
| `test_enableIPC_upsertsExistingCalyxEntry` | Old entry replaced (not duplicated) with new port/token |
| `test_disableIPC_removesCalyxEntry` | Entry removed; other servers survive |
| `test_disableIPC_removesMcpKeyIfEmpty` | `mcp` key dropped when calyx-ipc was the only child |
| `test_disableIPC_noFile_noOp` | Missing file → no throw |
| `test_enableIPC_symlinkRejected` | Symlink path → throw |
| `test_isIPCEnabled_trueWhenPresent` | Detection positive |
| `test_isIPCEnabled_falseWhenAbsent` | Detection negative (other entry present) |
| `test_isIPCEnabled_falseWhenNoFile` | Detection negative (no file) |

**Updated tests:**
- `IPCConfigManagerTests` extended with `onlyCrush` and `allSixFail` cases.

## Acceptance criteria

- [ ] **Enable AI Agent IPC** adds `mcp.calyx-ipc` to `crush.json` when `~/.config/crush` exists.
- [ ] **Disable AI Agent IPC** removes the entry (and the `mcp` key if empty).
- [ ] `IPCConfigManager.isIPCEnabled().crush` reflects the current state.
- [ ] Existing `crush.json` content (other MCP servers, top-level keys) is preserved.
- [ ] Symlink paths are rejected with a descriptive error.
- [ ] All Crush-specific tests pass.

## Notes

- Crush supports shell-style value expansion in `crush.json` (`$VAR`,
  `${VAR:-default}`, `$(command)`) — but the entries written by Calyx are
  literal strings (the token is a hex string with no special shell characters),
  so expansion is a no-op.
- Crush also looks for `.crush.json` and `crush.json` in the project root
  before the global config.  Calyx only writes the **global** config
  (`~/.config/crush/crush.json`), consistent with the other config managers
  that target the user-level config.