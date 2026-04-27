# gbrain-skill

Canonical 15-layer health dashboard for [GBrain](https://github.com/garrytan/gbrain) + [OpenClaw](https://www.npmjs.com/package/openclaw) integrations. Single-command surface to verify the brain stack is at 100% canonical and to detect silent drift before it breaks the agent.

Built after 48 hours of debugging GBrain + OpenClaw together — encodes every check that was needed to find root cause, so neither future-me nor any agent has to re-derive it.

## What it does

Run `bash run.sh check` (or wire it as `/gbrain` in Claude Code / OpenClaw skill loader) and you get a full markdown report covering:

### 🚨 Alert banner (top, only when critical)
Renders only when one of these is true:
- Stuck sessions detected in the openclaw log within the last hour
- `openclaw-node` process has 0 `*_API_KEY` vars in its environment (MCP children will fail silently)
- Agent model has no fallbacks configured (one timeout = dead session)
- Doctor queue depth >100 on any worker

### 15 layers
| # | Layer | What it answers |
|---|---|---|
| 1 | Versiones | GBrain + OpenClaw vs latest published |
| 2 | Runtime | Gateway, Telegram conns, npm loops, model + fallbacks, MCP, SOUL.md directive |
| 3 | Doctor | `gbrain doctor --json` structured table |
| 4 | Stats | Pages / chunks / embedded / links / timeline / tags |
| 5 | Skills | GBrain skills loaded in OpenClaw (signal-detector, brain-ops, etc.) |
| 6 | Capture (24h) | Pages/links/timeline created + `gbrain__` MCP calls in last 5 sessions |
| 7 | Bugs (you-affecting) | Cross-references known upstream bugs vs your installed versions |
| 8 | News | Last 5 PRs/issues with date + labels |
| 9 | Snapshot diff | Stats delta vs last snapshot — catches silent drops in capture |
| 10 | Canonical files mtime | SOUL.md / MEMORY.md / openclaw.json — flags unexpected changes |
| 11 | MCP Health | Each registered MCP server + binary presence on disk |
| 12 | Stuck sessions | Rolling 1h count from openclaw log — direct symptom of "agent not responding" |
| 13 | Process env audit | Counts `*_API_KEY` in `/proc/$openclaw-node/environ` (catches the silent-MCP-failure root cause) |
| 14 | Cron failure rate (24h) | Reads `~/.openclaw/cron/jobs-state.json`, lists which crons are failing |
| 15 | Upstream changelog | Last 15 commits flagged ✅ instalado / 🟢 tu versión / 🔜 pendiente + cross-references fix-commits with your local doctor warnings |

## Subcommands

```bash
bash run.sh check     # default: full 15-layer dashboard + alert banner
bash run.sh fix       # idempotent auto-fix (embed --stale, extract links/timeline, integrity, migrations)
bash run.sh news      # only upstream releases/PRs/issues (with dates + labels)
bash run.sh bugs      # only bugs that affect THIS user
bash run.sh compare   # diff vs previous snapshot
bash run.sh save      # full + save markdown to ~/brain/reports/gbrain-latest.md
```

## Why each new layer exists

L11–L15 were added after a real incident where the legacy 10-layer dashboard reported `MCP gbrain ✅` while the MCP server had been failing every 15 minutes for hours with `OPENAI_API_KEY missing` — because `openclaw-node` was started by systemd without `EnvironmentFile=`, so its child processes (the gbrain MCP server) inherited an empty env.

The new layers detect each blind spot directly:
- **L13 process env audit** would have caught it instantly (count of API keys = 0).
- **L12 stuck-session detector** would have flagged the symptom (3 sessions stuck in last hour).
- **L14 cron failure rate** would have shown the GBrain Sync cron failing repeatedly.
- **L11 MCP binary check** confirms the MCP target binary still exists where openclaw expects it.
- **L15 upstream changelog cross-reference** marks which fixes you already have installed (so you don't waste time chasing an upgrade) vs which are still pending.

## Install

Copy `SKILL.md` + `run.sh` into your skills directory:
- Claude Code: `~/.claude/skills/gbrain/`
- OpenClaw: `~/.openclaw/skills/gbrain/`

The CLI wrapper (`SKILL.md`) is identical for both. Both invocation paths call the same `run.sh` (single source of truth).

## Requirements

- `gbrain` CLI in `PATH` (tested with v0.21.0)
- `openclaw` CLI in `PATH` (tested with v2026.4.23)
- `~/gbrain/.env` with `DATABASE_URL` (Supabase or local PGLite)
- `~/.openclaw/openclaw.json` with at least one MCP server, agent definition, and Telegram channel
- `psql`, `python3`, `curl` (standard on Amazon Linux 2023 / Ubuntu)

## Caveats

- Reads only — never modifies GBrain or OpenClaw state. Safe to run anytime.
- L8/L15 hit GitHub API unauthenticated → rate-limited at 60 req/h per IP. If you exceed, those sections show empty; nothing else breaks.
- L13 reads `/proc/$pid/environ` which is mode `0400` (owner only). Run as the same user that owns `openclaw-node`.
- The script is bash + Python 3 + `gbrain` + `openclaw` CLIs. No external dependencies installed.

## Installing on a new machine

Interactive bootstrap that detects your OS, installs the canonical GBrain from GitHub (not the squatted npm package), reuses or creates the brain config, and asks per-client which MCP clients to wire (Claude Code, Cursor, Windsurf — and explicitly skips clients that need an HTTP wrapper not yet available):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/durang/gbrain-skill/master/bootstrap.sh)
```

Full prompt-by-prompt walkthrough in [INSTALL.md](INSTALL.md).

## Connecting multiple clients to one brain

See [CONNECT.md](CONNECT.md) for the verified compatibility matrix and step-by-step recipes for sharing one GBrain across Claude Code on multiple machines, Cursor, Windsurf, and a frank explanation of what does NOT work today (Claude Desktop, claude.ai web Cowork, mobile — they need an HTTP wrapper that the v0.21.0 binary does not include).

## Architecture audit

[ARCHITECTURE.md](ARCHITECTURE.md) is the end-to-end mental model — diagrams of the multi-machine brain, per-machine zoom (config / binary / serve / jobs / autopilot), full inventory of what is connected and why (and what is NOT and why), data-flow walkthrough of a write-on-laptop / read-on-server roundtrip, and a 6-step audit checklist to run on each node.

## Ambient capture for Claude Code

By default, Claude Code does NOT write to GBrain — the MCP wiring lets the model query/write when it chooses, but conversational sessions end without leaving a trail. [CAPTURE.md](CAPTURE.md) documents the Claude Code Stop hook that mirrors OpenClaw's `signal-detector` skill: at session end, a Python script runs in background, asks Haiku to extract decisions / original thinking / entities / concepts, and writes selective pages to GBrain. The full transcript is NOT saved (that would be noise) — only signals worth keeping.

Install with one command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/durang/gbrain-skill/master/install-capture.sh)
```

Health check + auto-repair:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/durang/gbrain-skill/master/capture-doctor.sh)         # check
bash <(curl -fsSL https://raw.githubusercontent.com/durang/gbrain-skill/master/capture-doctor.sh) --fix   # repair
```

## Progression tracker

`progression.sh` is a stateful walkthrough of the full multi-client setup. Auto-detects which phases you have done, which are pending, and tells you exactly what to do next. Every claim is evidence-based (filesystem + config inspection — no remembered state):

```bash
# Status overview + next action (markdown)
bash <(curl -fsSL https://raw.githubusercontent.com/durang/gbrain-skill/master/progression.sh)

# Just the next pending action, terse
bash <(curl -fsSL https://raw.githubusercontent.com/durang/gbrain-skill/master/progression.sh) --next

# Save report into your shared brain (queryable from any machine)
bash <(curl -fsSL https://raw.githubusercontent.com/durang/gbrain-skill/master/progression.sh) --save

# Detail for one specific phase
bash <(curl -fsSL https://raw.githubusercontent.com/durang/gbrain-skill/master/progression.sh) --phase 5A
```

Tracks 9 phases (Phase 0 install → Phase 4D upstream contribution). Reinstall from scratch and the same script walks you back through every step in order.

## License

MIT.

## Author

Sergio Durán ([@durang](https://github.com/durang)).
Built on top of GBrain by Garry Tan ([@garrytan](https://github.com/garrytan)).
