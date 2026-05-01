---
name: gbrain
description: "GBrain CENTRAL ORCHESTRATOR — 17-layer health dashboard + 7th-phase compounding engine + upstream features watch + skill propagation. THIS skill is source of truth for the GBrain stack: when upstream gbrain/openclaw releases new features (voice, zoom, dream synthesize, etc.), Layer 17 surfaces them as informational and tells which satellite skills (brain-write-macro, signal-detector, gbrain-http-wrapper) are affected. Subcomandos: /gbrain check (default), /gbrain fix, /gbrain news, /gbrain bugs, /gbrain compare, /gbrain save, /gbrain compound, /gbrain bootstrap, /gbrain principles, /gbrain manifest, /gbrain manual, /gbrain custom-instructions. Triggers: /gbrain, revisa gbrain, salud del brain, verifica el brain, gbrain status."
allowed-tools: Bash Read Write
user-invocable: true
distribute-to: [claude, openclaw]
role: central-orchestrator
related-skills: [brain-write-macro, signal-detector, gbrain-http-wrapper]
---

# /gbrain — GBrain Central Orchestrator

You are running the central authority for Sergio's GBrain + OpenClaw stack. This skill does NOT just report — it **dictates** how related skills behave.

## Central orchestrator contract (READ FIRST)

When upstream gbrain or openclaw changes anything, propagation flows from this skill outward:

1. **gbrain CLI upgrades** → Layer 17 surfaces new features (read from upstream commits) and tells the user which satellite skills are affected. Format: `you have a module for X — try it with <command>` OR `not applicable to your setup`.
2. **Schema migrations** → Layer 3b detects DB column drift and flags wrapper/skills that read affected columns.
3. **Wrapper changes** (`gbrain-http-wrapper`) → MANIFEST.json tracks expected version + security features; Layer 11b verifies wrapper health + public Tailscale Funnel TLS; bootstrap.sh confirms canonical install.
4. **Sub-skill updates** (`brain-write-macro`, `signal-detector`) → Layer 5 confirms loaded; Layer 11b D verifies macro pointer in SOUL.md; if upstream gbrain ships native equivalent, Layer 17 flags "subskill no longer needed".
5. **OpenClaw new features** (voice, zoom, video, etc.) → Layer 17 reads upstream commits/tweets, surfaces as informational, with concrete `try-it` commands. NOT urgent unless user-actionable.
6. **Compound engine** → owns subcommand `/gbrain compound`, runs as 30-min-after-dream complement. Since gbrain v0.23.0 ships `synthesize`+`patterns` natively, compound is now POST-DREAM (DB-side analysis), not the only LLM-driven layer.

**Hard rule:** if a satellite skill needs to change because of upstream movement, this skill MUST flag it first via Layer 17b (skill propagation). Never modify `brain-write-macro/SKILL.md` or `signal-detector/SKILL.md` without checking that `/gbrain check` says "skill propagation: needed".

## Action

Execute the runnable script that already exists at `~/.openclaw/skills/gbrain/run.sh`. It supports subcommands:

```bash
bash ~/.openclaw/skills/gbrain/run.sh check                # full 17-layer dashboard + alert banner
bash ~/.openclaw/skills/gbrain/run.sh fix                  # auto-fix safe issues (idempotent)
bash ~/.openclaw/skills/gbrain/run.sh news                 # only upstream releases/PRs/issues
bash ~/.openclaw/skills/gbrain/run.sh bugs                 # only bugs that affect THIS user
bash ~/.openclaw/skills/gbrain/run.sh compare              # diff vs previous snapshot
bash ~/.openclaw/skills/gbrain/run.sh save                 # full + save to ~/brain/reports/gbrain-YYYY-MM-DD.md
bash ~/.openclaw/skills/gbrain/run.sh bootstrap            # verify entire stack canonical
bash ~/.openclaw/skills/gbrain/run.sh principles           # operational rules + decision log
bash ~/.openclaw/skills/gbrain/run.sh manifest             # canonical inventory
bash ~/.openclaw/skills/gbrain/run.sh manual               # full manual with use-cases
bash ~/.openclaw/skills/gbrain/run.sh custom-instructions  # generate Custom Instructions block

bash ~/.openclaw/skills/gbrain/run.sh compound run         # run compounding cycle
bash ~/.openclaw/skills/gbrain/run.sh compound dry-run     # preview proposals
bash ~/.openclaw/skills/gbrain/run.sh compound status      # confidence per category
bash ~/.openclaw/skills/gbrain/run.sh compound history     # last 10 cycles
bash ~/.openclaw/skills/gbrain/run.sh compound revert <id> # queue revert
```

