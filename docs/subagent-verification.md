# Subagent Row Verification

End-to-end verification procedure for the Agents sidebar's subagent
(parent/child) rows. Items 1 and 2 are automated. Items 3 onward each
record what `SubagentSidebarPipelineTests` already pins automatically,
driven by payloads captured from real CLI runs, and what genuinely still
needs a human looking at the screen.

A child row exists only while a CLI reports the child. Calyx keeps no
history of one, so every item below checks both that a child appears and
that it goes away for a reason a CLI actually reported.

## 1. Build

```
cd ~/projects/Calyx-worktrees/feat-subagent-rows
xcodegen generate
xcodebuild -project Calyx.xcodeproj -scheme Calyx -configuration Debug -arch arm64 build
```

Expected: `** BUILD SUCCEEDED **`.

## 2. Unit tests

```
xcodebuild -project Calyx.xcodeproj -scheme Calyx -destination 'platform=macOS' test -only-testing:CalyxTests
```

Expected: the full suite green. The subagent feature contributes:

- `AgentEventTests`, `AgentEventGrokDecodeTests` (wire model and the
  per-CLI normalization)
- `AgentStateResolverSubagentTests` (a child never owns a row)
- `SubagentRegistryTests` (the child store's creation, update, and every
  removal trigger)
- `AgentSidebarRowsTests` (the parent/child flattening)
- `CalyxMCPServerAgentEventTests`, `CalyxMCPServerGrokRoutingTests` (a
  child's session id never reaches `recordAgentSession`, and the route's
  body cap)
- `ClaudeHooksConfigManagerTests`, `CodexHooksConfigManagerTests`,
  `GrokHooksConfigManagerTests`, `OpenCodePluginManagerTests` (the hook
  subscriptions and the OpenCode translation)
- `AgentHookPipelineIntegrationTests` (real `/bin/sh` hook script, real
  server, real registry)

## Per-CLI support, and why the unsupported ones are unsupported

Verified against each CLI's own primary source, not against sampled
payloads.

| kind | child identity | what a child row shows |
|---|---|---|
| claude-code | `agent_id` plus `agent_type`, carried on every hook event fired inside a subagent | lifecycle and the current tool |
| codex | `agent_id` plus `agent_type`, on `SubagentStart` / `SubagentStop` only; its other subagent hooks reuse the parent session's id | lifecycle only |
| grok | no `agent_id` exists; identity is `subagentId` where present, else the event's own `sessionId`, with `subagentType` naming the type | lifecycle and the current tool |
| opencode | the child session's own id, from `session.created`'s `info.parentID` | lifecycle only |
| pi | no subagent lifecycle events exist; pi's subagents are a `registerTool` extension | no child rows |
| hermes | no hook injection surface exists | no child rows |
| herdr | `herdr api schema --json` (protocol 19, schema_version 1) has no `subagent`, `parent`, or `child` vocabulary, and `AgentHookScript` exits 0 whenever `HERDR_PANE_ID` is set | no child rows |

A pane whose CLI reports no children is not a degraded case. Its row is
identical to a Calyx build without this feature: no chevron, no badge, no
notice.

Re-run `herdr api schema --json` whenever this feature changes and confirm
`SubscriptionEventKind` and `AgentInfo` still carry no subagent concept.

## Wire contract, verified against the real CLIs

Captured by running each CLI for real with a hook that appends its stdin
to a file, in an isolated config that touches nothing Calyx installs.
This is the check that a fixture cannot make: it is what the CLI actually
sends, not what Calyx assumes it sends.

### Claude Code

One `Task` launching an `Explore` subagent that runs one `Bash` command:

| event | `agent_id` | `agent_type` | `tool_name` | `session_id` |
|---|---|---|---|---|
| `PreToolUse` (parent launches `Agent`) | absent | absent | `Agent` | parent |
| `SubagentStart` | present | `Explore` | absent | parent |
| `PreToolUse` (inside the child) | present | `Explore` | `Bash` | parent |
| `SubagentStop` | present | `Explore` | absent | parent |

Confirms: the subscribed events fire and matcher `"*"` matches them; a
child's tool events really do carry `agent_id` and `tool_name`, so a
claude-code child row shows a live tool; and the parent's own event
carries no `agent_id`, so `isSubagentEvent` separates the two on real
payloads.

