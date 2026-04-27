# GBrain Architecture — Reference Audit

End-to-end view of how a multi-machine GBrain setup is wired: clients, processes, transports, brain backend, and where each piece lives. Use this as the mental model when adding a new client, debugging "why isn't this connected", or onboarding a new collaborator.

The diagrams are generic. Substitute your own hostnames, paths, and clients.

## 1. The bird's-eye view

```
                           ┌──────────────────────────────────────┐
                           │          Supabase Postgres           │
                           │          (the brain itself)          │
                           │  pages · chunks · embeddings · links │
                           │                  │                   │
                           │     pgvector  ·  HNSW  ·  pgbouncer  │
                           └─────────────────┬────────────────────┘
                                             │
                              database_url (one URL, shared)
                                             │
              ┌──────────────────────────────┼──────────────────────────────┐
              │                              │                              │
        ┌─────┴──────┐                ┌──────┴──────┐                ┌──────┴──────┐
        │  Server    │                │   Laptop    │                │   Other     │
        │  (EC2,     │                │   (Mac,     │                │   machines  │
        │   VPS,     │                │   Linux)    │                │   you own   │
        │   home)    │                │             │                │             │
        └─────┬──────┘                └──────┬──────┘                └──────┬──────┘
              │                              │                              │
              │ each machine runs            │                              │
              │ its own local                │                              │
              │ "gbrain serve" stdio         │                              │
              │ + optional jobs/autopilot    │                              │
              ▼                              ▼                              ▼
       ┌────────────┐                 ┌────────────┐                 ┌────────────┐
       │ MCP stdio  │                 │ MCP stdio  │                 │ MCP stdio  │
       │  clients   │                 │  clients   │                 │  clients   │
       └────────────┘                 └────────────┘                 └────────────┘
   Claude Code / Cursor /         Claude Code / Cursor /         Claude Code / Cursor /
   Windsurf / Antigravity         Windsurf / Antigravity         Windsurf / Antigravity
```

Key idea: **the brain is one Postgres database**. Each machine you want to use runs its own local `gbrain serve` (stdio) that points at that database. MCP clients on each machine spawn `gbrain serve` as a child process — they never talk over the network.

## 2. Per-machine zoom (one node)

A typical machine looks like this:

```
┌─────────────────────────────────────────────────────────────────┐
│  Machine ($HOME)                                                │
│                                                                 │
│  ┌─────────────────────────────────┐                            │
│  │  ~/.gbrain/config.json          │  ◄── declares engine + URL │
│  │  { engine: "postgres",          │                            │
│  │    database_url: "..." }        │                            │
│  └────────────┬────────────────────┘                            │
│               │ read by every gbrain CLI invocation             │
│               ▼                                                 │
│  ┌─────────────────────────────────┐                            │
│  │  ~/.bun/bin/gbrain  (Garry Tan) │                            │
│  └────────────┬────────────────────┘                            │
│               │ spawned per command                             │
│               ▼                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Long-running processes (optional, server-class only)   │    │
│  │   • gbrain serve        — one per MCP client connection │    │
│  │   • gbrain jobs work    — background queue worker       │    │
│  │   • gbrain autopilot    — git→brain incremental sync    │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  MCP clients on this machine                            │    │
│  │   • Claude Code        ~/.claude.json  (stdio)          │    │
│  │   • Cursor             ~/.cursor/mcp.json  (stdio)      │    │
│  │   • Windsurf           ~/.codeium/windsurf/mcp_config   │    │
│  │   • VS Code Claude ext shares ~/.claude.json with CC    │    │
│  │   • Antigravity        shares ~/.claude.json with CC    │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

Notes:

- **`gbrain serve` is stdio-only**, one process per active MCP client. If you have Claude Code + Cursor open at the same time on the same machine, you'll see two `gbrain serve` processes.
- **`jobs work` and `autopilot` are server-class**: only worth running on a node that's always on (your EC2/VPS/home server). A laptop doesn't need them.
- **Antigravity, VS Code Claude extension, and Claude Code CLI all read `~/.claude.json`**. Configure once → all three see the MCP entry.

## 3. What is connected and why — checklist

| Layer | Where it runs | Transport | Wired today? | Why / reason |
|---|---|---|---|---|
| Brain backend (Postgres) | Cloud (Supabase) | TCP 6543 (pgbouncer) | ✅ | Single source of truth for all clients |
| `gbrain serve` (server node) | Your always-on box | stdio child of MCP client | ✅ | Lets EC2/server's Claude Code use the brain |
| `gbrain jobs work` | Server node | n/a (queue worker) | ✅ | Processes async embed/extract jobs |
| `gbrain autopilot` | Server node | n/a (file watcher → DB) | ✅ | Mirrors a git repo into the brain |
| `gbrain serve` (laptop) | Your Mac/Linux laptop | stdio child of MCP client | ✅ | Lets laptop's Claude Code use the brain |
| Claude Code (terminal/Antigravity/VS Code) | Local machine | MCP stdio | ✅ | Canonical Option 1 in `docs/mcp/CLAUDE_CODE.md` |
| Cursor | Local machine | MCP stdio | ✅ | Same stdio pattern |
| Windsurf | Local machine | MCP stdio | ✅ | Same stdio pattern |
| Claude Desktop app | Local machine | MCP HTTP only | ❌ | App only accepts remote HTTP servers; no stdio for `gbrain serve`. Needs HTTP wrapper. |
| claude.ai web (chat, Cowork) | Anthropic servers | MCP HTTP only | ❌ | Anthropic servers can't reach your private network. Needs public HTTP wrapper + token. |
| Claude mobile (iOS/Android) | Anthropic servers | MCP HTTP only | ❌ | Same as above |
| Perplexity | Perplexity servers | MCP HTTP only | ❌ | Same as above |
| OpenClaw integration | Server node (next to gbrain) | direct CLI / DB | ✅ if you use OpenClaw | OpenClaw uses `gbrain` CLI as its memory backend |

### The HTTP gap, in one sentence

`gbrain serve --http` is documented as *"planned but not yet implemented"* in upstream `docs/mcp/DEPLOY.md`. Until that lands (or someone — possibly you — contributes a wrapper), the four ❌ rows above stay disconnected.

See [CONNECT.md](CONNECT.md) → "What about HTTP / Claude Desktop / claude.ai web?" for the three real paths to unblock them.

## 4. Data flow — write from one client, read from another

```
[Laptop:  Claude Code]                              [Server: Claude Code]
       │                                                     │
       │  "Save my note about openclaw memory"               │
       ▼                                                     │
  gbrain serve (stdio, on Laptop)                            │
       │                                                     │
       │  put_page(slug, content)                            │
       ▼                                                     │
  ┌─────────────────────────────────────────────────┐        │
  │            Supabase Postgres                    │        │
  │  INSERT pages, INSERT chunks,                   │        │
  │  trigger search_vector update,                  │        │
  │  enqueue embedding job,                         │        │
  │  enqueue link extraction job                    │        │
  └─────────────────────────────────────────────────┘        │
                            │                                │
                            │  (later, async on the server)  │
                            ▼                                │
                     gbrain jobs work                        │
                  generates embeddings                       │
                  extracts auto-links                        │
                                                             │
                   ─── any time later ───                    │
                                                             ▼
                                                      gbrain serve (stdio, on Server)
                                                             │
                                                             │  search_pages(query)
                                                             ▼
                                                       Supabase returns
                                                       the laptop's page
                                                       with embeddings
                                                       already populated
