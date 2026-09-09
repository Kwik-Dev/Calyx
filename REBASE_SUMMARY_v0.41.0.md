# Rebase: Sync Fork with Upstream v0.41.0

## Summary

Rebased all applied branches from the v0.37.2 base (`4b71822`) onto upstream **v0.41.0** (`8415801`) — **22 upstream commits** across v0.37.3 → v0.41.0. This was a comparatively light rebase: upstream's changes were mostly additive (approval panel, context menus, git ref picker, session/login-shell fixes) and did not collide with the fork's pi/Crush IPC work except in one file. Two conflicted commits resolved in `CalyxMCPServer.swift`, plus a duplicate-block cleanup. Full test suite passes.

## Affected Branches

- **main** — advanced to `upstream/main` (`8415801`, v0.41.0); not yet pushed
- **add-pi-cursh-ipc** — rebased, 2 conflicted commits resolved (`syw`, `wnx`), plus a post-rebase duplicate-removal commit (`vmk`)
- **fix/cmd-ctrl-f-fullscreen-menu-routing** — rebased, no conflicts
- **fix/pi-crush-ipc-dialog** — rebased, no conflicts
- **fix/compose-input-text-color** — rebased, no conflicts
- **fix/launch-env** — rebased, no conflicts

## Notable Upstream Changes (v0.37.2 → v0.41.0)

- **v0.37.3**: launchd-owned `calyx-session` daemon, glass-opacity cells, subagent tool summary on child rows, agent-endpoint ownership fix (only remove `agent-endpoint.json` this server published), tail-truncate native agent row subtitles
- **v0.38.0**: herdr connection driven from session presence, default session shell started as a login shell
- **v0.38.1**: login-shell fixes (blank pane before attach, keep login banner, quiet shell start)
- **v0.38.2**: answer Claude Code's `AskUserQuestion` from the approval banner, mirror the CLI permission dialog, single-column choice strips
- **v0.39.0**: VSCode-style Auto refs in the Changes commit log with a per-repo ref picker, right-click context menu on tab bar tabs and sidebar tab rows
- **v0.40.0**: right-click context menu on tab group headers
- **v0.41.0**: Cockpit approval dialog moved to a floating notification-style panel at the top-right (glass sheet, hover-to-expand body, dismiss disc, title truncation)

## Conflict Resolutions

### `CalyxMCPServer.swift` — `syw` (feat: add Crush & pi support)

The fork's `syw` commit had deleted the port-bind helpers (`bindListener`, `bindKernelAssignedListener`, `askKernelForFreeLoopbackPort`, `startListenerAndWaitForReady`, `finishStart`) as an artifact of an earlier rebase; upstream v0.41.0 kept them (with doc-comment rewording that dropped the "Round 5 / task #47" references). Resolution: **keep upstream's versions** — the fork's later "restore missing helper functions" commits re-add them anyway.

### `CalyxMCPServer.swift` — `wnx` (fix: restore missing helper functions)

Nested/recursive conflict: the fork's history has a "delete → restore" pattern for the bind helpers, so `wnx` re-introduced the older "Round 5" copy on top of the upstream copy already kept in `syw`. Resolution: keep the bind helpers once, drop the duplicate.

### `CalyxMCPServer.swift` — `stop()`

Upstream added `let stoppedPort = port` / `let stoppedToken = token` (captured before reset, used by `AgentEndpointFile.remove`); the fork added `removeStateFile()` (removes `~/.config/calyx/ipc.json`). Resolution: **keep both** — the two additions are independent and both are needed.

## Post-Rebase Fixes

- `xcodegen generate`
- Removed the duplicate bind-helper block left by the `syw` + `wnx` resolutions (committed as `vmk`)
- Committed the pre-existing uncommitted conflict resolutions and docs (`our`, `nns`, `kuu`) that were sitting in the working tree from the v0.37.2 rebase before pulling

## Build Status

✅ **Build succeeds** (arm64 macOS, Debug) — **test suite: 4308 tests, 0 failures** (13 skipped).

## Notes

- The fork's pi/Crush IPC work (7-axis `IPCConfigResult`, `PiConfigManager`, `CrushConfigManager`, `calyx ipc` CLI) carried over cleanly — no IPC-layer conflicts this time, unlike the v0.37.2 convergence rebase.
- The `(no changes)` leftovers on the pi branch remain from earlier rebases — squash on cleanup.
- Nothing pushed yet; `origin/main` and branches still on old history.

## Checklist

- [ ] Review the `CalyxMCPServer.swift` bind-helper resolution (upstream version kept, fork's `removeStateFile()` preserved)
- [ ] Decide fork's `PiConfigManager` (skill) vs upstream's `PiExtensionManager` (extension) — one mechanism should win (carried over from v0.37.2)
- [ ] Squash the `(no changes)` commits on the pi branch
- [ ] Push branches to Kwik-Dev fork
- [ ] Create PR
