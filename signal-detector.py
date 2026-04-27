#!/usr/bin/env python3
"""
Claude Code Stop hook → ambient signal capture into GBrain.

Mirrors OpenClaw's signal-detector skill pattern: extracts ORIGINAL THINKING +
ENTITY MENTIONS from the just-finished session and writes selective pages to
GBrain. Does NOT save the full transcript (that would be noise).

Wire-up: see ~/.gbrain/hooks/README.md
Trigger: Claude Code Stop event passes JSON event on stdin.
"""

from __future__ import annotations
import json, os, sys, subprocess, urllib.request, urllib.error
from datetime import datetime, timezone
from pathlib import Path

# ─── Config ──────────────────────────────────────────────
HOME = Path.home()
GBRAIN_BIN = os.environ.get("GBRAIN_BIN", str(HOME / ".bun/bin/gbrain"))
ENV_FILE = Path(os.environ.get("GBRAIN_ENV_FILE", str(HOME / "gbrain/.env")))
LOG_FILE = HOME / ".gbrain/hooks/signal-detector.log"
# Project transcript dir: Claude Code stores per-cwd. Detect dynamically.
def _detect_projects_dir() -> Path:
    base = HOME / ".claude/projects"
    if not base.is_dir(): return base
    cands = [p for p in base.iterdir() if p.is_dir()]
    if not cands: return base
    return max(cands, key=lambda p: max((j.stat().st_mtime for j in p.glob("*.jsonl")), default=0))
PROJECTS_DIR = _detect_projects_dir()
MIN_TRANSCRIPT_BYTES = 2000
MAX_TRANSCRIPT_CHARS = 30000
MODEL = "claude-haiku-4-5-20251001"

def log(msg: str) -> None:
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with LOG_FILE.open("a") as f:
        f.write(f"{datetime.now(timezone.utc).isoformat(timespec='seconds')} {msg}\n")

def load_env_file(path: Path) -> dict:
    env = {}
    if not path.exists(): return env
    for line in path.read_text(errors="ignore").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line: continue
        k, _, v = line.partition("=")
        env[k.strip()] = v.strip().strip('"').strip("'")
    return env

def find_transcript(event: dict) -> Path | None:
    p = event.get("transcript_path") or ""
    if p and Path(p).is_file(): return Path(p)
    candidates = sorted(PROJECTS_DIR.glob("*.jsonl"), key=lambda x: x.stat().st_mtime, reverse=True)
    return candidates[0] if candidates else None

def extract_turns(transcript: Path, max_turns: int = 200) -> str:
    turns = []
    for line in transcript.read_text(errors="ignore").splitlines():
        line = line.strip()
        if not line: continue
        try: ev = json.loads(line)
        except: continue
        msg = ev.get("message") or {}
        role = msg.get("role")
        content = msg.get("content")
        if not (role and content): continue
        if isinstance(content, list):
            text = "\n".join(c.get("text","") for c in content if isinstance(c,dict) and c.get("type")=="text").strip()
        elif isinstance(content, str):
            text = content
        else:
            text = ""
        if text:
            turns.append(f"[{role}]\n{text}\n")
    return ("\n---\n".join(turns[-max_turns:]))[:MAX_TRANSCRIPT_CHARS]

SYSTEM_PROMPT = """You are signal-detector. Your ONLY job is to output a JSON object.
You output NOTHING else. No prose. No greeting. No analysis. No markdown.
Your output MUST start with { and end with }. Anything else is failure."""

EXTRACTION_PROMPT = """Extract structured signals from this Claude Code session transcript.

Schema (output ONLY this JSON object):
{
  "decisions":   [{"slug":"decisions/<kebab>","title":"...","summary":"<2-4 sentences>"}],
  "insights":    [{"slug":"originals/<kebab>","title":"...","summary":"<user's exact phrasing>"}],
  "entities":    [{"slug":"people/<kebab>|companies/<kebab>","title":"...","summary":"..."}],
  "concepts":    [{"slug":"concepts/<kebab>","title":"...","summary":"..."}],
  "skip_reason": null
}

Rules:
- If session is purely operational (only commands, no decisions/insights), return all empty arrays and skip_reason="operational".
- Capture USER'S exact phrasing in insights — do not paraphrase.
- Only emit signals worth keeping forever. Skip noise.
- Slugs MUST be kebab-case, max 60 chars, alphanumeric + hyphens only.
- Total signals across all categories: at most 8.

Transcript follows after the marker. Output ONLY the JSON object.

=== TRANSCRIPT START ===
"""

