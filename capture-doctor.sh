#!/usr/bin/env bash
# capture-doctor.sh — health check + auto-repair for the Claude Code capture hook.
#
# Usage:
#   bash capture-doctor.sh           # check only (no changes)
#   bash capture-doctor.sh --fix     # check + auto-fix common issues
#   bash capture-doctor.sh --verbose # extra detail per check
#
# Exit codes:
#   0 = all checks passed
#   1 = one or more checks failed (run with --fix to repair)
#   2 = critical failure that --fix can't repair (manual intervention)

set -uo pipefail   # NOT -e — we want to keep checking after a failure

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
[ -t 1 ] || { C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_BOLD=""; C_RESET=""; }

ok()    { echo "${C_OK}✓${C_RESET} $*"; }
warn()  { echo "${C_WARN}⚠${C_RESET} $*"; }
err()   { echo "${C_ERR}✗${C_RESET} $*" >&2; }
hdr()   { echo ""; echo "${C_BOLD}── $* ──${C_RESET}"; }

FIX=0
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --fix) FIX=1 ;;
    --verbose|-v) VERBOSE=1 ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# //; s/^#//'
      exit 0 ;;
  esac
done

FAILURES=0
FIXED=0
CRITICAL=0

check() {
  local label="$1"; shift
  local cmd="$*"
  if eval "$cmd" >/dev/null 2>&1; then
    ok "$label"
    return 0
  else
    err "$label"
    FAILURES=$((FAILURES+1))
    return 1
  fi
}

repair() {
  local label="$1"; shift
  local cmd="$*"
  if [ "$FIX" = "0" ]; then
    warn "  Run with --fix to: $label"
    return 1
  fi
  echo "  ${C_DIM}→ Fixing: $label${C_RESET}"
  if eval "$cmd"; then
    ok "  Fixed: $label"
    FIXED=$((FIXED+1))
    return 0
  else
    err "  Repair failed: $label"
    CRITICAL=$((CRITICAL+1))
    return 1
  fi
}

echo "════════════════════════════════════════════════════════"
echo "  Claude Code Capture — Health Check"
[ "$FIX" = "1" ] && echo "  Mode: CHECK + AUTO-FIX" || echo "  Mode: CHECK ONLY"
echo "════════════════════════════════════════════════════════"

# ── L1: gbrain CLI present and canonical ──────────
hdr "L1 — gbrain CLI"
if command -v gbrain >/dev/null 2>&1; then
  GVER=$(gbrain --version 2>&1 | head -1 | awk '{print $NF}')
  case "$GVER" in
    0.2*|0.3*|0.4*) ok "gbrain $GVER (canonical)" ;;
    1.*|2.*)
      err "gbrain $GVER — this is the squatted npm package, not Garry Tan's"
      FAILURES=$((FAILURES+1))
      repair "reinstall canonical gbrain from GitHub" \
        "bun remove -g gbrain 2>/dev/null; rm -f \$HOME/.bun/bin/gbrain; bun install -g github:garrytan/gbrain"
      ;;
    *) warn "gbrain $GVER (unexpected version)"; FAILURES=$((FAILURES+1)) ;;
  esac
else
  err "gbrain CLI not in PATH"
  FAILURES=$((FAILURES+1))
  CRITICAL=$((CRITICAL+1))
fi

# ── L2: gbrain config points at a brain ───────────
hdr "L2 — Brain config"
CFG="$HOME/.gbrain/config.json"
if [ -f "$CFG" ]; then
  if python3 -c "import json; d=json.load(open('$CFG')); assert d.get('engine') and (d.get('database_url') or d.get('engine')=='pglite')" 2>/dev/null; then
    ENGINE=$(python3 -c "import json; print(json.load(open('$CFG')).get('engine','?'))")
    ok "config.json valid (engine=$ENGINE)"
  else
    err "config.json malformed"
    FAILURES=$((FAILURES+1))
  fi
else
  err "config.json missing"
  FAILURES=$((FAILURES+1))
  warn "  Create with: gbrain init --pglite  OR  paste a database_url"
fi

