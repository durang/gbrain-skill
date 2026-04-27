# Installing GBrain on a new machine

Reproducible, interactive setup that:

- detects your host (Mac, Linux, EC2)
- installs Bun + the canonical `gbrain` from `github:garrytan/gbrain` (not the squatted npm package)
- reuses an existing brain (Postgres/Supabase) or creates a local one
- asks per-client whether to wire MCP (Claude Code, Cursor, Windsurf), and explicitly skips the clients that need an HTTP wrapper not yet available (Claude Desktop, claude.ai web, mobile, Perplexity)
- runs a bidirectional ping to prove the brain is shared

## One-liner

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/durang/gbrain-skill/master/bootstrap.sh)
```

If you already cloned the repo:

```bash
bash bootstrap.sh
```

## What it asks you

The script prompts at every decision point. Defaults are sensible; press Enter to accept. You will be asked:

| # | Question | Default | Notes |
|---|---|---|---|
| 1 | Install Bun if missing? | yes | Required runtime |
| 2 | Reinstall canonical `gbrain` if a non-Garry-Tan version is detected? | yes | Catches the npm squat case |
| 3 | Reuse existing `~/.gbrain/config.json`? | yes | Skip if you want to switch brains |
| 4 | If no config: paste a Postgres URL, init local PGLite, or abort? | option 1 | Pick (1) for shared, (2) for solo |
| 5 | Connect Claude Code (terminal / Antigravity / VS Code Claude extension)? | yes | These three share `~/.claude.json` |
| 6 | Connect Cursor? | no | Wires `~/.cursor/mcp.json` |
| 7 | Connect Windsurf? | no | Wires `~/.codeium/windsurf/mcp_config.json` |
| 8 | Mark Claude Desktop / web / mobile as TODO? | no | They need HTTP wrapper (see CONNECT.md) |
| 9 | Run a bidirectional ping test? | yes | Writes `test/bootstrap-ping-<ts>` |
| 10 | Append Bun's bin to your shell PATH? | yes | Prevents `gbrain: command not found` in future shells |

## What it does NOT do

- **Does not connect Claude Desktop, claude.ai web (Cowork, chat), Claude mobile, or Perplexity.** These require HTTP, and `gbrain serve --http` is documented as *"planned but not yet implemented"* in the upstream `docs/mcp/DEPLOY.md`. See [CONNECT.md](CONNECT.md) for the three real paths to unblock those clients (wait upstream, build a wrapper, or contribute a PR).
- **Does not push tokens or secrets anywhere.** All config is local under `~/.gbrain/`.
- **Does not modify your shared Postgres schema.** `gbrain doctor` reads only.

## Verifying multi-machine shared brain

After running the bootstrap on machine A and on machine B (with the same `database_url`):

```bash
# Machine A:
echo "ping from A at $(date -u +%FT%TZ)" | gbrain put test/multi-client-ping

# Machine B:
gbrain get test/multi-client-ping
```

If machine B prints what A wrote, the brain is shared. If not, double-check `~/.gbrain/config.json` on both ends.

## Reinstalling from scratch (full reset)

The bootstrap is idempotent — safe to re-run. To force a clean reset of just the client (without touching the shared brain):

```bash
bun remove -g gbrain
rm -f ~/.bun/bin/gbrain
rm -rf ~/.gbrain
# Then re-run bootstrap.sh
```

To wipe the shared Postgres brain itself, do that on the database side (Supabase dashboard or `psql`), not on a client.

## Common pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `gbrain` installs but isn't in PATH | `~/.bun/bin` missing from shell PATH | Step 10 above; or `export PATH="$HOME/.bun/bin:$PATH"` |
| `gbrain --version` shows `1.x.x` | npm squat package (`gbrain` on registry, NOT Garry Tan's) | Bootstrap auto-replaces; or manually: `bun remove -g gbrain && bun install -g github:garrytan/gbrain` |
| `claude mcp list` shows `✗ Failed` | Binary path wrong, or `gbrain` not in PATH for Claude Code's spawned shell | Bootstrap registers with absolute path. If broken, re-run step 5/6/7 |
| `doctor` warns `Could not find skills directory` | Optional skills dir missing | Benign. Only matters if you load local skills |
| Shared-brain test fails: B can't see A's page | Different `database_url` between machines | Diff `~/.gbrain/config.json` on A vs B |

## See also

- [README.md](README.md) — what this skill is and the health dashboard
- [SKILL.md](SKILL.md) — `/gbrain` slash-command spec
- [CONNECT.md](CONNECT.md) — multi-client compatibility matrix and HTTP-client paths
- [PROTOCOL.md](PROTOCOL.md) — what the health dashboard actually checks
