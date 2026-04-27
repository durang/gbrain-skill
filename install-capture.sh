#!/usr/bin/env bash
# Install ambient capture for Claude Code (signal-detector pattern as Stop hook).
# Idempotent. Documented in CAPTURE.md.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/durang/gbrain-skill/master/install-capture.sh)

set -euo pipefail

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_RESET=$'\033[0m'
ok()   { echo "${C_OK}✓${C_RESET} $*"; }
warn() { echo "${C_WARN}⚠${C_RESET} $*"; }
err()  { echo "${C_ERR}✗${C_RESET} $*" >&2; }

HOOKS_DIR="$HOME/.gbrain/hooks"
SCRIPT_DST="$HOOKS_DIR/signal-detector.py"
SETTINGS="$HOME/.claude/settings.json"

mkdir -p "$HOOKS_DIR"

# 1. Pull signal-detector.py from this repo's master
echo "→ Downloading signal-detector.py..."
RAW_URL="https://raw.githubusercontent.com/durang/gbrain-skill/master/signal-detector.py"
curl -fsSL "$RAW_URL" -o "$SCRIPT_DST"
chmod 700 "$SCRIPT_DST"
ok "Installed $SCRIPT_DST"

# 2. Verify ANTHROPIC_API_KEY is reachable
echo "→ Checking ANTHROPIC_API_KEY..."
ENV_FILE="${GBRAIN_ENV_FILE:-$HOME/gbrain/.env}"
if [ -f "$ENV_FILE" ] && grep -q "^ANTHROPIC_API_KEY=" "$ENV_FILE"; then
  ok "Found in $ENV_FILE"
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  ok "Found in shell env"
else
  warn "ANTHROPIC_API_KEY not found — capture will skip until you add it"
  warn "Add to $ENV_FILE: ANTHROPIC_API_KEY=sk-ant-..."
fi

# 3. Wire Stop hook into ~/.claude/settings.json
echo "→ Wiring Stop hook into $SETTINGS..."
if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
fi

cp "$SETTINGS" "$SETTINGS.bak-pre-capture-$(date +%s)"

python3 - <<PY
import json, os, tempfile, sys
p = "$SETTINGS"
with open(p) as f: d = json.load(f)
d.setdefault("hooks", {}).setdefault("Stop", [])

new_cmd = "python3 $SCRIPT_DST"
existing = []
for entry in d["hooks"]["Stop"]:
    for h in entry.get("hooks", []):
        if h.get("type") == "command":
            existing.append(h.get("command",""))

if new_cmd in existing:
    print("Already wired — skipping merge.")
else:
    d["hooks"]["Stop"].append({
        "matcher": "",
        "hooks": [{
            "type": "command",
            "command": new_cmd,
            "timeout": 120,
            "async": True
        }]
    })

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p))
with os.fdopen(fd, "w") as f:
    json.dump(d, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, p)
print("Settings written.")
PY

ok "Stop hook wired"

# 4. Verify with jq
if command -v jq >/dev/null 2>&1; then
  if jq -e '.hooks.Stop[].hooks[] | select(.command | contains("signal-detector"))' "$SETTINGS" >/dev/null 2>&1; then
    ok "jq validation passed"
  else
    err "jq validation FAILED — settings.json may be malformed"
    exit 1
  fi
fi

# 5. Smoke test the script (won't actually call Haiku unless transcript is long enough)
echo "→ Smoke testing script..."
echo '{}' | python3 "$SCRIPT_DST" || true
LAST_LOG=$(tail -1 "$HOOKS_DIR/signal-detector.log" 2>/dev/null || echo "")
if [ -n "$LAST_LOG" ]; then
  ok "Script ran. Last log: $LAST_LOG"
fi

echo ""
echo "════════════════════════════════════════════"
echo "  ✅ Ambient capture installed"
echo "════════════════════════════════════════════"
echo ""
echo "  - Script: $SCRIPT_DST"
echo "  - Settings: $SETTINGS (Stop hook async)"
echo "  - Log: $HOOKS_DIR/signal-detector.log"
echo ""
echo "  Open /hooks in Claude Code (or restart) to load the new hook."
echo "  Documentation: CAPTURE.md in https://github.com/durang/gbrain-skill"
echo ""
