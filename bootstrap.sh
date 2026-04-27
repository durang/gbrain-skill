#!/usr/bin/env bash
# GBrain Multi-Client Bootstrap
# Interactive installer: detects host, asks which clients to connect,
# verifies shared brain. Documented in INSTALL.md and CONNECT.md.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/durang/gbrain-skill/master/bootstrap.sh)
# or, if you already have the repo:
#   bash bootstrap.sh

set -euo pipefail

# ── colors ────────────────────────────────────────
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

ok()   { echo "${C_OK}✓${C_RESET} $*"; }
warn() { echo "${C_WARN}⚠${C_RESET} $*"; }
err()  { echo "${C_ERR}✗${C_RESET} $*" >&2; }
hdr()  { echo ""; echo "${C_BOLD}── $* ──${C_RESET}"; }
ask()  {
  # ask "prompt" "default" → echoes user response
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    read -p "  $prompt [$default]: " reply </dev/tty || reply=""
    echo "${reply:-$default}"
  else
    read -p "  $prompt: " reply </dev/tty || reply=""
    echo "$reply"
  fi
}
yesno() {
  # yesno "Question?" "y|n" → returns 0 if yes, 1 if no
  local prompt="$1" default="${2:-n}" reply
  local hint="[y/N]"; [ "$default" = "y" ] && hint="[Y/n]"
  read -p "  $prompt $hint: " reply </dev/tty || reply=""
  reply="${reply:-$default}"
  case "$reply" in y|Y|yes|YES|s|S|si|SI) return 0 ;; *) return 1 ;; esac
}

# ── 1. Detect host ────────────────────────────────
hdr "Detect host"
OS="$(uname -s)"
ARCH="$(uname -m)"
HOST="$(hostname -s 2>/dev/null || hostname)"
case "$OS" in
  Darwin) HOST_KIND="Mac" ;;
  Linux)  HOST_KIND="Linux" ;;
  *)      HOST_KIND="Other ($OS)" ;;
esac
ok "Host: $HOST_KIND ($HOST, $ARCH)"

# ── 2. Pre-flight: Bun ────────────────────────────
hdr "Pre-flight: Bun runtime"
export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export PATH="$BUN_INSTALL/bin:$PATH"
if command -v bun >/dev/null 2>&1; then
  ok "Bun: $(bun --version)"
else
  if yesno "Bun is required. Install it now?" "y"; then
    curl -fsSL https://bun.sh/install | bash
    export PATH="$BUN_INSTALL/bin:$PATH"
    ok "Bun installed: $(bun --version)"
  else
    err "Bun required. Aborting."; exit 1
  fi
fi

# ── 3. Pre-flight: gbrain ─────────────────────────
hdr "Pre-flight: GBrain CLI"
GBRAIN_NEEDS_REINSTALL=0
if command -v gbrain >/dev/null 2>&1; then
  GVER="$(gbrain --version 2>&1 | head -1 | awk '{print $NF}')"
  case "$GVER" in
    0.2*|0.3*) ok "gbrain $GVER (canonical Garry Tan version)" ;;
    *)
      warn "gbrain $GVER detected — not the canonical version (expected 0.2x.x from github:garrytan/gbrain)"
      if yesno "Reinstall the canonical version from GitHub?" "y"; then
        GBRAIN_NEEDS_REINSTALL=1
      fi
      ;;
  esac
else
  GBRAIN_NEEDS_REINSTALL=1
fi

if [ "$GBRAIN_NEEDS_REINSTALL" = "1" ]; then
  bun remove -g gbrain 2>/dev/null || true
  rm -f "$HOME/.bun/bin/gbrain" 2>/dev/null || true
  bun install -g github:garrytan/gbrain
  hash -r 2>/dev/null || true
  ok "gbrain $(gbrain --version 2>&1 | head -1 | awk '{print $NF}') installed"
fi

