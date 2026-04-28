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
