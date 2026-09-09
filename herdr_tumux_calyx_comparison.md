https://flaviocopes.com/herdr/

Yes — based on the Herdr comparison criteria and Calyx’s documented features, I’d add Calyx as a separate column like this:

| Capability | Plain terminal tabs | tmux or Zellij | Graphical agent manager | Herdr | Calyx |
|---|---|---|---|---|---|
| Real terminal processes | Yes | Yes | Depends on app | Yes | Yes |
| Persistent detach and reattach | No | Yes | Usually different | Yes | Yes (session persistence) |
| Panes and tabs | Terminal-dependent | Yes | Yes | Yes | Yes (tab groups and split panes) |
| Agent lifecycle state | No | No | Yes | Yes | Limited / not a primary feature |
| Works through normal SSH | Yes | Yes | Usually limited | Yes | Depends on Ghostty/terminal workflow; not a core feature |
| Mouse-native workspace UI | Terminal-dependent | Limited | Yes | Yes | Yes (native macOS UI) |
| Local CLI and API | No shared layer | General terminal control | Product-dependent | Yes, agent-aware | MCP server + CLI tooling |
| Agent can control another agent | No | Possible, but manual | Product-dependent | Built in | Yes, via built-in MCP peer messaging between agents in different panes |

## Summary

The Herdr article positions itself between tmux and agent platforms. Calyx sits in a somewhat different spot:

- Herdr = terminal-native multiplexer with explicit agent awareness and agent state tracking.
- Calyx = native macOS terminal built on Ghostty with session persistence, browser integration, and a built-in MCP server that enables agent-to-agent communication across panes.

If I were editing Flavio’s table, I’d add a footnote like this:

> Calyx: A macOS-native terminal focused on developer experience and agent interoperability. It provides terminal management, persistence, and inter-agent messaging, but it does not currently emphasize semantic agent lifecycle tracking (working/blocked/done) in the same way Herdr does.

That makes Calyx look closer to “cmux + agent communication” than to Herdr’s agent-aware control plane.