# ── 4. Backend: Postgres database_url ─────────────
hdr "Backend: shared brain (Postgres)"
CFG="$HOME/.gbrain/config.json"
if [ -f "$CFG" ]; then
  EXISTING_URL="$(python3 -c "import json,sys; print(json.load(open('$CFG')).get('database_url',''))" 2>/dev/null || echo "")"
  if [ -n "$EXISTING_URL" ]; then
    ok "Existing config found at $CFG"
    echo "  ${C_DIM}URL prefix: $(echo "$EXISTING_URL" | cut -c1-40)...${C_RESET}"
    if yesno "Keep this database_url?" "y"; then
      DBURL="$EXISTING_URL"
    fi
  fi
fi

if [ -z "${DBURL:-}" ]; then
  echo "  No usable config. Choose backend:"
  echo "    1) Paste an existing Postgres URL (Supabase, Neon, RDS, etc.)"
  echo "    2) Run 'gbrain init --pglite' for a local-only brain (not shared)"
  echo "    3) Abort"
  CHOICE=$(ask "Choice (1/2/3)" "1")
  case "$CHOICE" in
    1)
      DBURL=$(ask "Postgres URL (postgresql://user:pass@host:port/db)" "")
      [ -n "$DBURL" ] || { err "Empty URL"; exit 1; }
      mkdir -p "$HOME/.gbrain"
      cat > "$CFG" <<JSON
{
  "engine": "postgres",
  "database_url": "$DBURL"
}
JSON
      chmod 600 "$CFG"
      ok "Wrote $CFG (mode 600)"
      ;;
    2)
      gbrain init --pglite
      ok "Local PGLite brain initialized (this client will NOT share with others)"
      DBURL="(pglite)"
      ;;
    *) err "Aborted"; exit 1 ;;
  esac
fi

# ── 5. Verify shared brain ────────────────────────
hdr "Verify connection to shared brain"
if [ "$DBURL" != "(pglite)" ]; then
  gbrain doctor --fast || warn "doctor returned warnings (often benign with --fast)"
  echo ""
  echo "  Sample pages already in this brain:"
  gbrain list -n 5 2>/dev/null | sed 's/^/    /' || warn "list failed"
fi

# ── 6. Per-client MCP registration ────────────────
hdr "Connect MCP clients"
echo "  For each client, you'll be asked yes/no. Skip what you don't use."
echo ""

GBRAIN_BIN="$(command -v gbrain || echo $HOME/.bun/bin/gbrain)"
ANY_CONNECTED=0

# Claude Code (terminal / Antigravity / VS Code with Claude extension all share ~/.claude.json)
if command -v claude >/dev/null 2>&1; then
  if yesno "Connect Claude Code (terminal, Antigravity, VS Code Claude extension — they share user config)?" "y"; then
    claude mcp add gbrain -- "$GBRAIN_BIN" serve 2>&1 || warn "(may already be registered)"
    ok "Claude Code wired"
    ANY_CONNECTED=1
  fi
else
  if yesno "Claude Code CLI not found. Install it now? (npm i -g @anthropic-ai/claude-code)" "n"; then
    npm i -g @anthropic-ai/claude-code
    claude mcp add gbrain -- "$GBRAIN_BIN" serve 2>&1 || true
    ANY_CONNECTED=1
  fi
fi

# Cursor
if yesno "Connect Cursor (if installed)?" "n"; then
  CURSOR_CFG="$HOME/.cursor/mcp.json"
  mkdir -p "$(dirname "$CURSOR_CFG")"
  if [ -f "$CURSOR_CFG" ] && grep -q '"gbrain"' "$CURSOR_CFG"; then
    ok "Cursor already has gbrain configured"
  else
    # Merge or create
    python3 - <<PY
import json, os
p = os.path.expanduser("$CURSOR_CFG")
data = {"mcpServers": {}}
if os.path.exists(p):
    try: data = json.load(open(p))
    except: pass
data.setdefault("mcpServers", {})
data["mcpServers"]["gbrain"] = {"command": "$GBRAIN_BIN", "args": ["serve"]}
json.dump(data, open(p,"w"), indent=2)
PY
    ok "Cursor wired ($CURSOR_CFG)"
  fi
  ANY_CONNECTED=1
fi

