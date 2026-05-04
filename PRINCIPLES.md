# /gbrain — Operating Principles

These are non-negotiable rules for how this skill (and any future skill in the stack) handles upstream signals, workarounds, and fixes.

## 1. Canonical upstream behavior ALWAYS wins

When an upstream tool (gbrain, openclaw, anthropic) emits a signal, **the skill respects it as-is**. We do NOT downstream-classify, filter, or hide signals from upstream detectors — even if they appear noisy.

**Rationale:** local filters drift over time. The detector that emits the signal has more context than my downstream interpretation. If I add a whitelist today and forget about it, in 3 months when the detector starts firing for a NEW reason that I never anticipated, my whitelist silently masks it. Real bug → no alert → production breaks.

**Concrete example (incident 2026-04-28):**
> Tried to silence "stuck session" alerts for `GBrain Sync` cron because the 120s OpenClaw threshold was too aggressive for legitimate 2-3min remote syncs. Sergio caught it and pointed out: "but we'll lose signal." He was right. Reverted the workaround within an hour, opened upstream issue #73327 instead.

## 2. Noise from upstream → fix raíz upstream

If the canonical signal is noisy:
- **Open issue** in the upstream repo describing the noise + a clean shape for the fix.
- **Live with the noise** locally until upstream merges (or until the issue is rejected with a justification we accept).
- **Do NOT** add local workarounds that mask the upstream signal.

**The exception:** if a critical SLA is at stake AND upstream has been silent for >30 days, document the workaround AS a workaround (clearly marked) and link the upstream issue. When upstream merges, remove the workaround.

## 3. Skills monitor; they do not opinion

`/gbrain` reports what tools say. It does NOT decide which tool's signal is "really important" vs "noisy." That decision belongs to the user (Sergio) and to upstream.

## 4. Capabilities (genuine gaps) ≠ Workarounds (signal masking)

These are different and the principle applies only to the second:

- **Capability** — fills a real gap in the stack (e.g., `brain-write-macro` exists because mobile/web/desktop have NO hooks; the gap is in the platform, not in our interpretation). ✅ Build these.
- **Workaround** — masks/filters/redirects an upstream signal we don't like. ❌ Avoid these. Fix raíz upstream.

## 5. Honest reporting

- If an upstream tool emits a warning, the skill reports it verbatim with the upstream's wording.
- If the user wants to suppress it, the skill explains the trade-off and points at the upstream issue, then the user decides.
- The skill never silently filters signals.

## 6. Decision log

Every time we choose between "canónico vs workaround," we document the decision in this file with a date stamp. Future maintainers (incl. me 6 months from now) can see why each choice was made.

### Decision log