It also answers a question Claude Code's docs leave open: a subagent's
hooks carry the PARENT's `session_id`, not a child's.

### OpenCode

One `opencode run` delegating to a subagent, with a probe plugin logging
every bus event. Parent session `ses_fde19ee2...`, child `ses_fde19d51...`:

| event | count | what it carried |
|---|---|---|
| `session.created` | 2 | the parent with no `info.parentID`, then the child with `info.parentID` set to the parent |
| `session.idle` | 2 | the CHILD's first, then the parent's |
| `session.deleted` | 0 | never fired |
| `tool.execute.before` / `.after` | 0 | never fired, confirming they are plugin hooks rather than bus events |

Confirms the child-identification premise: `session.created`'s
`info.parentID` is what marks a child, and it really is populated.

It also corrected two things that documentation alone would not have
caught. `session.deleted` does not fire in a normal run, so retiring a
child on that signal alone leaves every finished child listed until the
parent's whole turn ends, and the sets keyed on it are never cleaned. A
child's own `session.idle` is what actually reports that child is over,
since a subagent takes no further turn.

### Codex

NOT captured, after four attempts. Two failed to launch (a stdin wait,
then a git-repo check). A third ran but loaded no probe hooks: Codex
merges hooks from `config.toml` only, and neither `--profile` nor `-c`
layers them, which a control run confirmed (an injected `PreToolUse`
hook never fired while the ones already in `config.toml` fired twice).

The fourth put the probe directly in `config.toml`, the one place Codex
reads hooks from, with the file restored byte for byte afterwards. Even
then no `SubagentStart` or `SubagentStop` fired, while `PreToolUse` and
`PostToolUse` fired repeatedly from that same file. The reasonable
reading is that `codex exec` did not spawn a subagent for that prompt at
all, so the events had nothing to report. Whether it can spawn one in
this mode is unresolved.

Codex therefore rests on its documentation alone: `agent_id` and
`agent_type` on `SubagentStart` and `SubagentStop`, and the parent's
session id elsewhere. Both other CLIs that were captured contradicted
their own documentation in some way, so treat this as the least verified
path here. Capture a real Codex subagent run, most likely from the
interactive TUI rather than `exec`, before relying on it.

### Grok

One `spawn_subagent` running one shell command. Parent session
`01a02092-04e6...`, child session `01a02092-1cc5...`:

| event | `sessionId` | `subagentId` | `subagentType` | `toolName` |
|---|---|---|---|---|
| `pre_tool_use` (parent) | parent | absent | absent | `spawn_subagent` |
| `subagent_start` | parent | child | `general-purpose` | absent |
| `pre_tool_use` (child) | child | absent | `general-purpose` | `run_terminal_command` |
| `pre_tool_use` (parent) | parent | absent | absent | `get_command_or_subagent_output` |
| `subagent_stop` | child | child | `general-purpose` | absent |
| `session_end` (child) | child | absent | `general-purpose` | absent |
| `session_end` (parent) | parent | absent | absent | absent |

Two facts here are not in Grok's own hooks documentation and were found
only by running it:

1. A `subagentId` field exists. The docs state only that subagent
   identity is `subagentType`, which names the type rather than the
   instance.
2. `subagent_start` alone carries the PARENT's `sessionId` and names the
   child only through `subagentId`. Every other child event carries the
   child's own `sessionId` and no `subagentId`, and where both appear
   they agree.

So a child's identity is `subagentId` where present, else `sessionId`.
Deriving it from `sessionId` alone keys `subagent_start` to the parent
and leaves a phantom child row that no later event can match.

The child's own `session_end` is also confirmed here, which is why a
subagent-scoped `SessionEnd` removes that child.

## 3. Claude Code: parallel children

Run three `Task` calls in parallel in a Claude Code pane.

Expected: the parent row grows a chevron and a count badge reading 3.
Expanding shows three child rows, indented, each with its agent type and
a tool name that changes as the child works.

Result:

Row-list behavior automated by `SubagentSidebarPipelineTests`
(`test_claudeCode_threeConcurrentChildren_orderAndIndependentRetirement`),
driven through the real hook script and real server. Chevron and badge
appearance on screen still needs a human.

## 4. Claude Code: children retire themselves

Let the three children finish.

