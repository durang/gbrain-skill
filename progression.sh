#!/usr/bin/env bash
# progression.sh — track GBrain multi-client setup progression.
# Detects which phases are done, which are pending, and what to do next.
#
# USAGE:
#   bash progression.sh              # status table + next action (markdown to stdout)
#   bash progression.sh --md         # full markdown report (suitable for piping to file)
#   bash progression.sh --save       # save report as page in GBrain
#   bash progression.sh --next       # only show next pending action (terse)
#   bash progression.sh --phase 4A   # detail + tests for one specific phase
#   bash progression.sh --json       # machine-readable
#   bash progression.sh --reset      # clear local progression cache (re-detect from scratch)
#
# Output is Markdown — can be piped to a file or rendered in any MD viewer.
# Auto-detects state from the actual filesystem; no claims, evidence-based.

set -uo pipefail

MODE="status"
PHASE_FILTER=""
for arg in "$@"; do
  case "$arg" in
    --md)    MODE="md" ;;
    --save)  MODE="save" ;;
    --next)  MODE="next" ;;
    --json)  MODE="json" ;;
    --reset) rm -f "$HOME/.gbrain/.progression.json" 2>/dev/null; echo "Cache cleared."; exit 0 ;;
    --phase) MODE="phase" ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# //; s/^#//'
      exit 0 ;;
    *) [ "$MODE" = "phase" ] && PHASE_FILTER="$arg" ;;
  esac
done

# ─── State helpers ────────────────────────────────
HOME_DIR="$HOME"
have() { command -v "$1" >/dev/null 2>&1; }
exists() { [ -e "$1" ]; }

# ─── Phase detection ──────────────────────────────
# Each phase has: id, name, description, detect (returns 0=done 1=pending), why, next, tests

declare -A PHASE_NAMES=(
  [0]="GBrain CLI installed"
  [1]="Brain backend connected"
  [2]="Claude Code MCP wired"
  [3]="Ambient capture (Stop hook)"
  [4]="Multi-machine shared brain"
  [5A]="Phase 4A — HTTP wrapper local"
  [5B]="Phase 4B — Public tunnel + tokens"
  [5C]="Phase 4C — claude.ai web Cowork"
  [5D]="Phase 4D — PR upstream"
)

declare -A PHASE_WHY=(
  [0]="The CLI is the gateway to everything else."
  [1]="Without a brain backend, captures have nowhere to go."
  [2]="Lets the model query/write GBrain during conversations."
  [3]="Captures decisions/originals/entities at end of every session."
  [4]="Same brain accessible from EC2, Mac, any other machine."
  [5A]="HTTP wrapper enables Desktop/Cowork/mobile (no stdio there)."
  [5B]="Public URL with Bearer auth so non-tailnet clients can reach the wrapper."
  [5C]="Cowork shares brain with all other clients (depends on plan tier)."
  [5D]="Contribute the wrapper upstream as native gbrain serve --http."
)

# Detect functions return 0 (done), 1 (pending), 2 (partial/needs verify)
detect_phase() {
  case "$1" in
    0)
      have gbrain || return 1
      VER=$(gbrain --version 2>&1 | head -1 | awk '{print $NF}')
      case "$VER" in 0.2*|0.3*|0.4*) return 0 ;; *) return 2 ;; esac
      ;;
    1)
      [ -f "$HOME_DIR/.gbrain/config.json" ] || return 1
      python3 -c "import json,sys; d=json.load(open('$HOME_DIR/.gbrain/config.json')); sys.exit(0 if (d.get('engine') and (d.get('database_url') or d.get('engine')=='pglite')) else 1)" 2>/dev/null
      ;;
    2)
      [ -f "$HOME_DIR/.claude.json" ] || return 1
      python3 -c "import json,sys; d=json.load(open('$HOME_DIR/.claude.json')); sys.exit(0 if 'gbrain' in d.get('mcpServers',{}) else 1)" 2>/dev/null
      ;;
    3)
      [ -x "$HOME_DIR/.gbrain/hooks/signal-detector.py" ] || return 1
      [ -f "$HOME_DIR/.claude/settings.json" ] || return 1
      jq -e '.hooks.Stop[].hooks[] | select(.command | contains("signal-detector"))' "$HOME_DIR/.claude/settings.json" >/dev/null 2>&1
      ;;
    4)
      # Heuristic: shared if config.json points to a non-pglite engine AND >1 source_session
      [ -f "$HOME_DIR/.gbrain/config.json" ] || return 1
      ENGINE=$(python3 -c "import json; print(json.load(open('$HOME_DIR/.gbrain/config.json'))['engine'])" 2>/dev/null)
      [ "$ENGINE" = "postgres" ] || return 2
      # Check if log has captures from >1 sessions (rough multi-machine signal)
      if [ -f "$HOME_DIR/.gbrain/hooks/signal-detector.log" ]; then
        SESSIONS=$(grep -oE '\[[a-z]+:[a-f0-9-]{12,}' "$HOME_DIR/.gbrain/hooks/signal-detector.log" | sort -u | wc -l)
        [ "$SESSIONS" -ge 2 ] && return 0 || return 2
      fi
      return 2
      ;;
    5A)
      [ -d "$HOME_DIR/gbrain-http-wrapper" ] && [ -f "$HOME_DIR/gbrain-http-wrapper/src/server.ts" ] && return 0
      return 1
      ;;
    5B)
      tailscale funnel status 2>&1 | grep -q "/mcp" && return 0
      return 1
      ;;
    5C)
      [ -f "$HOME_DIR/.gbrain/.cowork-connected" ] && return 0
      return 1
      ;;
    5D)
      [ -f "$HOME_DIR/.gbrain/.pr-submitted" ] && return 0
      return 1
      ;;
  esac
}

