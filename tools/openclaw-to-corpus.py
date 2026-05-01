#!/usr/bin/env python3
"""
openclaw-to-corpus: convert OpenClaw JSONL sessions → clean .txt transcripts
that gbrain dream synthesize can read.

Handles two formats:
  - v3 sessions: 'message' records with role+content
  - trajectory: 'prompt.submitted' + 'model.completed' wrapped records

Output: ~/.gbrain/corpus/openclaw-sessions/YYYY-MM-DD-<agent>-<id8>.txt
Idempotent: skips files already converted (content_hash match).
"""

import json, os, sys, hashlib, re
from pathlib import Path

HOME = os.path.expanduser("~")
SOURCE_DIRS = [
    f"{HOME}/.openclaw/agents/clawdex/sessions",
    f"{HOME}/.openclaw/agents/main/sessions",
    f"{HOME}/.openclaw/agents/midas/sessions",
    f"{HOME}/.openclaw/agents/pixel/sessions",
]
OUTPUT_DIR = f"{HOME}/.gbrain/corpus/openclaw-sessions"
INDEX_FILE = f"{OUTPUT_DIR}/.converted-index.json"

MIN_CHARS = 2000
MAX_PREVIEW = 100_000  # cap any single transcript


def hash_content(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def extract_text_content(content):
    """Normalize content (str or list-of-dicts) into plain text."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for c in content:
            if isinstance(c, dict):
                if c.get("type") == "text":
                    parts.append(c.get("text", ""))
                elif c.get("type") == "tool_use":
                    name = c.get("name", "?")
                    parts.append(f"[tool_use: {name}]")
                elif c.get("type") == "tool_result":
                    parts.append(f"[tool_result]")
        return "\n".join(parts)
    return str(content)


def convert_v3_session(jsonl_path):
    """v3 format: 'message' records with role + content."""
    lines = []
    started_at = None
    for line in jsonl_path.open():
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") == "session" and started_at is None:
            started_at = d.get("timestamp", "")[:10]
        if d.get("type") != "message":
            continue
        msg = d.get("message", {})
        role = msg.get("role", "?")
        text = extract_text_content(msg.get("content", ""))
        if text.strip():
            lines.append(f"[{role.upper()}]\n{text.strip()}\n")
    return ("\n".join(lines), started_at)


def convert_trajectory_session(jsonl_path):
    """Trajectory format: 'prompt.submitted' + 'model.completed'."""
    lines = []
    started_at = None
    for line in jsonl_path.open():
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") == "session.started" and started_at is None:
            started_at = d.get("ts", "")[:10]
        if d.get("type") == "prompt.submitted":
            data = d.get("data", {})
            prompt = data.get("prompt", "")
            if prompt:
                lines.append(f"[USER]\n{prompt}\n")
        elif d.get("type") == "model.completed":
            data = d.get("data", {})
            response = data.get("response") or data.get("text") or ""
            if isinstance(response, dict):
                response = extract_text_content(response.get("content", ""))
            elif isinstance(response, list):
                response = extract_text_content(response)
            if response and len(response) > 50:
                lines.append(f"[ASSISTANT]\n{response.strip()}\n")
    return ("\n".join(lines), started_at)


def detect_format(jsonl_path):
    """Peek first line to choose converter."""
    try:
        with jsonl_path.open() as f:
            first = json.loads(f.readline())
        if "traceSchema" in first:
            return "trajectory"
        if first.get("type") == "session" and first.get("version", 0) >= 3:
            return "v3"
    except Exception:
        pass
    return "v3"  # default


def load_index():
    if os.path.exists(INDEX_FILE):
        try:
            return json.load(open(INDEX_FILE))
        except Exception:
            pass
    return {}


def save_index(idx):
    os.makedirs(os.path.dirname(INDEX_FILE), exist_ok=True)
    with open(INDEX_FILE, "w") as f:
        json.dump(idx, f, indent=2)


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    index = load_index()

    written = skipped_short = skipped_existing = errors = 0

    for src_dir in SOURCE_DIRS:
        if not os.path.isdir(src_dir):
            continue
        agent = os.path.basename(os.path.dirname(src_dir))
        for entry in sorted(os.listdir(src_dir)):
            if "deleted" in entry or ".checkpoint." in entry:
                continue
            if not entry.endswith(".jsonl"):
                continue
            full = Path(src_dir) / entry
            try:
                size = full.stat().st_size
                if size < 2000:
                    continue
            except Exception:
                continue

            try:
                fmt = detect_format(full)
                if fmt == "v3":
                    text, date = convert_v3_session(full)
                else:
                    text, date = convert_trajectory_session(full)
            except Exception as e:
                errors += 1
                continue

            text = text[:MAX_PREVIEW]
            if len(text) < MIN_CHARS:
                skipped_short += 1
                continue

            content_hash = hash_content(text)
            session_id = entry.split(".")[0][:8]
            date = date or "unknown"
            out_name = f"{date}-{agent}-{session_id}.txt"
            out_path = Path(OUTPUT_DIR) / out_name

            # Idempotency: skip if content_hash matches index
            key = str(full)
            if index.get(key) == content_hash and out_path.exists():
                skipped_existing += 1
                continue

            with open(out_path, "w") as f:
                f.write(text)
            index[key] = content_hash
            written += 1

    save_index(index)
    print(f"Wrote: {written}, skipped (existing): {skipped_existing}, skipped (short): {skipped_short}, errors: {errors}")
    print(f"Output dir: {OUTPUT_DIR}")
    print(f"Total .txt files: {len(list(Path(OUTPUT_DIR).glob('*.txt')))}")


if __name__ == "__main__":
    main()