```

The laptop did the write. The server did the embedding work. Both clients see the same data because they share the same `database_url`.

## 5. What is NOT in the GBrain box (commonly confused)

These look like "memory" but they don't live in the GBrain DB:

| Thing | Where it actually lives | Confused with GBrain because |
|---|---|---|
| Claude Code's `auto-memory` | Local files in `~/.claude/projects/<dir>/memory/` | It's also called "memory" |
| OpenClaw heartbeat / dreams / SOUL | Local files under `~/.openclaw/` and `agents/*/memory/` | OpenClaw _uses_ GBrain but ALSO has its own files |
| Account-level MCPs in claude.ai (Google Drive, Gmail, Calendar, Figma, Cloudflare) | Anthropic-managed, attached to your account | They show up in `claude mcp list` next to gbrain |
| Tailscale tailnet URLs (`*.tail*.ts.net`) | Tailscale's coordination plane | Sometimes assumed to be where GBrain runs |

If you're hunting for a piece of context and `gbrain query` doesn't find it, check whether it actually lives in one of the rows above.

## 6. Where each thing lives (path cheatsheet)

| Thing | Path |
|---|---|
| GBrain config (per machine) | `~/.gbrain/config.json` |
| GBrain binary | `~/.bun/bin/gbrain` |
| Local PGLite brain (if used) | `~/.gbrain/brain.pglite/` |
| Autopilot run logs | `~/.gbrain/autopilot.log` |
| Claude Code MCP registry | `~/.claude.json` (key: `mcpServers`) |
| Cursor MCP registry | `~/.cursor/mcp.json` |
| Windsurf MCP registry | `~/.codeium/windsurf/mcp_config.json` |
| OpenClaw root (if installed) | `~/.openclaw/` |
| This skill (Claude Code) | `~/.claude/skills/gbrain/` |
| This skill (OpenClaw) | `~/.openclaw/skills/gbrain/` |

## 7. Audit checklist — "is everything wired right?"

Run these on each machine that should be on the brain:

```bash
# 1. Right binary in PATH
gbrain --version                              # 0.2x.x (Garry Tan), NOT 1.x.x (npm squat)

# 2. Pointing at the shared brain
cat ~/.gbrain/config.json                     # database_url should match other machines

# 3. Brain reachable
gbrain doctor --fast                          # health score >= 80

# 4. MCP wired
claude mcp list | grep gbrain                 # ✓ Connected

# 5. Bidirectional shared brain (run on Machine A, then Machine B)
echo "ping from A $(date -u +%FT%TZ)" | gbrain put test/ping-from-a    # on A
gbrain get test/ping-from-a                                            # on B — should print same line

# 6. (Server only) background workers alive
pgrep -af "gbrain (jobs work|autopilot)"      # should list both
```

If any step fails: see the "Common pitfalls" section in [INSTALL.md](INSTALL.md) and the troubleshooting in [CONNECT.md](CONNECT.md).

## 8. See also

- [README.md](README.md) — what this skill is
- [SKILL.md](SKILL.md) — `/gbrain` slash-command spec (the health dashboard)
- [INSTALL.md](INSTALL.md) — interactive bootstrap walkthrough
- [CONNECT.md](CONNECT.md) — multi-client compatibility matrix and HTTP-client paths
- [PROTOCOL.md](PROTOCOL.md) — what the health dashboard checks under the hood
- Upstream docs: [github.com/garrytan/gbrain/tree/main/docs/mcp](https://github.com/garrytan/gbrain/tree/main/docs/mcp)
