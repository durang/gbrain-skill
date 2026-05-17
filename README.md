# gbrain-skill — ARCHIVED · moved to [durang/skills](https://github.com/durang/skills)

> **This repo is archived.** All content lives canonically in [`durang/skills`](https://github.com/durang/skills) under [`shared/gbrain/`](https://github.com/durang/skills/tree/master/shared/gbrain).

## Why archived

`durang/gbrain-skill` was the original standalone repo for the gbrain skill.
Since 2026-05, all my skills (gbrain + whatsapp + hermestrack + openclawtrack + 13 more) live in a single monorepo at [`durang/skills`](https://github.com/durang/skills). Maintaining two sources for the same skill caused drift (this repo fell behind by 7 days + several features).

**Consolidated 2026-05-17** — one canonical source going forward.

## What this skill does (still relevant)

`bash run.sh check` (or `/gbrain` in Claude Code / OpenClaw) renders a markdown dashboard with **19 main layers + 6 sub-layers (25 sections)** covering:

- 🚨 Alert banner (stuck sessions, missing API keys, model fallbacks, AWS infra drift)
- L1–L18 health checks (versions, runtime, doctor, schema, stats, skills, captures, bugs, news, MCP, wrappers, env, cron, upstream, decision engine, features watch, propagation, MCP clients, models)
- **L19 AWS Infra Health (NEW)** — 11 controls (CloudTrail, GuardDuty, Budget, DLM, SG, EBS, IMDSv2, root keys, MFA × 2, SOUL.md canonical guard)
- 🌙 **Compounding engine** — 7th-phase brain growth that runs while you sleep
- 🔬 **Lie-detector** (`/gbrain verify`) — re-checks every claim against ground truth
- 🔄 **/gbrain sync** (NEW) — orchestrator: pulls monorepo → install.sh → hermes migrate → auto-restore SOUL.md → verify md5 cross-runtime

## Where to go now

```bash
git clone https://github.com/durang/skills
cd skills/shared/gbrain
bash run.sh check
```

Or read the latest docs:
- [README.md (canonical)](https://github.com/durang/skills/blob/master/shared/gbrain/README.md)
- [ARCHITECTURE.md](https://github.com/durang/skills/blob/master/shared/gbrain/ARCHITECTURE.md)
- [INSTALL.md](https://github.com/durang/skills/blob/master/shared/gbrain/INSTALL.md)
- [MANUAL.md](https://github.com/durang/skills/blob/master/shared/gbrain/MANUAL.md)
- [PHASE_4_GUIDE.md](https://github.com/durang/skills/blob/master/shared/gbrain/PHASE_4_GUIDE.md)

## License

MIT (see [LICENSE](https://github.com/durang/skills/blob/master/shared/gbrain/LICENSE))
