# gbrain-skill

Canonical health dashboard + autonomous brain compounding engine for [GBrain](https://github.com/garrytan/gbrain) + [OpenClaw](https://www.npmjs.com/package/openclaw) integrations. Single-command surface to verify the brain stack, detect silent drift, and grow the knowledge graph autonomously while you sleep.

Built on top of 60+ hours debugging GBrain + OpenClaw together — encodes every check that was ever needed to find a root cause, plus a 7th-phase compounding loop that complements the deterministic `gbrain dream` cycle.

## What it does

`bash run.sh check` (or `/gbrain` in Claude Code / OpenClaw) gives you a full markdown dashboard covering:

### 🚨 Alert banner (top, only when critical)
Renders only when one of these is true:
- Stuck sessions detected in the openclaw log within the last hour
- `openclaw-node` process has 0 `*_API_KEY` vars in its environment (MCP children will fail silently)
- Agent model has no fallbacks configured (one timeout = dead session)
- Doctor queue depth > 100 on any worker
- Public Tailscale Funnel TLS desynced (silent downtime)

### 16 layers
| # | Layer | What it answers |
|---|---|---|
| 1 | Versiones | GBrain + OpenClaw vs latest published |
| 2 | Runtime | Gateway, Telegram conns, npm loops, model + fallbacks, MCP, SOUL.md directive |
| 3 | Doctor | `gbrain doctor --json` structured table |
| 3b | Schema correlation | DB tables ↔ wrapper ↔ skills (catches silent migration drift) |
| 4 | Stats | Pages / chunks / embedded / links / timeline / tags |
| 5 | Skills | GBrain skills loaded in OpenClaw (signal-detector, brain-ops, etc.) |
| 6 | Capture (24h) | Pages/links/timeline created + `gbrain__` MCP calls in last 5 sessions |
| 7 | Bugs (you-affecting) | Cross-references known upstream bugs vs your installed versions |
| 8 | News | Last 5 PRs/issues with date + labels |
| 9 | Snapshot diff | Stats delta vs last snapshot — catches silent drops in capture |
| 10 | Canonical files mtime | SOUL.md / MEMORY.md / openclaw.json — flags unexpected changes |
| 11 | MCP Health | Each registered MCP server + binary presence on disk |
| 11b | Wrappers + Integrations | HTTP wrappers (systemd), integration recipes, OAuth clients, capture by source |
| 12 | Stuck sessions | Rolling 1h count from openclaw log — direct symptom of "agent not responding" |
| 13 | Process env audit | Counts `*_API_KEY` in `/proc/$openclaw-node/environ` (catches silent-MCP-failure root cause) |
| 14 | Cron failure rate (24h) | Reads `~/.openclaw/cron/jobs-state.json`, lists which crons are failing |
| 15 | Upstream changelog | Last 15 commits flagged ✅ instalado / 🔜 pendiente + cross-references fix-commits with your warnings + author posts |
| 16 | Upgrade Decision Engine | INSTALAR / ESPERAR / SKIP per tool with concrete reasons + best-stack-today |

## Subcommands

```bash
bash run.sh check                # full 16-layer dashboard + alert banner
bash run.sh bootstrap            # verify entire stack is canonically installed (idempotent)
bash run.sh fix                  # idempotent auto-fix (embed --stale, extract, integrity, migrations)
bash run.sh news                 # only upstream releases/PRs/issues (with dates + labels)
bash run.sh bugs                 # only bugs that affect THIS user
bash run.sh compare              # diff vs previous snapshot
bash run.sh save                 # full + save markdown to ~/brain/reports/gbrain-latest.md
bash run.sh principles           # operational rules (canonical-wins, no-signal-masking)
bash run.sh manifest             # canonical inventory of your stack
bash run.sh manual               # full manual with use-cases
bash run.sh custom-instructions  # generate updated Custom Instructions block for claude.ai

bash run.sh compound run         # run the 7th-phase compounding cycle (LLM-driven)
bash run.sh compound dry-run     # preview proposals without applying
bash run.sh compound status      # confidence per category + lifetime stats
bash run.sh compound history     # last 10 cycles
bash run.sh compound revert <id> # queue revert of a specific change
```

## 🌙 Compounding Engine (7th phase)

Runs nightly via cron, ~30 min after `gbrain dream`. Adds an LLM-driven semantic phase to the deterministic dream cycle:

1. **Backs up brain state** before any change.
2. **Reads** pages from last 24h + categorical learning state.
3. **Calls LLM** (DeepSeek API by default — uses your `~/.openclaw/.env` key; falls back to `claude --print` if available) with a strict-JSON prompt.
4. **Detects** 7 categories of opportunities:
   - `people_orphans` — names mentioned 2+ times without their own page
   - `page_orphans` — pages with 0 links AND >7 days old
   - `knowledge_gaps` — companies/concepts referenced 3+ times without a page
   - `concept_duplication` — originals with embedding cosine sim >0.92
   - `incomplete_pages` — `LENGTH(compiled_truth) < 100`
   - `archive_decay` — 90+ days no updates AND 0 hits in `mcp_request_log`
   - `synthesis_opportunities` — 3+ originals on same theme → consolidation concept
5. **Auto-applies** changes only in categories with confidence ≥ 0.70 (initial: 0.40-0.80, evolves with reverts).
6. **Journals** every change with revert ID; backs up the brain to `compound/backups/`.
7. **Telegram silent push** at 08:00 with summary (auto-applied / skipped / errors).

After 30+ cycles the engine knows your editorial preferences from the categories you've reverted vs accepted. It's the loop that lets the brain "be smarter than when you went to sleep" while staying within the boundaries you've shown it.

Cron-safe out of the box: auto-loads PATH and `DEEPSEEK_API_KEY` / `ANTHROPIC_API_KEY` from `~/.openclaw/.env`, since cron doesn't inherit user env.

## Files

| File | Purpose |
|---|---|
| `SKILL.md` | The skill descriptor for Claude Code / OpenClaw skill loaders |
| `run.sh` | Single source of truth — all subcommands route through here |
| `bootstrap.sh` | Idempotent stack verifier — reports what's missing and how to fix it |
| `MANIFEST.json` | Canonical inventory: expected versions, paths, schema contracts, upstream issues open |
| `MANUAL.md` | Full manual with use-cases — invoked by `run.sh manual` |
| `PRINCIPLES.md` | Operational rules + decision log (every canonical-vs-workaround choice with date) |
| `PROTOCOL.md` | Original 6-method bug detection protocol — historical reference |
| `compound/run.sh` | Compounding engine main orchestrator (4 phases: pre-flight → backup → analyze → apply) |
| `compound/morning-report.sh` | Reads journal, sends Telegram silent push at 08:00 |
| `compound/prompts/analyze.md` | LLM prompt with strict-JSON contract |

## Install

```bash
git clone https://github.com/durang/gbrain-skill.git
mkdir -p ~/.openclaw/skills/gbrain
cp -r gbrain-skill/. ~/.openclaw/skills/gbrain/
chmod +x ~/.openclaw/skills/gbrain/run.sh ~/.openclaw/skills/gbrain/bootstrap.sh ~/.openclaw/skills/gbrain/compound/*.sh
bash ~/.openclaw/skills/gbrain/bootstrap.sh   # verify stack
bash ~/.openclaw/skills/gbrain/run.sh check   # first dashboard
```

For **Claude Code**, also symlink: `ln -sf ~/.openclaw/skills/gbrain ~/.claude/skills/gbrain` — both invocation paths call the same `run.sh`.

For **automated nightly compounding**, add to crontab:

```
30 10 * * * bash $HOME/.openclaw/skills/gbrain/compound/run.sh run >> $HOME/.gbrain/logs/compound.log 2>&1
0 15 * * * bash $HOME/.openclaw/skills/gbrain/compound/morning-report.sh >> $HOME/.gbrain/logs/compound.log 2>&1
```

(Adjust hours to your timezone — example assumes UTC, runs at 03:30 / 08:00 Hermosillo UTC-7.)

## Requirements

- `gbrain` CLI in `PATH` (tested with v0.22.5 → v0.22.8)
- `openclaw` CLI in `PATH` (tested with v2026.4.23)
- `~/.gbrain/config.json` with `database_url` (Supabase Postgres + pgvector recommended)
- `~/.openclaw/openclaw.json` with at least one MCP server, agent definition, and Telegram channel (optional, only used for drift alerts)
- For compounding engine: `DEEPSEEK_API_KEY` in `~/.openclaw/.env` (or `claude` CLI installed for fallback)
- `psql`, `python3`, `curl` (standard on Amazon Linux 2023 / Ubuntu)

## Why each new layer exists

L11–L16 were added after real incidents:

- **The "MCP gbrain ✅ but everything is broken" incident.** Legacy dashboard reported MCP healthy while the MCP server had been failing every 15 min for hours with `OPENAI_API_KEY missing` — because `openclaw-node` was started by systemd without `EnvironmentFile=`. **L13 process env audit** catches this instantly (count of API keys = 0). **L12 stuck-session detector** flags the symptom. **L14 cron failure rate** shows the GBrain Sync cron failing repeatedly.
- **The "Tailscale Funnel TLS desync silent downtime" incident.** Wrapper restarted post-upgrade, TLS cert went out of sync, public endpoint returned 502 for 3 hours while local `127.0.0.1:8787/health` looked fine. **L11b** now probes the public path explicitly.
- **The "schema migration silent break" risk.** When gbrain merges a migration that renames a column the wrapper depends on, the wrapper 500s in production with no warning. **L3b** now diff-checks expected columns vs actual schema.
- **The "should I upgrade?" decision fatigue.** Every release of gbrain or openclaw triggers a "is it safe?" investigation. **L16** encapsulates senior-engineer judgment heuristics into a single verdict (INSTALAR / ESPERAR / SKIP) with concrete reasons + issue links.

## Operating principles (PRINCIPLES.md)

The skill follows non-negotiable rules — no local workarounds that mask upstream signals, no "noise filters" that drift over time, every canonical-vs-workaround decision logged with a date stamp. See `PRINCIPLES.md` for the full list and decision log.

## Caveats

- Reads only by default — `fix` subcommand is idempotent and only runs known-safe operations. Never modifies code, only state (re-extract, re-embed, re-validate).
- L8/L15 hit GitHub API unauthenticated → rate-limited at 60 req/h per IP. If you exceed, those sections show empty; nothing else breaks.
- L13 reads `/proc/$pid/environ` which is mode `0400` (owner only). Run as the same user that owns `openclaw-node`.
- Compounding engine writes to your brain. Always run `dry-run` first on a new install. The journal records every change with a revert ID.
- The script is bash + Python 3 + `gbrain` + `openclaw` CLIs + `curl`. No external dependencies installed.

## Upstream

- [garrytan/gbrain](https://github.com/garrytan/gbrain) — the brain itself
- [openclaw/openclaw](https://github.com/openclaw/openclaw) — the runtime
- PRs in flight: [#481](https://github.com/garrytan/gbrain/pull/481) (claude-code-capture recipe), [#509](https://github.com/garrytan/gbrain/pull/509) (compounding-engine recipe)
- Issues open: [#73327](https://github.com/openclaw/openclaw/issues/73327) (per-job stuckThresholdMs)

## License

MIT.

## Author

Sergio Durán ([@durang](https://github.com/durang)).
Built on top of GBrain by Garry Tan ([@garrytan](https://github.com/garrytan)).