# ── L3: signal-detector.py present and executable ──
hdr "L3 — Capture script"
SCRIPT="$HOME/.gbrain/hooks/signal-detector.py"
if [ -x "$SCRIPT" ]; then
  ok "$SCRIPT (executable)"
  if python3 -c "import py_compile; py_compile.compile('$SCRIPT', doraise=True)" 2>/dev/null; then
    ok "Python syntax valid"
  else
    err "Python syntax error"
    FAILURES=$((FAILURES+1))
    repair "redownload signal-detector.py from upstream" \
      "curl -fsSL https://raw.githubusercontent.com/durang/gbrain-skill/master/signal-detector.py -o '$SCRIPT' && chmod 700 '$SCRIPT'"
  fi
  if [ "$VERBOSE" = "1" ]; then
    echo "  ${C_DIM}Size: $(stat -c%s "$SCRIPT" 2>/dev/null || stat -f%z "$SCRIPT") bytes${C_RESET}"
  fi
else
  err "signal-detector.py missing or not executable"
  FAILURES=$((FAILURES+1))
  repair "install signal-detector.py" \
    "mkdir -p \$HOME/.gbrain/hooks && curl -fsSL https://raw.githubusercontent.com/durang/gbrain-skill/master/signal-detector.py -o '$SCRIPT' && chmod 700 '$SCRIPT'"
fi

# ── L4: Stop hook wired in settings.json ──────────
hdr "L4 — Stop hook in ~/.claude/settings.json"
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  if jq -e '.hooks.Stop[].hooks[] | select(.type=="command") | select(.command | contains("signal-detector"))' "$SETTINGS" >/dev/null 2>&1; then
    ok "Stop hook entry present"
    # Check async flag
    if jq -e '.hooks.Stop[].hooks[] | select(.command | contains("signal-detector")) | select(.async==true)' "$SETTINGS" >/dev/null 2>&1; then
      ok "async: true (won't block user)"
    else
      warn "Stop hook missing async:true — may block user"
      FAILURES=$((FAILURES+1))
    fi
  else
    err "Stop hook NOT wired"
    FAILURES=$((FAILURES+1))
    repair "wire Stop hook into settings.json" \
      "bash <(curl -fsSL https://raw.githubusercontent.com/durang/gbrain-skill/master/install-capture.sh)"
  fi
else
  err "$SETTINGS missing"
  FAILURES=$((FAILURES+1))
fi

# ── L5: Auth available (subscription preferred) ─────
hdr "L5 — Auth mode"
if command -v claude >/dev/null 2>&1; then
  ok "claude CLI found ($(command -v claude)) — capture will use Pro/Max subscription (\$0)"
else
  ENV_FILE="${GBRAIN_ENV_FILE:-$HOME/gbrain/.env}"
  if [ -f "$ENV_FILE" ] && grep -q "^ANTHROPIC_API_KEY=" "$ENV_FILE"; then
    ok "ANTHROPIC_API_KEY in $ENV_FILE — fallback API mode (~1-3¢/session)"
  elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    ok "ANTHROPIC_API_KEY in shell env — fallback API mode"
  else
    err "Neither claude CLI nor ANTHROPIC_API_KEY available — capture will skip"
    FAILURES=$((FAILURES+1))
    warn "  Install Claude Code:  npm i -g @anthropic-ai/claude-code"
    warn "  Or set:               ANTHROPIC_API_KEY in $ENV_FILE"
  fi
fi

# ── L6: Recent capture log activity ──────────────
hdr "L6 — Recent capture log (last 24h)"
LOG="$HOME/.gbrain/hooks/signal-detector.log"
if [ -f "$LOG" ]; then
  TOTAL=$(wc -l < "$LOG" 2>/dev/null || echo 0)
  RECENT=$(awk -v cutoff="$(date -u -d '24 hours ago' +%FT%T 2>/dev/null || date -u -v-24H +%FT%T)" '$1 >= cutoff' "$LOG" | wc -l)
  OK_COUNT=$(grep -c "\[ok:" "$LOG" 2>/dev/null || echo 0)
  EMPTY_COUNT=$(grep -c "\[empty:" "$LOG" 2>/dev/null || echo 0)
  SKIP_COUNT=$(grep -c "\[skip:" "$LOG" 2>/dev/null || echo 0)
  ok "Log exists ($TOTAL total runs, $RECENT in last 24h)"
  echo "  ${C_DIM}breakdown: $OK_COUNT [ok] / $EMPTY_COUNT [empty] / $SKIP_COUNT [skip]${C_RESET}"
  if [ "$VERBOSE" = "1" ]; then
    echo "  ${C_DIM}Last 3 runs:${C_RESET}"
    tail -3 "$LOG" | sed "s/^/    ${C_DIM}/" | sed "s/$/${C_RESET}/"
  fi
else
  warn "No capture log yet — hook hasn't fired"
fi

