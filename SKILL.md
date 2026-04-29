---
name: gbrain
description: "GBrain canonical health dashboard. 15 layers + alert banner top. Layers: versiones, runtime+fallbacks, doctor, stats, skills, captura ambient 24h, bugs upstream, news con fechas+labels, snapshot diff, file diff, MCP health, stuck sessions detector, process env audit, cron failure rate, upstream changelog vs implementado. Subcomandos: /gbrain check (default), /gbrain fix, /gbrain news, /gbrain bugs, /gbrain compare, /gbrain save. Triggers: /gbrain, revisa gbrain, salud del brain, verifica el brain, gbrain status."
allowed-tools: Bash Read Write
user-invocable: true
distribute-to: [claude, openclaw]
---

# /gbrain — GBrain Canonical Health Dashboard

You are running a complete health and canonicality check on the user's GBrain + OpenClaw setup.

## Action

Execute the runnable script that already exists at `~/.openclaw/skills/gbrain/run.sh`. It supports subcommands:

```bash
bash ~/.openclaw/skills/gbrain/run.sh check     # default: full 15-layer dashboard + alert banner
bash ~/.openclaw/skills/gbrain/run.sh fix       # auto-fix safe issues (idempotent)
bash ~/.openclaw/skills/gbrain/run.sh news      # only upstream releases/PRs/issues
bash ~/.openclaw/skills/gbrain/run.sh bugs      # only bugs that affect THIS user
bash ~/.openclaw/skills/gbrain/run.sh compare   # diff vs previous snapshot
bash ~/.openclaw/skills/gbrain/run.sh save      # full + save to ~/brain/reports/gbrain-YYYY-MM-DD.md
```

## How to invoke

1. **If user just types `/gbrain`** → run `bash ~/.openclaw/skills/gbrain/run.sh check` and show output as markdown directly to user.

2. **If user types `/gbrain <subcommand>`** (e.g. `/gbrain fix`, `/gbrain save`) → pass that subcommand.

3. **If user says natural language** ("revisa gbrain", "salud del brain", "está bien gbrain?") → run `check` by default.

## Output handling

The script outputs Markdown directly. Just stream that output to the user — no need to reformat or add commentary unless they ask.

If the script prints errors (e.g. `gbrain` binary missing, `openclaw` not running), explain what's wrong and suggest fixes. Common issues:
- `gbrain: command not found` → `npm install -g github:garrytan/gbrain` or `bun install -g github:garrytan/gbrain`
- `openclaw gateway status` returns "not running" → `openclaw gateway start`
- `psql` connection fails → check `~/gbrain/.env` has valid `DATABASE_URL`

## Why this skill exists

Sergio iterated for 48hrs to get OpenClaw + GBrain canonical. This skill encodes the
canonical check + auto-fix so neither he nor any future agent has to re-derive it.

The 14 layers + alert banner cover everything that can drift:
- 🚨 **Alert banner top** (solo si hay críticos): stuck sessions >0, openclaw-node sin API keys, modelo sin fallbacks, queue depth >100
- L1 Versiones (gbrain + openclaw vs latest)
- L2 Runtime (gateway, telegram conns, npm loops, modelo primario + fallbacks, MCP, SOUL)
- L3 Doctor (gbrain doctor structured)
- L4 Stats (pages/chunks/links/timeline)
- L5 Skills loaded
- L6 Captura ambient últimas 24h (detecta si captura cae)
- L7 Bugs upstream que TE afectan (matchea tu versión vs known bugs)
- L8 News (releases, PRs, issues — con fecha + labels)
- L9 Snapshot histórico + diff vs anterior
- L10 Cambios en SOUL.md / MEMORY.md / openclaw.json
- L11 MCP Health (cada server registrado + binario en disco)
- L12 Stuck sessions detector (último hora rolling, vía openclaw log)
- L13 Process env audit (count *_API_KEY en /proc/$openclaw-node/environ)
- L14 Cron failure rate 24h (lee jobs-state.json, lista crons fallando)
- L15 Upstream changelog vs implementado (últimos 15 commits ✅/🔜, fix-commits que matchean tus warnings, releases del autor)

## Reference docs

- Full skill spec: `~/.openclaw/skills/gbrain/SKILL.md` (OpenClaw version, idéntica)
- Protocol: `~/.openclaw/skills/gbrain/PROTOCOL.md` (qué archivos revisar, 6 métodos detect bugs)
- Bug report draft: `~/.openclaw/skills/gbrain/BUG_REPORT_DRAFT.md`
- Snapshots: `~/.openclaw/skills/gbrain/snapshots/` (auto-generated)

## Note on duplication (Claude Code vs OpenClaw)

This file is the Claude Code wrapper. The actual logic lives in
`~/.openclaw/skills/gbrain/run.sh` (single source of truth). Both invocation paths
(/gbrain in Claude Code AND /gbrain in OpenClaw Telegram) call the same script.
