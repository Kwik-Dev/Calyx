Based on my investigation of the Calyx architecture and MCP documentation, **no - MCP does NOT manage Calyx tabs or groups**. Here's the distinction:

## MCP (Model Context Protocol) Scope

### What MCP MANAGES:

| Category | Tools/Features |
|----------|---------------|
| **IPC Peer Communication** | 7 tools including `register_peer`, `list_peers`, `send`, `broadcast`, `status` |
| **Language Server Protocol** | 70 LSP tools: `lsp_hover`, `lsp_definition`, `lsp_install`, etc. |
| **Language Support** | 15+ languages with installation checking, prerequisites |
| **Code Intelligence** | Hover, definition, completion, workspace symbols |
| **Session Management** | `lsp_session_status`, `lsp_session_warmup`, auto-shutdown |

**MCP is primarily a protocol bridge** that connects Calyx to:
- Language servers (rust-analyzer, typescript-language-server, etc.)
- AI agents (Claude, OpenAI, etc. via HTTP)
- Bearer token authentication (stored in `~/.claude.json`)

### What MCP DOES NOT Manage:

| Feature | Management Method |
|---------|-------------------|
| **Browser tabs** | `calyx browser` CLI commands |
| **Tab grouping** | Not supported |
| **Tab closing/renaming** | Not supported |
| **Tab ordering** | Not supported |

## Tab/Group Management is Separate

### Browser Tab Commands (via `calyx browser`):

| Command | Function |
|---------|----------|
| `list` | List all browser tabs |
| `open` | Open a new browser tab |
| `navigate` | Navigate current/selected tab |
| `snapshot` | Get accessibility snapshot |
| `screenshot` | Take screenshot |

**Current state in your Calyx:**
```
calyx browser list
→ {"tabs":[{"id":"364D244B-8CEA-460F-8E36-49E914058850","url":"about:blank","title":""}]}
```
- 1 tab open (about:blank)
- No tab management commands available

### MCP Tools Related to Tabs:

Looking at the 77 MCP tools, **none** relate to tab management:

```
✅ IPC (7 tools): register_peer, list_peers, send, broadcast, receive-messages, ack-messages, status
✅ LSP (70 tools): lsp_hover, lsp_definition, lsp_install, lsp_session_status, etc.
❌ Tab management: No tools for close/rensae/duplicate/tabs
```

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────────┐
│                    Calyx Application                           │
│  ┌───────────────┐  ┌─────────────────────┐              │
│  │ Browser Layer │  │   MCP Proxy Layer   │              │
│  │ (tabs, UI)     │  │ (LSP/IPC bridging)  │              │
│  └───────────────┘  └─────────────────────┘              │
│           ▲                  ▲                           │
│           │                  │                           │
│     calyx browser      calyx ipc + lsp tools            │
│   (CLI commands)     (HTTP MCP protocol)              │
└─────────────────────────────────────────────────────────────────┘
```

## Key Differences

| Aspect | MCP | Browser CLI |
|--------|-----|-------------|
| **Purpose** | Language/server bridging | Tab/window management |
| **Tools** | 77 protocol tools | ~12 browser commands |
| **Access** | HTTP to `:41830/mcp` | Terminal `calyx` commands |
| **Audience** | AI agents, language servers | Human users via terminal |
| **State** | Token auth, server connections | Tab IDs, URLs, titles |

## What MCP Actually Controls

MCP controls **language-related functionality**, not UI layout:

```
MCP manages:
✅ Language server connections
✅ Code intelligence (hover, definition, completion)
✅ 7 IPC peer communication tools
✅ Language installation checking
✅ Session warmup/shutdown
✅ Auto-install of language servers

MCP does NOT manage:
❌ Browser tabs
❌ Window layout
❌ Tab groups or groupings
❌ UI positioning
❌ Visual page elements (except via lsp_hover which shows code, not DOM)
```

## Practical Example

**To manage tabs:** Use `calyx browser` commands:
```bash
calyx browser list          # See tabs
calyx browser open url     # Open new tab
calyx browser navigate url # Move current tab
```

**To use language features:** Use MCP:
```bash
# Via HTTP POST to MCP server
curl -X POST http://127.0.0.1:41830/mcp \
  -H "Authorization: Bearer <token>" \
  -d '{"method":"tools/call","params":{"name":"lsp_hover","arguments":{"language_id":"typescript", "position":{"line":0,"column":7}}}'
```

## Bottom Line

**MCP = Protocol bridge for language/code intelligence** (not tab management)
**Browser CLI = Tab and interface management** (not language features)

They're complementary systems that don't overlap - MCP handles what language servers can do, while the browser CLI handles the Calyx terminal's UI state (tabs, windows, etc.).