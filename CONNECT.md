# Connecting Multiple Clients to One GBrain

Practical reference for sharing one brain across multiple AI clients (Claude Code, Cursor, Windsurf, Claude Desktop, claude.ai web, mobile). Verified against `gbrain` v0.21.0 with Supabase Postgres engine.

## TL;DR

- **Local stdio clients** (Claude Code, Cursor, Windsurf, anything that supports MCP stdio): all share the same brain automatically by pointing each install of `gbrain` at the same Supabase `database_url`. ✅ Works today.
- **Remote HTTP clients** (Claude Desktop, claude.ai web Cowork, mobile, Perplexity): require an HTTP wrapper around `gbrain serve`. ❌ Not in the binary today — `gbrain serve --http` is documented as *"planned but not yet implemented"* in [docs/mcp/DEPLOY.md](https://github.com/garrytan/gbrain/blob/main/docs/mcp/DEPLOY.md).

## Compatibility matrix

| Client | Runs on | Transport needed | Possible today? | How |
|---|---|---|---|---|
| Claude Code (any host) | local machine | stdio | ✅ Yes | `claude mcp add gbrain -- gbrain serve` |
| Cursor | local machine | stdio | ✅ Yes | Add MCP server entry in Cursor settings |
| Windsurf | local machine | stdio | ✅ Yes | Add MCP server entry in Windsurf settings |
| Claude Desktop | local machine | HTTP only | ❌ Not today | Needs HTTP wrapper |
| claude.ai web (incl. Cowork) | Anthropic servers | HTTP only | ❌ Not today | Needs HTTP wrapper + public URL |
| Claude mobile (iOS/Android) | Anthropic servers | HTTP only | ❌ Not today | Needs HTTP wrapper + public URL |
| Perplexity | Perplexity servers | HTTP only | ❌ Not today | Needs HTTP wrapper + public URL |

## How shared brain works (architecture)

```
                    ┌──────────────────────┐
                    │   Supabase Postgres  │  ◄── the brain (single source of truth)
                    │   (or PGLite file)   │
                    └──────────┬───────────┘
                               │ same database_url
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
   gbrain serve            gbrain serve           gbrain serve
   (on Mac)                (on EC2)               (on laptop)
        │                      │                      │
        ▼                      ▼                      ▼
   Claude Code             Claude Code            Cursor / etc.
```

Each client runs its own local `gbrain serve` (stdio). They all read/write the same Postgres backend — so a page written from EC2 is immediately visible from Mac and vice versa.

## Connect a new local stdio client (canonical 4-step recipe)

This is the official path documented in [docs/mcp/CLAUDE_CODE.md](https://github.com/garrytan/gbrain/blob/main/docs/mcp/CLAUDE_CODE.md) Option 1, applied to multi-machine setups.

### 1. Install GBrain on the new machine

```bash
# requires Bun
curl -fsSL https://bun.sh/install | bash
bun install -g gbrain
gbrain --version  # should print 0.21.0+
```

### 2. Point it at the same Postgres as your other machines

If your "primary" machine has `~/.gbrain/config.json` with `engine: postgres` and a `database_url` to Supabase, copy the same `database_url` into the new machine's `~/.gbrain/config.json`:

```json
{
  "engine": "postgres",
  "database_url": "postgresql://...your-pooler-url..."
}
```

Permissions: `chmod 600 ~/.gbrain/config.json` (the URL contains the DB password).

### 3. Verify the connection

```bash
gbrain doctor --fast    # should show pgvector OK + same schema_version
gbrain list -n 3        # should show pages already created from your other machine
```

If `doctor` and `list` work and show the same data as the primary machine → the cerebro is shared.

### 4. Wire the MCP client

```bash
# Claude Code:
claude mcp add gbrain -- gbrain serve
claude mcp list   # confirms gbrain is registered + connected
```

For other stdio clients (Cursor, Windsurf), add this entry in their MCP config:

```json
{
  "mcpServers": {
    "gbrain": {
      "command": "gbrain",
      "args": ["serve"]
    }
  }
}
```

## What about HTTP / Claude Desktop / claude.ai web?

You have three real options today, ordered by effort:

### Option A — Wait for upstream HTTP transport
The README of `gbrain` says `gbrain serve --http` is on the roadmap. When it lands, this CONNECT.md will be updated with the canonical activation.

### Option B — Run a custom HTTP wrapper
Write a small Bun/Hono service that:
1. Accepts HTTP requests with `Authorization: Bearer <token>` (validated against tokens created via `bun run src/commands/auth.ts create`)
2. Spawns `gbrain serve` as a stdio child per request (or maintains a pool)
3. Pipes the MCP JSON-RPC frames between HTTP and stdio
4. Returns the response

Then expose it publicly via Tailscale Funnel (free, recommended) or ngrok ($8/mo Hobby for a fixed domain). Token-per-client gives you revocation. Reference: [docs/mcp/DEPLOY.md](https://github.com/garrytan/gbrain/blob/main/docs/mcp/DEPLOY.md) and [docs/mcp/ALTERNATIVES.md](https://github.com/garrytan/gbrain/blob/main/docs/mcp/ALTERNATIVES.md).

### Option C — Contribute the wrapper upstream
Submit a PR to `garrytan/gbrain` adding `gbrain serve --http` natively. This unlocks Claude Desktop, web, and mobile for every GBrain user, not just you.

## Verifying "shared brain" claims

Before trusting that two machines hit the same brain, write a unique test page from one and read it from the other:

```bash
# on machine A:
echo "ping from A at $(date -u +%FT%TZ)" | gbrain put test/multi-client-check

# on machine B:
gbrain get test/multi-client-check
# should print the same string
```

If machine B prints what A wrote → confirmed shared. If not, the `database_url` differs or there's a network/firewall issue between B and Supabase.

## Common pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `claude mcp list` shows `✗ Failed` | `gbrain` binary not in `PATH` for the shell that launched Claude Code | Use absolute path: `claude mcp add gbrain -- /full/path/to/gbrain serve` |
| `gbrain doctor` says `pgvector NOT FOUND` on machine B but works on A | Different `database_url` | Diff `~/.gbrain/config.json` across machines |
| Claude Desktop "added" the server but tools never appear | Tried `claude_desktop_config.json` for a remote URL | Desktop only takes remote MCP via Settings > Integrations GUI; JSON config is stdio-only |
| Tailscale URL works on tailnet but not from claude.ai web | claude.ai web runs on Anthropic's servers — not in your tailnet | Use Tailscale **Funnel** (public) or ngrok, not Tailscale **Serve** (tailnet-only) |

## References

- Upstream docs: [github.com/garrytan/gbrain/tree/main/docs/mcp](https://github.com/garrytan/gbrain/tree/main/docs/mcp)
  - [CLAUDE_CODE.md](https://github.com/garrytan/gbrain/blob/main/docs/mcp/CLAUDE_CODE.md) — local stdio (canonical)
  - [CLAUDE_DESKTOP.md](https://github.com/garrytan/gbrain/blob/main/docs/mcp/CLAUDE_DESKTOP.md) — remote HTTP (requires wrapper)
  - [CLAUDE_COWORK.md](https://github.com/garrytan/gbrain/blob/main/docs/mcp/CLAUDE_COWORK.md) — remote HTTP (requires wrapper)
  - [PERPLEXITY.md](https://github.com/garrytan/gbrain/blob/main/docs/mcp/PERPLEXITY.md) — remote HTTP (requires wrapper)
  - [DEPLOY.md](https://github.com/garrytan/gbrain/blob/main/docs/mcp/DEPLOY.md) — tunneling + auth tokens
  - [ALTERNATIVES.md](https://github.com/garrytan/gbrain/blob/main/docs/mcp/ALTERNATIVES.md) — ngrok vs Tailscale Funnel vs Fly.io
- This skill (health dashboard): [SKILL.md](SKILL.md)
- Author: Sergio Durán ([@durang](https://github.com/durang))