## How to invoke

1. **If user just types `/gbrain`** → run `bash ~/.openclaw/skills/gbrain/run.sh check` and stream output as markdown directly.
2. **If user types `/gbrain <subcommand>`** (e.g. `/gbrain fix`, `/gbrain save`, `/gbrain compound status`) → pass that subcommand verbatim.
3. **If user says natural language** ("revisa gbrain", "salud del brain", "está bien gbrain?") → run `check` by default.

## Output handling

The script outputs Markdown directly. Stream that output as-is — no reformat unless asked. If the script prints errors:
- `gbrain: command not found` → `bun install -g gbrain@github:garrytan/gbrain --force`
- `openclaw gateway status` returns "not running" → `openclaw gateway start`
- `psql` connection fails → check `~/.gbrain/config.json` has valid `database_url`

## 17-layer surface (what each layer does)

- 🚨 **Alert banner** (top, only when critical): stuck sessions >0, openclaw-node sin API keys, model sin fallbacks, queue depth >100, public Tailscale Funnel TLS desync
- L1 Versiones (gbrain + openclaw vs latest)
- L2 Runtime (gateway, telegram conns, npm loops, modelo primario + fallbacks, MCP, SOUL)
- L3 Doctor (gbrain doctor structured)
- L3b Schema correlation (DB ↔ wrapper ↔ skills, catches silent migration drift)
- L4 Stats (pages/chunks/links/timeline)
- L5 Skills loaded
- L6 Captura ambient 24h (signal-detector effectiveness)
- L7 Bugs upstream que TE afectan
- L8 News (releases/PRs/issues with date + labels)
- L9 Snapshot diff
- L10 Canonical files mtime
- L11 MCP Health
- L11b Wrappers + Integrations (HTTP wrappers, recipes, OAuth clients, capture by source)
- L12 Stuck sessions detector
- L13 Process env audit
- L14 Cron failure rate 24h
- L15 Upstream changelog
- L16 Upgrade Decision Engine (INSTALAR/ESPERAR/SKIP per tool)
- **L17 Upstream Features Watch** (NEW) — tweet-style feature surface + skill propagation rules
- **L17b Skill propagation** (NEW) — concrete propagation hints per satellite skill

## Files

- `SKILL.md` — this file (central orchestrator descriptor)
- `run.sh` — single source of truth, all subcommands route here
- `bootstrap.sh` — idempotent stack verifier
- `MANIFEST.json` — canonical inventory (versions, paths, schema contracts, upstream issues)
- `MANUAL.md` — full manual with use-cases
- `PRINCIPLES.md` — operational rules + decision log
- `compound/run.sh` + `compound/morning-report.sh` + `compound/prompts/analyze.md` — 7th-phase compound engine
- `tools/openclaw-to-corpus.py` — converter for `~/.openclaw/agents/*/sessions/*.jsonl` → `.txt` corpus that gbrain v0.23.0 `dream synthesize` reads

## Reference docs

- `PRINCIPLES.md` — operational rules (canonical-wins, no-signal-masking, decision log with dates)
- `MANIFEST.json` — schemas, expected versions, security gaps, upstream issues open
- Snapshots: `~/.openclaw/skills/gbrain/snapshots/` (auto-generated)

## Note on duplication (Claude Code vs OpenClaw)

This file lives at `~/.openclaw/skills/gbrain/SKILL.md` and is mirrored to `~/.claude/skills/gbrain/` via the monorepo `durang/skills`. Both invocation paths (Claude Code `/gbrain` AND OpenClaw Telegram `/gbrain`) call the same `run.sh`. **Single source of truth: `run.sh`.**