# Windsurf
if yesno "Connect Windsurf (if installed)?" "n"; then
  WS_CFG="$HOME/.codeium/windsurf/mcp_config.json"
  mkdir -p "$(dirname "$WS_CFG")"
  python3 - <<PY
import json, os
p = os.path.expanduser("$WS_CFG")
data = {"mcpServers": {}}
if os.path.exists(p):
    try: data = json.load(open(p))
    except: pass
data.setdefault("mcpServers", {})
data["mcpServers"]["gbrain"] = {"command": "$GBRAIN_BIN", "args": ["serve"]}
json.dump(data, open(p,"w"), indent=2)
PY
  ok "Windsurf wired ($WS_CFG)"
  ANY_CONNECTED=1
fi

# Claude Desktop — needs HTTP wrapper (not available in v0.2x stdio-only)
echo ""
warn "Claude Desktop, claude.ai web, Claude mobile, and Perplexity require an HTTP"
warn "wrapper around 'gbrain serve' which is NOT in the v0.2x binary today."
warn "See CONNECT.md → 'What about HTTP / Claude Desktop / claude.ai web?' for the"
warn "three real paths (wait upstream / build wrapper / contribute PR)."
if yesno "Mark these as TODO in $HOME/.gbrain/TODO.md?" "n"; then
  mkdir -p "$HOME/.gbrain"
  cat >> "$HOME/.gbrain/TODO.md" <<TODO
## $(date -u +%F) — HTTP wrapper deferred
Clients waiting on HTTP transport (gbrain serve --http or custom wrapper):
  - Claude Desktop ($HOST_KIND)
  - claude.ai web (Cowork, chat)
  - Claude mobile
See https://github.com/durang/gbrain-skill/blob/master/CONNECT.md
TODO
  ok "TODO appended"
fi

# ── 7. Bidirectional brain test (optional) ────────
hdr "Optional: bidirectional brain test"
if [ "$DBURL" != "(pglite)" ] && yesno "Write a ping page to verify shared-brain end-to-end?" "y"; then
  SLUG="test/bootstrap-ping-$(date -u +%s)"
  echo "ping from $HOST_KIND:$HOST at $(date -u +%FT%TZ)" | "$GBRAIN_BIN" put "$SLUG"
  ok "Wrote $SLUG to shared brain"
  echo "  ${C_DIM}From any other connected machine, run:${C_RESET}"
  echo "    gbrain get $SLUG"
  echo "  ${C_DIM}You should see the same string. That confirms shared brain.${C_RESET}"
fi

# ── 8. Shell PATH hint ────────────────────────────
hdr "Shell PATH"
SHELL_RC=""
[ -f "$HOME/.zshrc" ] && SHELL_RC="$HOME/.zshrc"
[ -z "$SHELL_RC" ] && [ -f "$HOME/.bashrc" ] && SHELL_RC="$HOME/.bashrc"
if [ -n "$SHELL_RC" ] && ! grep -q "\.bun/bin" "$SHELL_RC" 2>/dev/null; then
  if yesno "Append '$BUN_INSTALL/bin' to PATH in $SHELL_RC?" "y"; then
    echo 'export PATH="$HOME/.bun/bin:$PATH"' >> "$SHELL_RC"
    ok "PATH updated in $SHELL_RC (source it or open a new terminal)"
  fi
fi

# ── 9. Summary ────────────────────────────────────
hdr "Summary"
ok "GBrain CLI: $(gbrain --version 2>&1 | head -1 | awk '{print $NF}')"
ok "Backend: $([ "$DBURL" = "(pglite)" ] && echo "PGLite (local-only)" || echo "Postgres (shared)")"
[ "$ANY_CONNECTED" = "1" ] && ok "At least one MCP client wired" || warn "No MCP clients wired"
echo ""
echo "${C_BOLD}Next:${C_RESET}"
echo "  - Restart Claude Code / Cursor / Windsurf to pick up new MCP entry"
echo "  - Try: 'search my brain for [topic]' inside the client"
echo "  - For HTTP-only clients (Desktop/web/mobile), see CONNECT.md"
echo ""
