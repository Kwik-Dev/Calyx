# Rebase: Sync Fork with Upstream v0.34.1

## Summary

Rebased all applied branches from the v0.28.0 base (`022c624`) onto upstream **v0.34.1** (`3d7b6f8`) — **183 upstream commits** across v0.29.0 → v0.34.1. Resolved 3 conflicts, removed duplicate code the fork had independently re-added (upstream had since adopted it), and fixed redeclaration build errors from the conflict merges.

## Affected Branches

- **main** — advanced to `upstream/main` (`3d7b6f8`, v0.34.1); not yet pushed
- **add-pi-cursh-ipc** — rebased, conflicted (`uku`), resolved + dedup amended in
- **fix/cmd-ctrl-f-fullscreen-menu-routing** — rebased, conflicted (`tyk`), resolved + dedup amended in
- **fix/compose-input-text-color** — rebased, no conflicts
- **fix/pi-crush-ipc-dialog** — rebased, no conflicts
- **fix/launch-env** — rebased, conflicted (`urx`), resolved

## Conflict Resolutions

### CalyxWindowController.swift — `tyk` (fix/cmd-ctrl-f-fullscreen-menu-routing)
- Upstream's missing-observer keybind-wiring batch (close_tab/close_window/toggle_fullscreen/initial_size/renderer_health, the six-action second batch, prompt_title #42, split_zoom) already registers `.ghosttyToggleFullscreen` — kept upstream's observer registration, dropped the fork's duplicate line.
- Fork's older `handleToggleFullscreenNotification` handler (raw `window.toggleFullScreen(nil)`) was removed in favor of upstream's complete version, which routes through `processToggleFullscreen(mode:)` / `shouldUseNativeFullscreen`. The fork's `GlobalEventTap` main-menu-routing change and `GlobalEventTapTests` remain intact.

### CalyxWindowController.swift — `uku` (add-pi-cursh-ipc)
- The fork's "restore screen poll task" commit replayed over itself: upstream had already adopted `startScreenPollTask()` / `pollScreenClassificationIfAgentsSidebarVisible()` (the "Herdr Layer 2" section), so the rebase produced an identical duplicate with an empty common ancestor. Kept one copy.
- The commit's real change is the `AgentHooksResult` cleanup: `agentHooksStatusMessage` now references only `claudeCode`/`codex`/`openCode` (upstream removed hermes/pi/crush from `AgentHooksResult` in v0.29.0). The fork's IPC layer is unaffected — `configStatusMessage(_: IPCConfigResult)` still lists Hermes/pi/Crush, since `IPCConfigResult` keeps those fields.

### AppDelegate.swift — `urx` (fix/launch-env)
- Upstream added a Bell-handling section (`processRingBell`, `cachedBellFeatures`, `playBellAudio`, …); the fork added `terminalLaunchPATH()` for augmented login PATH. Independent additions — kept both.

## Post-Rebase Fixes

- `xcodegen generate` — regenerated `Calyx.xcodeproj` so fork-only files (e.g. `TestEnvironment.swift`, `ProcessCancellationBridge.swift`) stay in the target
- Fixed 3 redeclaration errors in `CalyxWindowController.swift` caused by keeping both sides of the conflicts:
  - duplicate `startScreenPollTask()` / `pollScreenClassificationIfAgentsSidebarVisible()` (screen-poll section existed twice — upstream already provides it)
  - duplicate `handleToggleFullscreenNotification` (upstream's version kept)
- Amended each dedup into its owning commit (`uku`, `tyk`) so no branch carries the other's fix

## Notable Upstream Changes (v0.28.0 → v0.34.1)

- **v0.29.0** (80 commits): session daemon + attach CLI (P2), ghostty-vt shim / Rust vt crates (P1), in-app recovery bar, session browser fixes, tab-title abbreviation HOME fix, a11y fixes
- **v0.30.0**: Cockpit API with human approval gating — `pane_list`/`pane_split`/`tab_create`/`pane_run`/`pane_send_keys`/`palette_execute` MCP tools, approval banner UI + settings toggle, dedicated Agents settings pane
- **v0.30.1**: command log secret redaction (async, off MainActor), truthful pending state for records awaiting redaction
- **v0.31.x**: approval inbox for CLI agents — `calyx-approval-hook` script, synchronous PreToolUse gating, `POST /approval-request` long-poll endpoint, per-tool Always Allow memory, banner prev/next navigation, empty restored-session-snapshot fix
- **v0.32.x**: auto-refresh Git Changes sidebar, commit history scoped to linked worktree, Hermes managed-block removal fix
- **v0.33.0**: split zoom (`toggle_split_zoom`), `prompt_title` tab rename editor (#42), Cmd+W routed through NSWindow (#45), key-window gating for Edit menu actions / Focus Split, quick-terminal teardown, Secure Input checkmark via `validateMenuItem`
- **v0.34.x**: inactive-window glass washout fix (#44) + chrome boundary seams, stray zsh prompt marker fix, `zig@0.15` keg pin for `build-session.sh`

## Build Status

✅ **Build succeeds** (arm64 macOS, Debug) after all fixes and dedup amends.

## Notes

- **Fork vs upstream ownership shifted**: several fork-originated pieces are now upstream (screen-poll task, `handleToggleFullscreenNotification`, agent-hooks status shape). The fork keeps its distinct value: pi/Crush IPC config managers, `IPCConfigResult` hermes/pi/crush axis, fullscreen menu routing via `GlobalEventTap`, compose-input text color, IPC dialog listing pi/Crush, and `terminalLaunchPATH()`.
- pi branch still carries leftover `(no changes)` commits from the v0.28 rebase — harmless; squash on cleanup.
- Nothing pushed yet; `origin/main` and branches still on old history. Push per-branch with `but push <branch>` when ready.
- `REBASE_SUMMARY_v0.28.md` is superseded by this document (kept for history).

## Checklist

- [ ] Review `add-pi-cursh-ipc` branch (AgentHooksResult cleanup + dedup)
- [ ] Review `fix/cmd-ctrl-f-fullscreen-menu-routing` (GlobalEventTap routing still behaves with upstream's handler)
- [ ] Run test suite (GlobalEventTapTests, AppDelegateLaunchEnvironmentGateTests, IPC config tests)
- [ ] Squash the `(no changes)` commits on the pi branch
- [ ] Push branches to Kwik-Dev fork
- [ ] Create PR
