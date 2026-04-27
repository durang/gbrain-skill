# Ambient Capture for Claude Code

Mirrors the OpenClaw `signal-detector` skill pattern, ported to Claude Code as a Stop hook. After every Claude Code session, a small Python script runs in the background, asks Haiku to extract original thinking + entity mentions + decisions from the just-finished transcript, and writes selective pages to GBrain — never blocking the user, never saving the full transcript.

## Why this exists

By default, Claude Code does NOT write to GBrain. The MCP wiring lets the model query/write when it chooses to, but conversational sessions end without leaving a trail in the brain. OpenClaw users have `signal-detector` doing this for Telegram chats; this brings the same pattern to terminal sessions.

## What gets captured

Per the OpenClaw signal-detector contract:

| Category | Slug pattern | What it is |
|---|---|---|
| Decisions | `decisions/<kebab>` | Concrete decisions made in the session (architecture, scope, prioritization) |
| Insights (originals) | `originals/<kebab>` | User's original thinking — captured with the user's exact phrasing, NOT paraphrased |
| Entities | `people/<kebab>` or `companies/<kebab>` | Notable people/companies mentioned |
| Concepts | `concepts/<kebab>` | World concepts or domain ideas referenced |

What is NOT captured:

- The full transcript (would be noise; auto-memory in `~/.claude/projects/<dir>/memory/` already handles that locally if you want full sessions)
- Operational chatter (yes/no/run-this — flagged as `skip_reason: "operational"` and dropped)
- Sessions under 2KB of transcript (skipped as too small)

## Files

| Path | Purpose |
|---|---|
| `~/.gbrain/hooks/signal-detector.py` | The capture script (Python) |
| `~/.gbrain/hooks/signal-detector.log` | One-line-per-run log: `[ok:<sid>] captured: N decisions, N insights, N entities, N concepts` |
| `~/.gbrain/hooks/last-extraction-raw.txt` | Last raw response from Haiku — only written on parse failure (debugging aid) |
| `~/.claude/settings.json` (`hooks.Stop`) | Wires the script as a Stop event hook |

## Install

After running [`bootstrap.sh`](INSTALL.md), enable ambient capture with:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/durang/gbrain-skill/master/install-capture.sh)
```

Or manually:

1. Place `signal-detector.py` at `~/.gbrain/hooks/signal-detector.py`, chmod 700.
2. Ensure `ANTHROPIC_API_KEY` is set in `~/gbrain/.env` (the script reads it from there). The script does NOT need a separate API key — it reuses the one you already use for `gbrain agent run`.
3. Add this to `~/.claude/settings.json` (merge with existing `hooks` if present):

```json
{
  "hooks": {
    "Stop": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "python3 $HOME/.gbrain/hooks/signal-detector.py",
        "timeout": 120,
        "async": true
      }]
    }]
  }
}
```

`async: true` is critical — the hook runs in background, never blocks the user. `timeout: 120` is generous because Haiku extraction takes 5-30s on a typical session.

4. After editing settings, open `/hooks` in Claude Code once (or restart) so the watcher picks it up.

## How it works (under the hood)

```
Session ends
    ↓
Claude Code fires Stop hook
    ↓
signal-detector.py spawns in background
    ├─ reads JSON event from stdin: { transcript_path, session_id }
    ├─ falls back to newest *.jsonl in ~/.claude/projects/-home-<user>/ if path missing
    ├─ skips if transcript < 2KB
    ├─ extracts last 200 user/assistant turns to plain text
    ├─ truncates to 30k chars (cheap Haiku call)
    ├─ calls Anthropic Haiku with system + extraction prompt
    ├─ robust JSON extraction (finds first balanced {...}, ignores prose/fences)
    ├─ for each signal: gbrain put <slug> with frontmatter (source_session, captured_at)
    └─ writes one-line summary to ~/.gbrain/hooks/signal-detector.log
```

Cost: ~1-3¢ per session at Haiku-4-5 prices for typical 30k-char transcripts.

## Verify it's working

After a real session ends, check:

```bash
tail -3 ~/.gbrain/hooks/signal-detector.log
```

Expected output (one per session):

```
2026-04-27T04:08:03+00:00 [ok:abc123] captured: 3 decisions, 2 insights, 2 entities, 5 concepts (transcript 1432343b)
```

Then list newly-created pages:

```bash
gbrain list -n 10
```

You should see `decisions/...`, `originals/...`, `concepts/...` slugs from the recent session.

## Manually re-run on a past session

Useful if you want to backfill:

```bash
TRANSCRIPT=~/.claude/projects/-home-USER/SESSION-ID.jsonl
echo "{\"transcript_path\":\"$TRANSCRIPT\",\"session_id\":\"manual-backfill\"}" \
  | python3 ~/.gbrain/hooks/signal-detector.py
tail -1 ~/.gbrain/hooks/signal-detector.log
```

## Tuning

Open `~/.gbrain/hooks/signal-detector.py` and edit:

- `MIN_TRANSCRIPT_BYTES` (default 2000) — raise to skip more short sessions
- `MAX_TRANSCRIPT_CHARS` (default 30000) — raise for longer history (more $ to Haiku)
- `MODEL` (default `claude-haiku-4-5-20251001`) — swap to Sonnet if you want richer extraction at higher cost
- `EXTRACTION_PROMPT` — refine what counts as a signal for your domain

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Log says `[skip:...] no ANTHROPIC_API_KEY` | Script can't find the key | Add `ANTHROPIC_API_KEY=sk-ant-...` to `~/gbrain/.env`, or export in shell |
| Log says `[skip:...] no transcript found` | Wrong projects path | Edit `PROJECTS_DIR` in script to your actual `~/.claude/projects/<dir>/` |
| Log says `[skip:...] no_json_object_found` | Haiku returned prose instead of JSON | The script saves the raw response to `last-extraction-raw.txt` — inspect, then strengthen the prompt or switch to Sonnet |
| No log file appears | Hook didn't fire | Check `claude --debug` output, then run `/hooks` to reload settings, or restart Claude Code |
| Pages not appearing in GBrain | `gbrain put` is failing silently | Run the script manually with a known-good transcript and check exit code |

## Comparison with OpenClaw signal-detector

| | OpenClaw signal-detector | Claude Code Stop hook (this) |
|---|---|---|
| When it fires | Every inbound Telegram message | After every Claude Code session ends |
| Where it runs | Inside the OpenClaw agent loop | As a Stop hook spawned by Claude Code |
| Model | Whatever the OpenClaw agent is configured to use | Haiku 4.5 (cheap, fast) |
| Capture latency | Real-time (during conversation) | End-of-session (batch, ~5-30s) |
| Output | Same: decisions/originals/people/companies/concepts pages | Same |
| Shared brain | Yes (writes to same Postgres) | Yes (writes to same Postgres) |

Both write to the SAME GBrain Postgres → unified memory across all entry points.

## See also

- [SKILL.md](SKILL.md) — the `/gbrain` health dashboard
- [INSTALL.md](INSTALL.md) — bootstrap installer
- [CONNECT.md](CONNECT.md) — multi-client compatibility matrix
- [ARCHITECTURE.md](ARCHITECTURE.md) — end-to-end audit
- OpenClaw signal-detector skill (canonical reference): [`~/.openclaw/skills/signal-detector/SKILL.md`](https://github.com/garrytan/gbrain) (pattern source)