# Next-step instruction per phase
declare -A PHASE_NEXT=(
  [0]="bun install -g github:garrytan/gbrain"
  [1]="Either: gbrain init --pglite  OR  paste a Postgres URL into ~/.gbrain/config.json"
  [2]="claude mcp add gbrain -- gbrain serve  (or run install-capture.sh)"
  [3]="bash <(curl -fsSL https://raw.githubusercontent.com/durang/gbrain-skill/master/install-capture.sh)"
  [4]="Install gbrain on a 2nd machine pointing at the same database_url, run a real session, then re-check"
  [5A]="Tell your AI assistant: \"go Phase 4A ambos protocolos\" (or solo streamable). Builds gbrain-http-wrapper/. ~2-3 hrs assistant work."
  [5B]="After 4A done: tailscale funnel --bg --set-path /mcp 8787 + bun run gbrain/src/commands/auth.ts create"
  [5C]="After 4B done: in claude.ai/settings/connectors paste your Tailscale URL + Bearer token"
  [5D]="After 4A validated: open PR at https://github.com/garrytan/gbrain with the wrapper as native gbrain serve --http"
)

# Verification tests per phase (Markdown bullet form, evaluated on next run)
declare -A PHASE_TESTS=(
  [0]="\`gbrain --version\` returns 0.2x.x (canonical Garry Tan); not 1.x.x (npm squat)"
  [1]="\`gbrain doctor --fast\` health score >= 70"
  [2]="\`claude mcp list\` shows gbrain ✓ Connected"
  [3]="A real Claude Code session ends → \`tail -1 ~/.gbrain/hooks/signal-detector.log\` shows new [ok:<sid>] line"
  [4]="From a 2nd machine, \`gbrain get\` retrieves a page written from the 1st machine"
  [5A]="\`curl http://localhost:8787/health\` returns 200 OK"
  [5B]="\`curl https://your-tailscale-url/mcp/health\` returns 200 OK from outside tailnet"
  [5C]="claude.ai web Cowork can call a gbrain MCP tool successfully"
  [5D]="PR merged or open at github.com/garrytan/gbrain"
)

# ─── Render ────────────────────────────────────────
PHASE_ORDER=(0 1 2 3 4 5A 5B 5C 5D)

PHASE_STATUSES=()
DONE_COUNT=0
PARTIAL_COUNT=0
PENDING_COUNT=0
NEXT_PENDING=""

for p in "${PHASE_ORDER[@]}"; do
  detect_phase "$p"
  RC=$?
  case "$RC" in
    0) PHASE_STATUSES+=("$p:done");    DONE_COUNT=$((DONE_COUNT+1)) ;;
    2) PHASE_STATUSES+=("$p:partial"); PARTIAL_COUNT=$((PARTIAL_COUNT+1)); [ -z "$NEXT_PENDING" ] && NEXT_PENDING="$p" ;;
    *) PHASE_STATUSES+=("$p:pending"); PENDING_COUNT=$((PENDING_COUNT+1)); [ -z "$NEXT_PENDING" ] && NEXT_PENDING="$p" ;;
  esac
done

icon_for() {
  case "$1" in
    done)    echo "✅" ;;
    partial) echo "🟡" ;;
    pending) echo "⏳" ;;
    *)       echo "—" ;;
  esac
}

