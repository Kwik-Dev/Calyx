# Rebase: Sync Fork with Upstream v0.35.1

## Summary

Rebased all applied branches from the v0.34.1 base (`3d7b6f8`) onto upstream **v0.35.1** (`1574072`, one commit past the tag: `Create FUNDING.yml`) — **26 upstream commits**. Two conflicts resolved, no code duplication this time (the dedup fixes from the v0.34.1 rebase carried forward cleanly), and the build succeeded without post-rebase fixes beyond `xcodegen generate`.

## Affected Branches

- **main** — advanced to `upstream/main` (`1574072`, v0.35.1+1); not yet pushed
- **add-pi-cursh-ipc** — rebased, conflicted (`syw`, README), resolved
- **fix/launch-env** — rebased, conflicted (`urx`, AppDelegate.swift), resolved
- **fix/cmd-ctrl-f-fullscreen-menu-routing** — rebased, no conflicts
- **fix/compose-input-text-color** — rebased, no conflicts
- **fix/pi-crush-ipc-dialog** — rebased, no conflicts

## Conflict Resolutions

### README.md — `syw` (add-pi-cursh-ipc)
- Upstream **fully rewrote the README** in v0.35.0: new "Why Calyx" sections and the Features list reorganized into subsections (Agent supervision / Code review and agent coordination / Sessions and remote work / Terminal workspace / Browser automation), plus a new herdr Integration bullet.
- The fork's `syw` commit had added pi/Crush to two agent-list bullets in the **old flat** structure. Resolution: kept upstream's rewritten layout and re-applied the fork's additions onto it —
  - intro: "submit the complete review directly to a Claude Code, Codex, OpenCode, **Hermes, pi, or Crush** pane"
  - AI Agent IPC bullet: "built-in MCP messaging (**Claude Code, Codex, OpenCode, Hermes, pi, and Crush**)"
- The other pi/Crush mentions in the README (Diff Review Comments bullet, "Start agents" steps) belong to fork commits that applied cleanly — already present.

### Calyx/App/AppDelegate.swift — `urx` (fix/launch-env)
- Same shape as the v0.34.1 rebase: upstream added a **Herdr Integration** section (`HerdrIntegrationCoordinator`, `herdrCreateSurface`/`herdrDestroySurface` seams); the fork's `terminalLaunchPATH()` is independent. Kept both.

## Post-Rebase Fixes

- `xcodegen generate` only — no redeclaration or API-mismatch fixes were needed this cycle.

## Notable Upstream Changes (v0.34.1 → v0.35.1)

- **herdr integration** (the bulk of the release):
  - optional herdr detection, session list, and attach; socket connection unified
  - open herdr workspaces as **native split-pane tabs**; tabs named after workspace labels; workspace dir chosen by herdr / created in home dir
  - mirror herdr's agent states into the **Agents Sidebar**; monitoring-off and IPC-disabled notices quieted
  - close a tab when its herdr workspace is killed / attach process exits; close herdr tabs Calyx didn't open when herdr closes them wholesale; survive broken pipes; stop the attach client before the workspace
  - Session Browser row alignment fixes
- **agent-monitor**: connect Codex and preserve hook config; track OpenCode, Hermes, and herdr exits
- **README rewrite** + `chore: update README.md`
- **FUNDING.yml**

## Build Status

✅ **Build succeeds** (arm64 macOS, Debug).

## Notes

- `but skill install` fails with `No such file or directory` because the skill is installed as **symlinks into `~/GitHub/dotfiles`** (writes through the symlinked `references/*.md` fail). The skill itself works fine — `but` still reports the AGENT ACTION REQUIRED notice on every command. Needs a fix upstream (installer should follow symlinks) or replacing the symlinks with real files.
- Nothing pushed yet. `origin/main` and the branches are still on the v0.28-era history from before the two rebases.
- pi branch still carries leftover `(no changes)` commits from the v0.28 rebase — squash on cleanup.
- `REBASE_SUMMARY_v0.28.md` / `REBASE_SUMMARY_v0.34.1.md` superseded by this document (kept for history).

## Checklist

- [ ] Review `add-pi-cursh-ipc` (README pi/Crush re-application on upstream's rewritten structure)
- [ ] Review `fix/launch-env` (terminalLaunchPATH alongside upstream's Herdr section)
- [ ] Run test suite (IPC config, GlobalEventTap, launch-env gate tests)
- [ ] Squash the `(no changes)` commits on the pi branch
- [ ] Push branches to Kwik-Dev fork
- [ ] Create PR