Expected: each child row disappears as that child stops, and the chevron
and badge disappear with the last one. The parent row returns to exactly
its pre-run appearance.

Result:

Automated by the same test: each child retires independently down to
`childCount: 0`. The disclosure control disappearing on screen still
needs a human.

## 5. Claude Code: an approval inside a child

Trigger a permission prompt inside one child.

Expected: the parent row turns red, and so does that one child row. The
other children keep their own state. This is the settled design: a child's
approval blocks the parent, because the parent is what the user has to act
on.

Result:

Automated by `test_grok_childScopedPermissionRequest_blocksParentAndOnlyThatChild`.
The event name drives the same resolver path for every kind, so this
covers the rule. The red dot on screen still needs a human.

## 6. Codex

Repeat items 3 through 5 in a Codex pane.

Expected: children appear and retire on lifecycle alone. Child rows carry
no tool name, because Codex documents `agent_id` only on `SubagentStart`
and `SubagentStop`. This is the known, accepted limit of what Codex
reports, not a Calyx defect.

Result:

NOT automated. Codex carries `agent_id` only on `SubagentStart` and
`SubagentStop`, so pinning its child rows needs a real Codex capture
that has not been taken. Manual.

## 7. Grok, including the behavior change

Repeat items 3 through 5 in a Grok pane.

Expected: children appear, and the parent row now stays yellow (working)
for as long as a child runs. Before this change Grok alone left the parent
row idle during a child's run, because its decoder deliberately left child
event names unmapped. Claude Code always behaved the new way.

Also confirm a child's own session teardown removes its row rather than
leaving a stale finished child behind: Grok's `SessionEnd` carries
`subagentType` for a child session.

Result:

Automated by `test_grok_subagentSequence_oneChildAndParentStaysWorking`,
which replays the captured 7-event sequence verbatim: one child (not
two) from `subagent_start` plus the child's first tool event, the parent
held `.working` while the child runs, the child's own `session_end`
neither resurrecting it nor settling the parent, and only the parent's
`session_end` settling the row. Colors on screen still need a human.

## 8. OpenCode, including the behavior change

Repeat items 3 through 5 in an OpenCode pane.

Expected: children appear and retire on lifecycle alone, with no tool
name. The parent row now reacts to a child's approval flow: blocked on a
child's `permission.asked`, and working again on its `permission.replied`.
Before this change the plugin suppressed child events entirely, so the
parent row did not move at all.

OpenCode reports no per-tool activity to this integration. Its
`tool.execute.before` / `tool.execute.after` are dedicated plugin hooks
with an `(input, output)` signature, invoked through `plugin.trigger`,
rather than members of the event bus's own `Event` type, so the plugin's
generic `event` handler never sees them. A child's own session lifecycle
(`session.created` / `session.deleted`) is what its row is built from.

Result:

Partly verified. A real subagent run was captured (see the wire contract
section above) and corrected how a child retires. The plugin's own
translation is pinned by `OpenCodePluginManagerTests`, but the ingestion
path is the plugin rather than the `/bin/sh` hook script the pipeline
tests drive, so the end-to-end row behavior in the sidebar is still
manual.

## 9. pi and herdr are untouched

Open a pi pane and a herdr-hosted pane and let each run a task.

Expected: both look exactly as they did before this feature. No chevron,
no badge, no explanatory text, no dimming.

Result:

The row-list half is automated by
`test_noChildrenAtAll_rowListIdenticalToHardcodedEmptyChildStore`, which
compares the real (empty) child store against a hardcoded empty one and
requires identical output. Confirming the panes look unchanged on screen
still needs a human.

## 10. A killed CLI takes its children with it

Force-quit an agent CLI mid-run with children showing, then close the pane.

Expected: the children disappear with the pane. No child outlives the row
it belonged to.

Result:

The row-list half is automated by
`test_forceQuit_paneExitSweepsChildren_lateChildEventCreatesNothing`,
which settles through `handlePaneCommandFinished` and proves a late child
event creates nothing under the settled row. The real force-quit path
(ghostty's own pane-exit signal, then closing the pane) still needs a
human.

## Operational note

Adding hook subscriptions does not reach a CLI session that is already
running. A CLI reads its hook configuration once, at session start, and
holds that snapshot for the session's lifetime. Subagent rows therefore
appear only in sessions started after Calyx installed the new hooks.