| Date | Decision | Rationale | Upstream issue |
|---|---|---|---|
| 2026-04-28 | Stay canonical on stuck-session detector. No local classification. | Sergio: "perderemos señal." Correct. | [openclaw/openclaw#73327](https://github.com/openclaw/openclaw/issues/73327) |
| 2026-04-28 | Disabled `tts-audio-watcher.service` (workaround) | Watcher was created for OpenClaw v2026.4.19 bug that's fixed in .23. Watcher had become DUPLICATE delivery on top of OpenClaw native. Removing a stale workaround is NOT masking signal — opposite of the stuck-detector case. Verification window 24h before permanent archive. Script preserved in `~/bin/` for rollback. | (none — bug already resolved upstream) |
| 2026-04-28 | Implemented 3 cheap-win security fixes in wrapper: audit log, rate limit, content wrapping | Public security audit triggered by Clay Whitehead question on X. Picked the 3 lowest-disruption / highest-impact fixes. All stress-tested (30 concurrent ok, 130 sequential → 120/10 split). Cero regresiones. Open gaps documented (DATABASE_URL=superuser, RLS theatre, refresh token rotation, granular scopes) for future iteration. | (n/a — internal fix, no upstream issue needed) |
| 2026-04-29 | Built `compounding-engine` as 7th phase complement to gbrain dream cycle (NOT replacement) | Gbrain dream covers structural maintenance (lint/backlinks/sync/extract/embed/orphans) but doesn't create new structure. Engine adds LLM-driven semantic detection: people orphans, knowledge gaps, concept duplication, synthesis opportunities, archive decay. Per-category confidence learning loop — engine adapts to user editorial preferences from reverts over 30+ cycles. Coordinated with dream cycle via 30-min cron offset. Sent upstream as recipe PR. | [garrytan/gbrain#509](https://github.com/garrytan/gbrain/pull/509) |
| 2026-05-03 | Migrated "GBrain Sync" cron from openclaw isolated-agent (5 min/run, 1GB RAM) to system shell crontab (0.4 sec/run, <100MB) | Garry's canonical pattern in `docs/guides/live-sync.md` (Approach 1) is direct shell command `gbrain sync && gbrain embed --stale`. Old approach spawned full openclaw agent runtime + plugins/MCP just to execute 2 shell commands → 670x overhead, saturated 4GB EC2 to swap. Same `*/15` cadence preserved. MANIFEST adds `system_crontab_jobs` array + Layer 14b in `/gbrain check` audits declared vs actual crontab. | (none — config/skill change, gbrain CLI capability already exists) |
| 2026-05-03 | `agentRuntime: codex` MUST live on individual agent (`agents.list[main]`) NOT on `agents.defaults` | Setting it on defaults applies to ALL agents incl. isolated cron jobs. Cron agents like "GBrain Dream" use non-OpenAI fallbacks (deepseek/minimax/xai). Codex runtime rejects those with HTTP 400 "model not supported when using Codex with a ChatGPT account" → cascade fail spawns nested processes → saturated 3.7GB RAM to swap → Telegram polling died → user sent photo, never received it. Per-agent override: `agents.list[id=main].agentRuntime={id:codex, fallback:none}` keeps Telegram on Plus subscription, leaves cron agents on default PI runner. | (none — schema already supports per-agent override; failure mode now documented) |
| 2026-05-03 | Codex Plus subscription requires `~/.codex/auth.json` (codex CLI native) — OpenClaw's own OAuth profile is insufficient | OpenClaw codex runtime resolves auth in order: (1) OpenClaw OAuth profile, (2) **Codex CLI session** at `~/.codex/auth.json`, (3) ENV vars. Without (2), the runtime falls through to Direct API endpoint (`api.openai.com/v1/responses`) which requires `api.responses.write` scope — Plus tokens lack that → 401 silent failures. Fix: install `@openai/codex` CLI, construct `~/.codex/auth.json` from OpenClaw OAuth profile (access_token, refresh_token, account_id from JWT claims). | (none — undocumented in OpenClaw docs at time of writing; consider upstream PR to docs) |
| 2026-05-03 | EC2 sized at t3.medium (4GB) is insufficient for full stack (gateway+node+wrapper+7 isolated crons+browser headless+bun+python skills). Upgraded to t3.large (8GB). | Full stack baseline ~2.8GB, but cron isolated runs spawn +1GB each. With 4GB → swap (100x slower) → cascade saturation (Telegram drops, agent runs queue, event-loop delay 19s+). With 8GB: zero swap pressure, isolated crons cohabit, Telegram responds in 2-5s vs 1-2 min. Cost: +$30/mo (~$60 t3.large vs $30 t3.medium). User incidents (failed Telegram requests during peak) more than justified. | (n/a — infra capacity decision) |

(Append new rows as decisions get made.)

## 7. The trade-off is permanent until upstream fixes

After choosing canonical, we accept:
- Telegram drift alert may fire 1-3× per hour for the GBrain Sync window (false positives by stuck-detector standards, but legitimate signal-of-the-detector).
- This is the cost of keeping the signal channel honest.
- It improves automatically the day OpenClaw merges #73327.

When that happens, `/gbrain` Layer 16 (Upgrade Decision Engine) will detect the new OpenClaw release and flag it as "INSTALAR — closes #73327, your noise issue."

That's the loop. Canonical → upstream issue → wait → upgrade → noise gone. Forever, structurally.

---

## Reference

- Run `/gbrain check` to see this skill in action.
- This file is read by future agents to understand WHY the skill behaves this way.
- Update only with explicit user confirmation.