# ── L7: Recent write failures ─────────────────────
hdr "L7 — Recent write failures (last 24h)"
WFLOG="$HOME/.gbrain/hooks/write-failures.log"
if [ -f "$WFLOG" ]; then
  RECENT_FAILS=$(awk -v cutoff="$(date -u -d '24 hours ago' +%FT%T 2>/dev/null || date -u -v-24H +%FT%T)" '$1 >= cutoff' "$WFLOG" | wc -l)
  if [ "$RECENT_FAILS" = "0" ]; then
    ok "No failures in last 24h"
  else
    warn "$RECENT_FAILS write failures in last 24h"
    if [ "$VERBOSE" = "1" ] || [ "$RECENT_FAILS" -gt 0 ]; then
      echo "  ${C_DIM}Recent failures:${C_RESET}"
      awk -v cutoff="$(date -u -d '24 hours ago' +%FT%T 2>/dev/null || date -u -v-24H +%FT%T)" '$1 >= cutoff' "$WFLOG" | tail -3 | sed "s/^/    ${C_DIM}/" | sed "s/$/${C_RESET}/"
    fi
    # Note: failures are not critical — script still exits 0
  fi
else
  ok "No write-failures.log (no failures recorded)"
fi

# ── L8: Brain reachability + recent captured pages ──
hdr "L8 — Brain connectivity"
if command -v gbrain >/dev/null 2>&1 && [ -f "$CFG" ]; then
  if gbrain doctor --fast 2>&1 | grep -q "Health score"; then
    SCORE=$(gbrain doctor --fast 2>&1 | grep -oE "score: [0-9]+" | awk '{print $2}')
    if [ -n "$SCORE" ] && [ "$SCORE" -ge 70 ]; then
      ok "Brain reachable (health $SCORE/100)"
    else
      warn "Brain reachable but health $SCORE/100"
    fi
  else
    err "gbrain doctor failed"
    FAILURES=$((FAILURES+1))
  fi
fi

# ── L9: Security audit ─────────────────────────────
hdr "L9 — Security audit"
SEC_FAILURES=0

# 9.1 — File perms 0600 on sensitive files
for f in "$CFG" "$HOME/gbrain/.env" \
         "$HOME/.gbrain/hooks/signal-detector.log" \
         "$HOME/.gbrain/hooks/write-failures.log" \
         "$HOME/.gbrain/hooks/last-extraction-raw.txt"; do
  [ -f "$f" ] || continue
  PERMS=$(stat -c%a "$f" 2>/dev/null || stat -f%A "$f" 2>/dev/null)
  if [ "$PERMS" = "600" ] || [ "$PERMS" = "400" ]; then
    [ "$VERBOSE" = "1" ] && ok "0$PERMS  $f"
  else
    err "Permisos 0$PERMS en $f (debe ser 0600 o 0400)"
    SEC_FAILURES=$((SEC_FAILURES+1))
    repair "chmod 600 on $f" "chmod 600 '$f'"
  fi
done

# 9.2 — Hooks dir not world-readable
HOOKS_PERMS=$(stat -c%a "$HOME/.gbrain/hooks" 2>/dev/null || stat -f%A "$HOME/.gbrain/hooks" 2>/dev/null)
if [ -n "$HOOKS_PERMS" ]; then
  if [ "$HOOKS_PERMS" = "700" ] || [ "$HOOKS_PERMS" = "750" ]; then
    [ "$VERBOSE" = "1" ] && ok "Dir perms 0$HOOKS_PERMS on ~/.gbrain/hooks"
  else
    warn "~/.gbrain/hooks dir has 0$HOOKS_PERMS (recommend 0700)"
    SEC_FAILURES=$((SEC_FAILURES+1))
    repair "chmod 700 on ~/.gbrain/hooks" "chmod 700 '$HOME/.gbrain/hooks'"
  fi
fi

# 9.3 — No API key leaks in logs
LEAK_PATTERN='sk-ant-[a-zA-Z0-9_-]{40,}'
for f in "$HOME/.gbrain/hooks/signal-detector.log" \
         "$HOME/.gbrain/hooks/write-failures.log" \
         "$HOME/.gbrain/hooks/last-extraction-raw.txt"; do
  [ -f "$f" ] || continue
  if grep -qE "$LEAK_PATTERN" "$f" 2>/dev/null; then
    err "API key leaked in $f — exposed!"
    SEC_FAILURES=$((SEC_FAILURES+1))
    CRITICAL=$((CRITICAL+1))
    warn "  Run: chmod 600 '$f' && manually inspect+redact"
  fi
done

