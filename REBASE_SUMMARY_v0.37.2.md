# Rebase: Sync Fork with Upstream v0.37.2

## Summary

Rebased all applied branches from the v0.35.1 base (`1574072`) onto upstream **v0.37.2** (`4b71822`) — **83 upstream commits** across v0.36.0 → v0.37.2. This was the **convergence rebase**: upstream added its own pi integration and Grok support, refactored the IPC activation flow, and rewrote agent-row tracking, colliding directly with the fork's pi/Crush IPC work. Five conflicts resolved by merging both sides' agent axes, and the full test suite passes.

## Affected Branches

- **main** — advanced to `upstream/main` (`4b71822`, v0.37.2); not yet pushed
- **add-pi-cursh-ipc** — rebased, 4 conflicted commits resolved (`tyk`, `syw`, `wnx`, `uku`)
- **fix/cmd-ctrl-f-fullscreen-menu-routing** — rebased (same `tyk` change-ID, stacked under pi; resolved together)
- **fix/pi-crush-ipc-dialog** — rebased, `zrv` resolved and collapsed to **(no changes)**
- **fix/compose-input-text-color** — rebased, no conflicts
- **fix/launch-env** — rebased, no conflicts

## Notable Upstream Changes (v0.35.1 → v0.37.2)

- **v0.36.0**: upstream's own **pi integration** (Agents sidebar + approval inbox via `~/.pi/agent/extensions/calyx.ts`), **Grok** support (config manager + hooks + sidebar), Git Changes sidebar as one section per repository (+ submodules), approval queue preview menu, single root glass sheet (reverted, then re-landed), agent rows named after their pane
- **v0.37.x**: subagent child rows in the sidebar, row retirement via ghostty command-finished / pane-exit signals, Codex session-end settling, IPC enable-gate fixes ("let pi-only machines enable IPC", "stop showing Enable while IPC is running"), parent-row "in 0 sec." label fix, per-row tick anchoring

## Conflict Resolutions

### IPC layer: `IPCConfigManager.swift` / `IPCConfigResult` / `IPCActivation*` (merged by hand)
- Upstream refactored IPC enable/disable into `IPCActivationCoordinator` + `IPCActivationPresenter` (generic renderer driven by `axes`), and added `grok` to `IPCConfigResult`; the fork had added `pi`/`crush` axes. Resolution: **keep both** — `IPCConfigResult` now has **seven axes** (claudeCode, codex, openCode, hermes, grok, pi, crush) with `GrokConfigManager`, `PiConfigManager`, and `CrushConfigManager` all driven from `IPCConfigManager.enable/disableIPC()`.
- `AgentHooksResult` (upstream's shape) keeps **five axes** (claudeCode, codex, openCode, grok, pi) — Crush is IPC-config-only, no hooks axis.
- The old manual enable/disable dialog helpers in `CalyxWindowController` (`configStatusMessage`, `agentHooksStatusMessage`, `hooksIssueMessages`, `AgentHooksMode`, `configStatusLabel`) became **dead code** — deleted. The fork's pi/Crush status lines now come out of upstream's `axes`-driven presenter automatically (`zrv`'s "show pi and crush in the dialog" goal is satisfied with no code of its own).

### CalyxWindowController — `tyk` (fullscreen routing) + `uku` (AgentHooksResult cleanup)
- Upstream now **deliberately excludes pi** from `isAIAgentTitle` (a two-character substring matches "npm run api" etc.); pi reaches the sidebar through its extension's own events. Adopted upstream's rationale and added Grok. Kept the fork's **Crush** in the title check and the "No AI Agent" alert message.

### README — `syw`
- Upstream's v0.36.0 rewrite already mentions pi (extension mechanism) and Grok. Merged every agent list to **"Claude Code, Codex, OpenCode, Hermes, Grok, pi, Crush"**, and the config-paths paragraph now covers `~/.grok/config.toml`, `~/.config/crush/crush.json`, and the pi skill path used by the fork's `PiConfigManager`.

### CalyxMCPServer — `wnx`
- Upstream v0.37.2 **already contains the bind helpers** the fork's commit "restored" (`bindListener`, `bindKernelAssignedListener`, `askKernelForFreeLoopbackPort`, `startListenerAndWaitForReady`, `finishStart`) — they were upstreamed. Kept upstream's versions, re-applied the fork's only real delta: `writeStateFile()` / `removeStateFile()` (`~/.config/calyx/ipc.json`) hooked into `finishStart`/`stop()`.

## Post-Rebase Fixes

- `xcodegen generate`
- Rewrote `IPCConfigManagerTests.swift` + `IPCActivationResultFixtures.swift` to the 7-axis `IPCConfigResult` / 5-axis `AgentHooksResult` constructors (both sides' axis tests preserved)
- Cosmetic blank line in `CalyxMCPServer.swift`

## Build Status

✅ **Build succeeds** (arm64 macOS, Debug) — **test suite: 3845 tests, 0 failures** (13 skipped).

## Notes

- **Pi is now dual-mechanism**: upstream's `PiExtensionManager` (extension file, hooks axis) coexists with the fork's `PiConfigManager` (skill at `~/.pi/agent/skills/calyx-ipc/`, IPC axis). Worth a product review — likely only one should ship.
- `zrv` (IPC dialog) collapsed to a no-op commit — its behavior is fully covered by upstream's axes-driven presenter.
- `(no changes)` leftovers on the pi branch remain from the v0.28 rebase — squash on cleanup.
- Uncommitted workspace files `feature_request_memo_calyx_MCP.md` / `herdr_tumux_calyx_comparison.md` untouched (pre-existing).
- Nothing pushed yet; `origin/main` and branches still on old history.

## Checklist

- [ ] Review the 7-axis `IPCConfigResult` merge (grok + pi + crush)
- [ ] Decide fork's `PiConfigManager` (skill) vs upstream's `PiExtensionManager` (extension) — one mechanism should win
- [ ] Review `isAIAgentTitle`: upstream excludes pi deliberately; Crush kept
- [ ] Run the full test suite (done: 3845 pass)
- [ ] Squash the `(no changes)` commits on the pi branch
- [ ] Push branches to Kwik-Dev fork
- [ ] Create PR