def call_haiku(api_key: str, transcript: str) -> dict:
    body = json.dumps({
        "model": MODEL,
        "max_tokens": 2000,
        "system": SYSTEM_PROMPT,
        "messages": [{"role":"user","content": EXTRACTION_PROMPT + transcript + "\n=== TRANSCRIPT END ===\n\nNow output the JSON object:"}]
    }).encode()
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=body,
        headers={
            "Content-Type":"application/json",
            "x-api-key": api_key,
            "anthropic-version":"2023-06-01"
        }
    )
    try:
        resp = urllib.request.urlopen(req, timeout=90).read().decode()
    except urllib.error.HTTPError as e:
        return {"skip_reason": f"http_{e.code}", "decisions":[], "insights":[], "entities":[], "concepts":[]}
    except Exception as e:
        return {"skip_reason": f"net_error: {e}", "decisions":[], "insights":[], "entities":[], "concepts":[]}
    text = json.loads(resp)["content"][0]["text"]
    # Robust JSON extraction: find first {...} balanced block, ignore prose/fences.
    json_text = _extract_first_json_object(text)
    if not json_text:
        (Path.home() / ".gbrain/hooks/last-extraction-raw.txt").write_text(text[:8000])
        return {"skip_reason": "no_json_object_found (raw saved to last-extraction-raw.txt)",
                "decisions":[], "insights":[], "entities":[], "concepts":[]}
    try:
        return json.loads(json_text)
    except Exception as e:
        (Path.home() / ".gbrain/hooks/last-extraction-raw.txt").write_text(text[:8000])
        return {"skip_reason": f"parse_error: {e}",
                "decisions":[], "insights":[], "entities":[], "concepts":[]}


def _extract_first_json_object(text: str) -> str | None:
    """Find first balanced {...} block in text. Skip strings (handle escapes)."""
    start = text.find("{")
    if start < 0: return None
    depth = 0
    in_string = False
    escape = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escape: escape = False
            elif ch == "\\": escape = True
            elif ch == '"': in_string = False
        else:
            if ch == '"': in_string = True
            elif ch == "{": depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0: return text[start:i+1]
    return None

def write_to_gbrain(slug: str, title: str, body: str, session_id: str) -> bool:
    page = (
        f"---\n"
        f"type: {slug.split('/',1)[0]}\n"
        f"title: {title}\n"
        f"source_session: {session_id}\n"
        f"captured_at: {datetime.now(timezone.utc).isoformat(timespec='seconds')}\n"
        f"---\n\n{body}\n"
    )
    try:
        r = subprocess.run(
            [GBRAIN_BIN, "put", slug],
            input=page, capture_output=True, text=True, timeout=30
        )
        return r.returncode == 0
    except Exception:
        return False

def main():
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

    # 1. Read event from stdin
    try:
        event = json.loads(sys.stdin.read() or "{}")
    except Exception:
        event = {}

    session_id = event.get("session_id", "unknown")[:36]

    # 2. Load API key
    env = load_env_file(ENV_FILE)
    api_key = os.environ.get("ANTHROPIC_API_KEY") or env.get("ANTHROPIC_API_KEY")
    if not api_key:
        log(f"[skip:{session_id}] no ANTHROPIC_API_KEY")
        return 0

    # 3. Locate transcript
    transcript = find_transcript(event)
    if not transcript:
        log(f"[skip:{session_id}] no transcript found")
        return 0

    bytes_size = transcript.stat().st_size
    if bytes_size < MIN_TRANSCRIPT_BYTES:
        log(f"[skip:{session_id}] transcript too small ({bytes_size}b)")
        return 0

    # 4. Extract turns
    transcript_txt = extract_turns(transcript)
    if not transcript_txt:
        log(f"[skip:{session_id}] empty extraction")
        return 0

    # 5. Call Haiku
    signals = call_haiku(api_key, transcript_txt)
    if signals.get("skip_reason"):
        log(f"[skip:{session_id}] reason={signals['skip_reason']}")
        return 0

    # 6. Write each signal to GBrain
    counts = {"decisions":0, "insights":0, "entities":0, "concepts":0}
    for cat in ("decisions","insights","entities","concepts"):
        for item in (signals.get(cat) or []):
            slug = (item.get("slug") or "").strip()
            title = (item.get("title") or "").strip()
            body = (item.get("summary") or "").strip()
            if slug and title and body and write_to_gbrain(slug, title, body, session_id):
                counts[cat] += 1

    log(f"[ok:{session_id}] captured: {counts['decisions']} decisions, {counts['insights']} insights, {counts['entities']} entities, {counts['concepts']} concepts (transcript {bytes_size}b)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