# 9.4 — No DB password in logs
DB_PW_PATTERN='postgresql://[^:]+:[^@]+@'
for f in "$HOME/.gbrain/hooks/signal-detector.log" \
         "$HOME/.gbrain/hooks/write-failures.log" \
         "$HOME/.gbrain/hooks/last-extraction-raw.txt"; do
  [ -f "$f" ] || continue
  if grep -qE "$DB_PW_PATTERN" "$f" 2>/dev/null; then
    err "Postgres URL with credentials leaked in $f"
    SEC_FAILURES=$((SEC_FAILURES+1))
    CRITICAL=$((CRITICAL+1))
  fi
done

# 9.5 — Env vars not exposed in process listing
PROC_API_KEY=$(ps eww 2>/dev/null | grep "ANTHROPIC_API_KEY=sk-" | grep -v grep | head -1)
if [ -n "$PROC_API_KEY" ]; then
  warn "ANTHROPIC_API_KEY visible in some 'ps' output — consider env-file launchers"
  [ "$VERBOSE" = "1" ] && echo "  ${C_DIM}(this is normal for openclaw-node + gbrain workers; only an issue on shared hosts)${C_RESET}"
fi

# 9.6 — Stop hook command path is absolute (no PATH-injection)
HOOK_CMD=$(jq -r '.hooks.Stop[].hooks[] | select(.command | contains("signal-detector")) | .command' "$SETTINGS" 2>/dev/null | head -1)
if [ -n "$HOOK_CMD" ]; then
  if echo "$HOOK_CMD" | grep -qE 'python3 (/|\$HOME|\$\{HOME\})'; then
    [ "$VERBOSE" = "1" ] && ok "Hook command uses absolute or \$HOME path (safe)"
  else
    warn "Hook command may be PATH-relative — recommend absolute path"
    SEC_FAILURES=$((SEC_FAILURES+1))
  fi
fi

# 9.7 — Backup file with secret in CFG bak
BAK_LEAKS=$(ls "$HOME/.gbrain/"*.bak* 2>/dev/null | wc -l)
if [ "$BAK_LEAKS" -gt 0 ]; then
  warn "$BAK_LEAKS .bak file(s) in ~/.gbrain/ may contain secrets"
  ls "$HOME/.gbrain/"*.bak* 2>/dev/null | head -3 | sed 's/^/    /'
  SEC_FAILURES=$((SEC_FAILURES+1))
  if [ "$VERBOSE" = "1" ]; then
    warn "  Review and remove if obsolete: rm $HOME/.gbrain/*.bak*"
  fi
fi

# 9.8 — Ensure recursion env var not stuck on
if [ "${GBRAIN_HOOK_RUNNING:-0}" = "1" ]; then
  warn "GBRAIN_HOOK_RUNNING=1 in current shell — captures will silently skip"
  warn "  Run: unset GBRAIN_HOOK_RUNNING"
  SEC_FAILURES=$((SEC_FAILURES+1))
fi

if [ "$SEC_FAILURES" = "0" ]; then
  ok "Security audit: 8/8 checks passed"
else
  warn "Security audit: $SEC_FAILURES issue(s) — see above"
  FAILURES=$((FAILURES + SEC_FAILURES))
fi

# ── Summary ───────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
if [ "$FAILURES" = "0" ] && [ "$CRITICAL" = "0" ]; then
  echo "${C_OK}${C_BOLD}  ✅ ALL CHECKS PASSED${C_RESET}"
  echo "  Capture is healthy. Use Claude Code normally; signals will land in GBrain."
  EXIT=0
elif [ "$CRITICAL" -gt 0 ]; then
  echo "${C_ERR}${C_BOLD}  ✗ $CRITICAL CRITICAL FAILURES (manual intervention required)${C_RESET}"
  echo "  $FAILURES total failures. $FIXED auto-fixed. $CRITICAL need manual help."
  EXIT=2
elif [ "$FIX" = "0" ]; then
  echo "${C_WARN}${C_BOLD}  ⚠ $FAILURES FAILURE(S) — re-run with --fix to auto-repair${C_RESET}"
  echo "  Or manually follow the fix hints above."
  EXIT=1
else
  echo "${C_OK}${C_BOLD}  ✓ $FIXED REPAIRS APPLIED, $((FAILURES - FIXED)) STILL FAILING${C_RESET}"
  echo "  Re-run capture-doctor.sh to verify. Re-run with --fix again if some can self-heal."
  EXIT=$([ "$((FAILURES - FIXED))" = "0" ] && echo 0 || echo 1)
fi
echo "════════════════════════════════════════════════════════"
exit $EXIT
