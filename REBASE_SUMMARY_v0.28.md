# Rebase: Sync Fork with Upstream v0.28.0

## Summary

Rebased all local branches from v0.26.2 base onto upstream v0.28.0 (`022c624`). Resolved merge conflicts, restored missing upstream functions lost during conflict resolution, and fixed API mismatches.

## Affected Branches

- **main** — force-pushed to sync with upstream v0.28.0
- **add-pi-cursh-ipc** — rebased, conflicts resolved, missing functions restored
- **fix/cmd-ctrl-f-fullscreen-menu-routing** — rebased, conflicts resolved
- **fix/compose-input-text-color** — rebased, no conflicts

## Key Changes

### CalyxMCPServer.swift
- Restored missing upstream helper functions lost during rebase conflict resolution:
  - `bindListener(onPort:)` — NWListener bind with resolved port readback
  - `bindKernelAssignedListener()` — BSD socket fallback for ephemeral port assignment
  - `askKernelForFreeLoopbackPort()` — kernel-assigned ephemeral port probe
  - `startListenerAndWaitForReady(_:)` — blocking listener start with semaphore
  - `finishStart(listener:boundPort:priorTeardown:)` — common tail for all bind paths
- Integrated custom `writeStateFile()` call in `finishStart`
- Fixed malformed guard/catch block from poor conflict resolution

### CalyxWindowController.swift
- Removed stray closing brace that prematurely closed the class
- Restored `startScreenPollTask()` and `pollScreenClassificationIfAgentsSidebarVisible()` (upstream screen state polling fallback)
- Fixed `agentHooksStatusMessage` to reference only 3 fields in `AgentHooksResult` (claudeCode, codex, openCode) — Hermes/pi/Crush use IPC config, not shell hooks
- Added `handleToggleFullscreenNotification` notification observer

### PiConfigManager.swift / CrushConfigManager.swift
- Fixed `ConfigFileUtils.atomicWrite(data:to:)` API mismatch (upstream removed `lockPath` parameter)

### project.yml / .xcodeproj
- Regenerated Xcode project via xcodegen (upstream switched from .xcodeproj to project.yml)

## Build Status

✅ **Build succeeds** (arm64 macOS) after all fixes.

## Notes

- Remote URL swap workaround was used: temporarily set origin to upstream for `but pull`, then restored to fork
- `AgentHooksResult` has 3 fields (claudeCode, codex, openCode) — upstream v0.28.0 removed Hermes; pi/Crush use IPC config layer, not shell hooks
- Some empty rebase-fix commits were squashed; force-push needed to clean remote history
- **One hunk overlap**: screen poll task in CalyxWindowController.swift overlaps with fix/cmd-ctrl-f-fullscreen-menu-routing's changes — needs manual resolution during review

## Checklist

- [ ] Review `add-pi-cursh-ipc` branch
- [ ] Force-push to clean empty commits
- [ ] Resolve CalyxWindowController.swift hunk overlap with fix/cmd-ctrl-f-fullscreen-menu-routing
- [ ] Run tests
- [ ] Create PR