# ─── Output dispatchers ────────────────────────────
print_status_table() {
  echo "| # | Phase | Status | Why it matters |"
  echo "|---|---|---|---|"
  for entry in "${PHASE_STATUSES[@]}"; do
    p="${entry%%:*}"; st="${entry##*:}"
    echo "| $p | ${PHASE_NAMES[$p]} | $(icon_for "$st") $st | ${PHASE_WHY[$p]} |"
  done
}

print_phase_detail() {
  local p="$1"
  local entry st
  for entry in "${PHASE_STATUSES[@]}"; do
    [[ "$entry" == "$p:"* ]] && st="${entry##*:}"
  done
  echo "## Phase $p — ${PHASE_NAMES[$p]}"
  echo ""
  echo "**Status:** $(icon_for "$st") $st"
  echo ""
  echo "**Why it matters:** ${PHASE_WHY[$p]}"
  echo ""
  echo "**Next action:** \`${PHASE_NEXT[$p]}\`"
  echo ""
  echo "**Verification test:**"
  echo "- ${PHASE_TESTS[$p]}"
  echo ""
}

print_full_md() {
  echo "# GBrain Multi-Client Progression"
  echo ""
  echo "_Generated: $(date -u +%FT%TZ) — auto-detected from filesystem_"
  echo ""
  echo "**Summary:** $DONE_COUNT done · $PARTIAL_COUNT partial · $PENDING_COUNT pending (out of ${#PHASE_ORDER[@]})"
  echo ""
  echo "## Status overview"
  echo ""
  print_status_table
  echo ""
  if [ -n "$NEXT_PENDING" ]; then
    echo "## ⚡ Next action"
    echo ""
    print_phase_detail "$NEXT_PENDING"
  else
    echo "## 🏆 All phases complete!"
    echo ""
    echo "You've built the full multi-client GBrain stack. If something breaks, run:"
    echo ""
    echo "    bash <(curl -fsSL https://raw.githubusercontent.com/durang/gbrain-skill/master/capture-doctor.sh)"
    echo ""
  fi
  echo "## All phases (detail)"
  echo ""
  for p in "${PHASE_ORDER[@]}"; do
    print_phase_detail "$p"
  done
  echo "---"
  echo "_To re-check: \`bash progression.sh\`. To save into GBrain: \`bash progression.sh --save\`._"
}

print_next_terse() {
  if [ -z "$NEXT_PENDING" ]; then
    echo "✅ All phases complete."
    return 0
  fi
  echo "Next: Phase $NEXT_PENDING — ${PHASE_NAMES[$NEXT_PENDING]}"
  echo "Why: ${PHASE_WHY[$NEXT_PENDING]}"
  echo "Do:  ${PHASE_NEXT[$NEXT_PENDING]}"
  echo "Test: ${PHASE_TESTS[$NEXT_PENDING]}"
}

print_json() {
  echo "{"
  echo "  \"generated\": \"$(date -u +%FT%TZ)\","
  echo "  \"summary\": { \"done\": $DONE_COUNT, \"partial\": $PARTIAL_COUNT, \"pending\": $PENDING_COUNT },"
  echo "  \"next\": \"$NEXT_PENDING\","
  echo "  \"phases\": ["
  N=${#PHASE_STATUSES[@]}
  i=0
  for entry in "${PHASE_STATUSES[@]}"; do
    p="${entry%%:*}"; st="${entry##*:}"
    [ $i -gt 0 ] && echo ","
    printf "    {\"id\": \"%s\", \"name\": \"%s\", \"status\": \"%s\"}" "$p" "${PHASE_NAMES[$p]}" "$st"
    i=$((i+1))
  done
  echo ""
  echo "  ]"
  echo "}"
}

case "$MODE" in
  md|status)
    print_full_md ;;
  next)
    print_next_terse ;;
  json)
    print_json ;;
  phase)
    [ -z "$PHASE_FILTER" ] && { echo "Usage: --phase <id>" >&2; exit 1; }
    print_phase_detail "$PHASE_FILTER"
    ;;
  save)
    if ! have gbrain; then echo "gbrain CLI not available — can't --save" >&2; exit 2; fi
    SLUG="status/gbrain-progression-$(date +%F)"
    print_full_md | gbrain put "$SLUG" >/dev/null 2>&1 \
      && echo "✓ Saved to GBrain: $SLUG (read with: gbrain get $SLUG)" \
      || { echo "✗ gbrain put failed" >&2; exit 2; }
    ;;
esac
