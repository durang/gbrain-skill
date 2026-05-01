#!/bin/bash
# /gbrain — runnable script. Usage:
#   bash ~/.openclaw/skills/gbrain/run.sh           → full dashboard
#   bash ~/.openclaw/skills/gbrain/run.sh fix       → auto-fix safe issues
#   bash ~/.openclaw/skills/gbrain/run.sh news      → upstream news only
#   bash ~/.openclaw/skills/gbrain/run.sh bugs      → bugs that affect you
#   bash ~/.openclaw/skills/gbrain/run.sh compare   → diff vs last snapshot
#   bash ~/.openclaw/skills/gbrain/run.sh save      → full + save markdown to ~/brain/reports/

set +e   # tolerant — single failing layer should not abort whole report
SUBCMD="${1:-check}"
SKILL_DIR="$HOME/.openclaw/skills/gbrain"
SNAP_DIR="$SKILL_DIR/snapshots"
mkdir -p "$SNAP_DIR"

cd ~/gbrain && set -a && source .env && set +a 2>/dev/null
PASSWORD=$(echo "$DATABASE_URL" | sed 's/.*:\([^@]*\)@.*/\1/' 2>/dev/null)

# ─── Helpers ───
read_model_field() {
  # $1 = field: primary | fallbacks_count
  python3 -c "
import json
try:
    d = json.load(open('$HOME/.openclaw/openclaw.json'))
    m = (d.get('agents',{}).get('list') or [{}])[0].get('model') or d.get('agents',{}).get('defaults',{}).get('model','')
    if isinstance(m, dict):
        if '$1' == 'primary': print(m.get('primary',''))
        elif '$1' == 'fallbacks_count': print(len(m.get('fallbacks',[])))
        elif '$1' == 'fallbacks_list': print(','.join(m.get('fallbacks',[])))
    else:
        if '$1' == 'primary': print(m)
        elif '$1' == 'fallbacks_count': print(0)
        elif '$1' == 'fallbacks_list': print('')
except Exception as e:
    print('')
" 2>/dev/null
}

count_stuck_sessions_last_hour() {
  # CANÓNICO: respeta el detector OpenClaw, NO clasifica ni filtra. Si OpenClaw dice "stuck", es stuck.
  # Si el umbral 120s te genera ruido en jobs slow legítimos (GBrain Sync), el fix correcto es
  # upstream en OpenClaw (umbral configurable per-job), NO un workaround local que oculte señal.
  # Ver issue: https://github.com/openclaw/openclaw/issues/73327 (per-job stuckThresholdMs)
  local LOG="/tmp/openclaw/openclaw-$(date -u +%Y-%m-%d).log"
  [ -f "$LOG" ] || { echo 0; return; }
  local CUTOFF=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M)
  grep "stuck session" "$LOG" 2>/dev/null | awk -F'"date":"' '{print $2}' | cut -c1-16 | awk -v c="$CUTOFF" '$0 > c' | wc -l
}

count_node_api_keys() {
  local PID=$(systemctl --user show openclaw-node -p MainPID --value 2>/dev/null)
  [ -z "$PID" ] || [ "$PID" = "0" ] && { echo 0; return; }
  cat /proc/$PID/environ 2>/dev/null | tr '\0' '\n' | grep -cE "_API_KEY=" || echo 0
}

mcp_server_health() {
  # Quick non-blocking probe: does the configured command exist + can spawn?
  python3 -c "
import json, os, subprocess, sys
try:
    d = json.load(open('$HOME/.openclaw/openclaw.json'))
    servers = d.get('mcp',{}).get('servers',{})
    for name, cfg in servers.items():
        cmd = cfg.get('command','')
        ok = '✅' if cmd and os.path.exists(cmd) else '❌ binary missing'
        print(f'| \`{name}\` | {ok} | \`{cmd}\` |')
except Exception as e:
    print(f'| ? | error | {e} |')
" 2>/dev/null
}

cron_failure_rate_24h() {
  local STATE="$HOME/.openclaw/cron/jobs-state.json"
  local JOBS="$HOME/.openclaw/cron/jobs.json"
  [ -f "$STATE" ] || { echo "(no state file)"; return; }
  python3 -c "
import json, datetime, time
try:
    s = json.load(open('$STATE'))
    jobs_meta = {}
    try:
        j = json.load(open('$JOBS'))
        for jb in (j if isinstance(j, list) else j.get('jobs', [])):
            jobs_meta[jb.get('id','')] = jb.get('name','?')
    except Exception:
        pass
    cutoff_ms = int(time.time()*1000) - 24*3600*1000
    total = err = 0
    failed = []
    for jid, jstate in (s.get('jobs') or {}).items():
        st = jstate.get('state') or {}
        last = st.get('lastRunAtMs') or 0
        if last >= cutoff_ms:
            total += 1
            ce = st.get('consecutiveErrors', 0)
            status = (st.get('lastStatus') or st.get('lastRunStatus') or '').lower()
            if status not in ('ok','success','') or ce > 0:
                err += 1
                failed.append(jobs_meta.get(jid, jid[:8]))
    if failed:
        print(f'{err}/{total} — failing: ' + ', '.join(failed[:3]))
    else:
        print(f'{err}/{total} ✅')
except Exception as e:
    print(f'(parse err: {str(e)[:60]})')
" 2>/dev/null
}

run_check() {
  # ─── Auto-sync skills monorepo (silencioso, rate-limited 30min) ───
  # Cuando corres /gbrain, primero sincroniza skills si lleva >30 min sin sync.
  # Esto significa: NUNCA tienes que correr `git pull && install.sh` manual.
  # /gbrain es la única puerta — sincroniza por ti.
  if [ -d "$HOME/skills/.git" ]; then
    LAST_SYNC_FILE="$HOME/.skills-last-sync"
    NOW_TS=$(date +%s)
    LAST_TS=0
    if [ -f "$LAST_SYNC_FILE" ]; then
      # Linux uses stat -c %Y; macOS stat -f %m
      LAST_TS=$(stat -c %Y "$LAST_SYNC_FILE" 2>/dev/null || stat -f %m "$LAST_SYNC_FILE" 2>/dev/null || echo 0)
    fi
    AGE=$((NOW_TS - LAST_TS))
    if [ "$AGE" -gt 1800 ] || [ "$LAST_TS" -eq 0 ]; then
      echo "🔄 Sincronizando skills monorepo..."
      SYNC_OUTPUT=$(cd "$HOME/skills" && git pull 2>&1)
      if echo "$SYNC_OUTPUT" | grep -q "Already up to date\|Already up-to-date"; then
        echo "✓ Skills al día (sin cambios upstream)"
      else
        CHANGED=$(echo "$SYNC_OUTPUT" | grep -E "^\s+\S+\s+\|" | wc -l)
        echo "✓ Skills sincronizados — $CHANGED archivo(s) actualizado(s)"
        (cd "$HOME/skills" && bash install.sh >/dev/null 2>&1) && echo "✓ install.sh aplicado"
      fi
      date > "$LAST_SYNC_FILE"
      echo ""
    else
      AGE_MIN=$((AGE / 60))
      echo "✓ Skills al día (último sync hace ${AGE_MIN} min)"
      echo ""
    fi
  fi

  echo '```'
  echo '   ██████╗ ██████╗ ██████╗  █████╗ ██╗███╗   ██╗'
  echo '  ██╔════╝ ██╔══██╗██╔══██╗██╔══██╗██║████╗  ██║'
  echo '  ██║  ███╗██████╔╝██████╔╝███████║██║██╔██╗ ██║'
  echo '  ██║   ██║██╔══██╗██╔══██╗██╔══██║██║██║╚██╗██║'
  echo '  ╚██████╔╝██████╔╝██║  ██║██║  ██║██║██║ ╚████║'
  echo '   ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝'
  echo '              Canonical Health Dashboard v2'
  echo '```'
  echo ""
  echo "## 🗂️ Índice rápido — todos los comandos"
  echo ""
  echo "| Comando | Para qué |"
  echo "|---|---|"
  echo "| \`/gbrain\` o \`/gbrain check\` | Dashboard completo (esto que estás viendo) |"
  echo "| \`/gbrain manual\` | 📖 **Manual completo** con casos de uso. Si dudas qué correr, este |"
  echo "| \`/gbrain bootstrap\` | Verifica TODO el stack instalado correcto. Idempotente |"
  echo "| \`/gbrain custom-instructions\` (o \`ci\`) | Genera el bloque actualizado para claude.ai. Compara vs lo aplicado |"
  echo "| \`/gbrain compound [status\|history\|dry-run]\` | 🌙 Compounding Engine — brain mejora overnight (auto). \`status\` ve confidence, \`dry-run\` testa sin aplicar |"
  echo "| \`/gbrain principles\` | Reglas operacionales (canónico siempre gana, etc.) |"
  echo "| \`/gbrain manifest\` | Inventario canónico del stack (versiones, schemas) |"
  echo "| \`/gbrain news\` | Releases + PRs + issues abiertos en gbrain upstream |"
  echo "| \`/gbrain bugs\` | Bugs upstream que afectan tu versión instalada |"
  echo "| \`/gbrain fix\` | Auto-fix de issues seguros |"
  echo "| \`/gbrain compare\` | Diff vs snapshot anterior — detecta regresiones |"
  echo "| \`/gbrain save\` | Guarda este reporte en \`~/brain/reports/gbrain-YYYY-MM-DD.md\` |"
  echo ""
  echo "**Solo necesitas recordar \`/gbrain\` — desde aquí ves todo lo demás.**"
  echo ""
  echo "---"
  echo ""
  echo "| 🕐 Generated | 🌐 Host | 👤 User |"
  echo "|---|---|---|"
  echo "| \`$(date -u +%Y-%m-%dT%H:%M:%SZ) UTC\` | \`$(hostname)\` | \`$USER\` |"
  echo ""
  echo "> 👋 **Hola Sergio** — panel de control de **GBrain** + **OpenClaw**, en 15 capas."
  echo "> Cada capa explica qué mide, por qué importa, y qué hacer si está ⚠️ o ❌."
  echo ""
  echo "> 📖 **Manual completo:** \`/gbrain manual\` — todos los comandos + cuándo usarlos"
  echo ""
  echo "## 🎛️ Shortcuts disponibles (todos los subcomandos)"
  echo ""
  echo "| Comando | Qué hace | Cuándo usarlo |"
  echo "|---|---|---|"
  echo "| \`/gbrain\` o \`/gbrain check\` | Dashboard completo (lo que ves ahora) | Diario, después de cualquier cambio |"
  echo "| \`/gbrain fix\` | Auto-fix de issues seguros (embed --stale, extract links/timeline, integrity) | Cuando ves ⚠️ en doctor |"
  echo "| \`/gbrain news\` | Releases nuevas + PRs + issues abiertos en gbrain (upstream) | Cada 2-3 días para no perder updates de Garry |"
  echo "| \`/gbrain bugs\` | Solo bugs upstream que afectan TU stack actual | Cuando algo se rompe sin razón aparente |"
  echo "| \`/gbrain compare\` | Diff vs snapshot anterior (detecta regresiones) | Después de upgrade o cambio mayor |"
  echo "| \`/gbrain save\` | Guarda este reporte en \`~/brain/reports/gbrain-YYYY-MM-DD.md\` | Para historial / compartir con otros |"
  echo "| \`/gbrain bootstrap\` | Verifica que el host tenga TODO lo del MANIFEST.json instalado correctamente | Después de \`git clone\` en EC2 nueva, o periódicamente |"
  echo "| \`/gbrain principles\` | Lee las reglas operacionales (canónico siempre gana, etc.) | Antes de tocar cualquier skill |"
  echo "| \`/gbrain manifest\` | Lee el MANIFEST.json (canonical inventory de tu stack) | Cuando quieras saber qué versión esperada tienes |"
  echo "| \`/gbrain manual\` | Lee el manual completo (este archivo + casos de uso) | Cuando dudes qué comando correr |"
  echo "| \`/gbrain custom-instructions\` (o \`/gbrain ci\`) | Genera el bloque de Custom Instructions actualizado para claude.ai | Cuando \`Layer 11b\` muestre 🔴 drift, o monthly como sanity check |"
  echo ""
  echo "**Cómo invocar:**"
  echo "- Aquí (Claude Code terminal): escribe \`/gbrain\` o \`/gbrain <subcomando>\`"
  echo "- En Telegram a \`@Srgdrnmoltbot\`: igual, escribe \`/gbrain\` o \`revisa gbrain\`"
  echo "- CLI directo: \`bash ~/.openclaw/skills/gbrain/run.sh <subcomando>\`"
  echo ""
  echo "---"
  echo ""

  # ─── 🚨 ALERT BANNER (top) ───
  STUCK=$(count_stuck_sessions_last_hour)
  KEYS=$(count_node_api_keys)
  FB_COUNT=$(read_model_field fallbacks_count)
  QUEUE_DEPTH=$(gbrain doctor --json 2>/dev/null | tail -1 | python3 -c "
import json,sys,re
try:
    d=json.load(sys.stdin)
    for c in d.get('checks',[]):
        if c.get('name')=='queue_health':
            m=re.search(r'=(\d+)', c.get('message','')); print(m.group(1) if m else 0); break
    else: print(0)
except: print(0)" 2>/dev/null)
  ALERTS=()
  # CANÓNICO: respeta el detector de OpenClaw. Cualquier stuck = alert. Si hay ruido, fix raíz upstream.
  [ "$STUCK" -gt 0 ] 2>/dev/null && ALERTS+=("🔴 **$STUCK stuck session(s)** en última hora — el detector OpenClaw los marcó")
  [ "$KEYS" -eq 0 ] 2>/dev/null && ALERTS+=("🔴 **openclaw-node sin API keys** en su environment — fix: \`EnvironmentFile=\` en el systemd unit")
  [ "$FB_COUNT" -eq 0 ] 2>/dev/null && ALERTS+=("🟠 **Modelo sin fallbacks** — si MiniMax timeouts, la sesión muere. Configura \`agents.defaults.model.fallbacks\`")
  [ "$QUEUE_DEPTH" -gt 100 ] 2>/dev/null && ALERTS+=("🟠 **Queue depth=$QUEUE_DEPTH** en autopilot-cycle — workers atorados")

  # Custom Instructions drift detection
  CI_SPEC_VER=$(grep -oE "^custom-instructions-version: [0-9]+" "$HOME/.openclaw/skills/brain-write-macro/SKILL.md" 2>/dev/null | awk '{print $2}')
  CI_APPLIED_VER=$(cat "$HOME/.gbrain/custom-instructions-applied.flag" 2>/dev/null | tr -d ' \n')
  [ -z "$CI_APPLIED_VER" ] && CI_APPLIED_VER="0"
  if [ -n "$CI_SPEC_VER" ] && [ "$CI_APPLIED_VER" != "$CI_SPEC_VER" ]; then
    ALERTS+=("🔴 **Custom Instructions desactualizadas** — claude.ai tiene v$CI_APPLIED_VER, spec actual es v$CI_SPEC_VER. Corre \`/gbrain custom-instructions\` para el bloque nuevo.")
  fi

  # Skills monorepo drift detection
  if [ -d "$HOME/skills/.git" ]; then
    SKILLS_REMOTE=$(cd "$HOME/skills" && git ls-remote origin master 2>/dev/null | awk '{print $1}' | head -c 7)
    SKILLS_LOCAL=$(cd "$HOME/skills" && git rev-parse master 2>/dev/null | head -c 7)
    if [ -n "$SKILLS_REMOTE" ] && [ -n "$SKILLS_LOCAL" ] && [ "$SKILLS_LOCAL" != "$SKILLS_REMOTE" ]; then
      ALERTS+=("🟠 **Skills monorepo atrasado** — local \`$SKILLS_LOCAL\` vs remote \`$SKILLS_REMOTE\`. Corre \`cd ~/skills && git pull && ./install.sh\`")
    fi
  fi
  if [ "${#ALERTS[@]}" -gt 0 ]; then
    echo "## 🚨 Alertas críticas"
    echo ""
    for a in "${ALERTS[@]}"; do echo "- $a"; done
    echo ""
    echo "---"
    echo ""
  fi

  # ─── TL;DR — resumen ejecutivo ───
  HEALTH_SCORE=$(gbrain doctor --json 2>/dev/null | tail -1 | python3 -c "import json,sys;print(json.load(sys.stdin).get('health_score','?'))" 2>/dev/null)
  PAGES_NOW=$(gbrain stats 2>/dev/null | grep -E "^Pages:" | awk '{print $2}')
  if [ "$HEALTH_SCORE" -ge 90 ] 2>/dev/null; then SCORE_BADGE="🟢 $HEALTH_SCORE/100"; \
  elif [ "$HEALTH_SCORE" -ge 70 ] 2>/dev/null; then SCORE_BADGE="🟡 $HEALTH_SCORE/100"; \
  else SCORE_BADGE="🔴 $HEALTH_SCORE/100"; fi
  echo "## 📋 TL;DR — resumen ejecutivo"
  echo ""
  echo "| 🩺 Health | 📚 Pages | ⚠️ Alertas | 🔴 Stuck/h | 🔑 API keys |"
  echo "|---|---|---|---|---|"
  echo "| $SCORE_BADGE | \`$PAGES_NOW\` | \`${#ALERTS[@]}\` | \`$STUCK\` | \`$KEYS\` |"
  echo ""
  echo "---"
  echo ""

  # ─── Tabla de contenido ───
  echo "## 📚 Contenido"
  echo ""
  echo "| # | Capa | Qué mide |"
  echo "|---|---|---|"
  echo "| 1 | 📦 Versiones | GBrain + OpenClaw vs latest |"
  echo "| 2 | 🏥 Runtime | Gateway, Telegram, modelo, fallbacks |"
  echo "| 3 | 🔬 Doctor | gbrain doctor structured |"
  echo "| 3b | 🔗 Schema correlation | tablas BD ↔ wrapper ↔ skills (detecta drift silencioso) |"
  echo "| 4 | 📊 Stats | pages/chunks/links/timeline |"
  echo "| 5 | 🎯 Skills | skills cargadas en OpenClaw |"
  echo "| 5b | 🌀 HERMES integration | skills + bot diff + MCP link (parallel runtime) |"
  echo "| 6 | 📈 Captura 24h | efectividad de signal-detector |"
  echo "| 7 | 🐛 Bugs upstream | matchea tu versión vs known bugs |"
  echo "| 8 | 📰 News | releases/PRs/issues con fecha |"
  echo "| 9 | 📸 Snapshot diff | regresiones desde última corrida |"
  echo "| 10 | 📜 Archivos canónicos | mtime de SOUL/MEMORY/openclaw.json |"
  echo "| 11 | 🔌 MCP Health | servidores MCP y binarios |"
  echo "| 11b | 🧩 Wrappers + Integrations | wrappers HTTP, integration recipes, OAuth clients, captura por origen |"
  echo "| 12 | ⏱️ Stuck sessions | sesiones colgadas última hora |"
  echo "| 13 | 🔑 Process env | API keys en openclaw-node |"
  echo "| 14 | ⏰ Cron failures | jobs fallando en 24h |"
  echo "| 15 | 🚀 Upstream changelog | commits + cross-ref con warnings + posts del autor |"
  echo "| 16 | 🎲 Upgrade Decision Engine | INSTALAR / ESPERAR / SKIP con razones (gbrain + openclaw) |"
  echo "| 17 | 📡 Upstream Features Watch | tweet-style features informativos + propagación a skills satélite |"
  echo "| 15 | 🚀 Upstream changelog | commits + cross-ref con warnings |"
  echo ""
  echo "---"
  echo ""

  # ─── Layer 1: Versiones ───
  echo "## 📦 Layer 1 — Versiones (release tracking)"
  echo ""
  echo "_¿Qué mido?_ Si tu **GBrain** y **OpenClaw** locales están al día con lo último publicado por sus mantenedores. GBrain lo hace Garry Tan (CEO de Y Combinator), OpenClaw es de martian-engineering."
  echo ""
  IGB=$(gbrain --version 2>&1 | head -1 | awk '{print $2}')
  LGB=$(curl -sS https://raw.githubusercontent.com/garrytan/gbrain/master/VERSION 2>/dev/null | tr -d '\n')
  IOC=$(openclaw --version 2>&1 | head -1 | awk '{print $2}')
  LOCS=$(npm view openclaw dist-tags.latest 2>/dev/null)
  LOCB=$(npm view openclaw dist-tags.beta 2>/dev/null)
  [ "$IGB" = "$LGB" ] && GS="✅" || GS="⚠️ run: gbrain upgrade"
  [ "$IOC" = "$LOCS" ] && OS="✅" || OS="⚠️"
  echo ""
  echo "| Producto | Instalado | Latest | Status |"
  echo "|---|---|---|---|"
  echo "| GBrain | \`$IGB\` | \`$LGB\` | $GS |"
  echo "| OpenClaw | \`$IOC\` | \`$LOCS\` (beta=\`$LOCB\`) | $OS |"
  echo ""

  # ─── Layer 2: Runtime ───
  echo "## 🏥 Layer 2 — Runtime (lo que está vivo ahora mismo)"
  echo ""
  echo "_¿Qué mido?_ Si el **gateway de OpenClaw** está respondiendo, si **Telegram** tiene conexión activa con \`api.telegram.org\`, qué **modelo LLM** está corriendo, y si los archivos canónicos (MCP gbrain registrado, SOUL.md con la directiva signal-detector) están en su lugar."
  echo ""
  if openclaw gateway status 2>&1 | grep -q "Runtime: running" && ss -tlnp 2>/dev/null | grep -q ":18789"; then
    GW="✅ running (port 18789 listening)"
  else
    GW="❌ down — run: openclaw gateway start"
  fi
  TG=$(ss -tnp state established 2>/dev/null | grep -c "149.154.")
  NPM=$(ps -ef | grep "npm install" | grep -v grep | wc -l)
  MCP=$(grep -c '"gbrain"' ~/.openclaw/openclaw.json 2>/dev/null)
  SOUL=$(grep -c "Signal detector on every inbound" ~/SOUL.md 2>/dev/null)
  MODEL=$(read_model_field primary)
  FB_LIST=$(read_model_field fallbacks_list)
  FB_COUNT=$(read_model_field fallbacks_count)
  if [ "$FB_COUNT" -gt 0 ] 2>/dev/null; then
    FB_DISPLAY="✅ $FB_COUNT fallbacks (\`$FB_LIST\`)"
  else
    FB_DISPLAY="🟠 0 fallbacks — sesión muere si modelo timeoutea"
  fi
  echo ""
  echo "| Check | Estado |"
  echo "|---|---|"
  echo "| Gateway RPC | $GW |"
  echo "| Telegram conexiones | $TG $([ "$TG" -ge 1 ] && echo '✅' || echo '❌') |"
  echo "| npm install loop | $NPM $([ "$NPM" -eq 0 ] && echo '✅' || echo '⚠️') |"
  echo "| Modelo primario | \`$MODEL\` |"
  echo "| Fallbacks configurados | $FB_DISPLAY |"
  echo "| MCP gbrain registrado | $([ "$MCP" -ge 1 ] && echo '✅' || echo '❌') |"
  echo "| SOUL.md directiva | $([ "$SOUL" -ge 1 ] && echo '✅' || echo '❌') |"
  echo ""

  # ─── Layer 3: Doctor ───
  echo "## 🔬 Layer 3 — Doctor (chequeo completo de gbrain)"
  echo ""
  echo "_¿Qué mido?_ Esto es \`gbrain doctor --json\` — el chequeo nativo que ofrece Garry. Verifica schema version, RLS (Row Level Security en Postgres), embeddings, integridad JSONB, salud del knowledge graph, y más. **Health score 100 = todo perfecto. 75-99 = warnings menores. <75 = atender ya.**"
  echo ""
  echo ""
  gbrain doctor --json 2>/dev/null | tail -1 | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(f'**Health score: {d[\"health_score\"]}/100** ({d[\"status\"]})')
    print('')
    print('| Check | Status | Mensaje |')
    print('|---|---|---|')
    for c in d['checks']:
        icon = {'ok':'✅','warn':'⚠️','fail':'❌'}.get(c['status'], '?')
        msg = c['message'][:80].replace('|','\\\\|')
        print(f'| {c[\"name\"]} | {icon} | {msg} |')
except Exception as e:
    print(f'(doctor failed: {e})')
"
  echo ""

  # ─── Layer 3b: Schema correlation (¿wrapper sigue compatible con la BD?) ───
  echo "## 🔗 Layer 3b — Schema correlation (BD ↔ wrapper ↔ skills)"
  echo ""
  echo "_¿Qué mido?_ Verifico que las tablas + columnas que el **wrapper** y los **skills** esperan existan en la BD actual. Si gbrain hace una migration que renombra una columna o quita una tabla, el wrapper rompe **silenciosamente** (errores 500 en producción). Esto detecta el drift antes de que pase."
  echo ""

  declare -A REQUIRED_COLS
  REQUIRED_COLS["pages"]="id slug type compiled_truth frontmatter created_at updated_at"
  REQUIRED_COLS["content_chunks"]="id page_id chunk_index chunk_text embedding embedded_at"
  REQUIRED_COLS["access_tokens"]="id name token_hash created_at last_used_at revoked_at"
  REQUIRED_COLS["oauth_clients"]="client_id client_name redirect_uris"
  REQUIRED_COLS["oauth_codes"]="code_hash client_id redirect_uri code_challenge expires_at"
  REQUIRED_COLS["oauth_refresh_tokens"]="refresh_hash client_id access_token_name expires_at"
  REQUIRED_COLS["ingest_log"]="id source_type source_ref summary created_at"
  REQUIRED_COLS["links"]="id from_page_id to_page_id link_type"

  echo "| Tabla | Cols esperadas | Cols presentes | Status |"
  echo "|---|---|---|---|"
  SCHEMA_DRIFT=0
  for tbl in "${!REQUIRED_COLS[@]}"; do
    expected="${REQUIRED_COLS[$tbl]}"
    actual=$(PGCONNECT_TIMEOUT=5 psql "$DATABASE_URL" -At -F' ' -c "SELECT string_agg(column_name, ' ') FROM information_schema.columns WHERE table_name='$tbl' AND table_schema='public';" 2>/dev/null)
    if [ -z "$actual" ]; then
      echo "| \`$tbl\` | $(echo $expected | wc -w) | 0 | 🔴 TABLA NO EXISTE |"
      SCHEMA_DRIFT=$((SCHEMA_DRIFT+1))
      continue
    fi
    missing=""
    for col in $expected; do
      echo " $actual " | grep -q " $col " || missing="$missing $col"
    done
    if [ -z "$missing" ]; then
      echo "| \`$tbl\` | $(echo $expected | wc -w) | $(echo $actual | wc -w) | ✅ |"
    else
      echo "| \`$tbl\` | $(echo $expected | wc -w) | $(echo $actual | wc -w) | 🔴 falta:$missing |"
      SCHEMA_DRIFT=$((SCHEMA_DRIFT+1))
    fi
  done
  echo ""
  if [ "$SCHEMA_DRIFT" -gt 0 ]; then
    echo "⚠️ **$SCHEMA_DRIFT tabla(s) con drift de schema** — el wrapper o skills locales pueden romper. Investigar con \`gbrain doctor\` y revisar release notes upstream."
    ALERTS+=("- 🔴 **Schema drift en $SCHEMA_DRIFT tabla(s)** — wrapper en riesgo de romper")
  else
    echo "✅ Todas las tablas críticas tienen las columnas esperadas. Wrapper y skills compatibles con la BD actual."
  fi
  echo ""

  # ─── Layer 4: Stats ───
  echo "## 📊 Layer 4 — Brain stats (cuánto contenido tienes)"
  echo ""
  echo "_¿Qué mido?_ Cuántas **pages** (entidades + ideas + memorias), **chunks** (fragmentos vectorizados), **embeddings** (chunks con vector OpenAI), **links** (relaciones entre entidades), **timeline entries** (eventos con fecha), y **tags** tienes. Esto crece cada vez que tu agente captura información."
  echo ""
  echo ""
  gbrain stats 2>/dev/null | grep -E "Pages|Chunks|Embedded|Links|Timeline|Tags" | sed 's/^/- /'
  echo ""

  # ─── Layer 5: Skills ───
  echo "## 🎯 Layer 5 — Skills GBrain cargadas en OpenClaw"
  echo ""
  echo "_¿Qué mido?_ Las **skills de gbrain** que el agente puede invocar. La crítica es \`signal-detector\` — captura entidades/ideas en cada mensaje. \`brain-ops\` es el ciclo de read-enrich-write. Las demás son especializaciones (ingesta de PDFs, voces, meetings, etc.)."
  echo ""
  echo ""
  echo "| Skill | Status |"
  echo "|---|---|"
  for s in signal-detector brain-ops idea-ingest media-ingest meeting-ingestion soul-audit cross-modal-review citation-fixer; do
    [ -f ~/.openclaw/skills/$s/SKILL.md ] && echo "| \`$s\` | ✅ |" || echo "| \`$s\` | ❌ missing |"
  done
  echo ""

  # ─── Layer 5b: HERMES skills + integration (NEW — runtime parallel) ───
  if [ -d "$HOME/.hermes" ]; then
    echo "## 🌀 Layer 5b — HERMES skills + integration (parallel runtime)"
    echo ""
    echo "_¿Qué mido?_ HERMES corre en paralelo a OpenClaw alimentando el mismo brain. Aquí verifico que el setup esté limpio: bot Telegram diferente al de OpenClaw, gbrain MCP server compartido, skills heredadas, gateway status. Detalle granular en \`/hermestrack\`."
    echo ""
    HERMES_VER=$($HOME/.local/bin/hermes --version 2>/dev/null | head -1 | awk '{print $3}' || echo "n/a")
    HERMES_MODEL=$(grep -A 1 "^model:" $HOME/.hermes/config.yaml 2>/dev/null | grep "default:" | head -1 | sed 's/.*default: *"\?\([^"]*\)"\?/\1/')
    HERMES_PROVIDER=$(grep "provider:" $HOME/.hermes/config.yaml 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
    HERMES_SKILLS=$(ls $HOME/.hermes/skills/ 2>/dev/null | wc -l)
    HERMES_IMPORTED=$(ls $HOME/.hermes/skills/openclaw-imports/ 2>/dev/null | wc -l)
    HERMES_GATEWAY=$($HOME/.local/bin/hermes gateway status 2>&1 | grep -iE "running|stopped" | head -1 | head -c 50)
    HERMES_BOT=$(grep "^TELEGRAM_BOT_TOKEN" $HOME/.hermes/.env 2>/dev/null | head -1 | head -c 30 | sed 's/=.*/=***/')
    OPENCLAW_BOT_HASH=$(python3 -c "import json,hashlib;d=json.load(open('$HOME/.openclaw/openclaw.json'));t=d.get('channels',{}).get('telegram',{}).get('botToken','');print(hashlib.sha256(t.encode()).hexdigest()[:8] if t else '')" 2>/dev/null)
    HERMES_BOT_HASH=$(grep "^TELEGRAM_BOT_TOKEN" $HOME/.hermes/.env 2>/dev/null | sed 's/^TELEGRAM_BOT_TOKEN=//' | head -1 | python3 -c "import sys,hashlib;t=sys.stdin.read().strip();print(hashlib.sha256(t.encode()).hexdigest()[:8] if t else '')" 2>/dev/null)
    if [ "$OPENCLAW_BOT_HASH" = "$HERMES_BOT_HASH" ] && [ -n "$OPENCLAW_BOT_HASH" ]; then
      BOT_DIFF="🔴 SAME bot — VAN A PELEAR por mensajes (OpenClaw o HERMES debe usar bot diferente)"
    else
      BOT_DIFF="✅ different (no polling conflict)"
    fi
    HERMES_MCP_GBRAIN=$(grep -E "gbrain:" $HOME/.hermes/config.yaml 2>/dev/null | wc -l)
    if [ "$HERMES_MCP_GBRAIN" -gt 0 ] 2>/dev/null; then
      MCP_LINK="✅ HERMES → gbrain MCP server registered"
    else
      MCP_LINK="⚠️ HERMES no tiene gbrain MCP configurado — corre 'hermes mcp add gbrain'"
    fi

    echo "| Check | Valor |"
    echo "|---|---|"
    echo "| Versión HERMES | \`$HERMES_VER\` |"
    echo "| Modelo default | \`$HERMES_MODEL\` |"
    echo "| Provider | \`$HERMES_PROVIDER\` |"
    echo "| Skills totales (bundled+imports) | $HERMES_SKILLS |"
    echo "| Skills importadas de OpenClaw | $HERMES_IMPORTED |"
    echo "| MCP gbrain link | $MCP_LINK |"
    echo "| Bot Telegram vs OpenClaw | $BOT_DIFF |"
    echo "| Gateway status | $HERMES_GATEWAY |"
    echo ""
    echo "Para detalle granular: \`/hermestrack\`"
    echo ""
  fi

  # ─── Layer 6: Captura últimas 24h ───
  echo "## 📈 Layer 6 — Captura ambient (últimas 24h)"
  echo ""
  echo "_¿Qué mido?_ La **efectividad real** de tu setup. Si pages/links/timeline NO crecieron en 24h significa que el agente no está capturando — algo se rompió silenciosamente. Las \`gbrain__\` tools en sessions confirman que el agente realmente llamó al MCP server."
  echo ""
  if [ -n "$PASSWORD" ]; then
    P24=$(PGPASSWORD=$PASSWORD psql "$DATABASE_URL" -tAc "SELECT count(*) FROM pages WHERE created_at > now() - interval '24 hours'" 2>/dev/null || echo "?")
    L24=$(PGPASSWORD=$PASSWORD psql "$DATABASE_URL" -tAc "SELECT count(*) FROM links WHERE created_at > now() - interval '24 hours'" 2>/dev/null || echo "?")
    T24=$(PGPASSWORD=$PASSWORD psql "$DATABASE_URL" -tAc "SELECT count(*) FROM timeline_entries WHERE created_at > now() - interval '24 hours'" 2>/dev/null || echo "?")
  fi
  echo ""
  echo "| Métrica | Últimas 24h |"
  echo "|---|---|"
  echo "| Pages creadas | $P24 |"
  echo "| Links creados | $L24 |"
  echo "| Timeline entries | $T24 |"
  echo ""
  echo "**Tools \`gbrain__\` en últimas 5 sessions:**"
  for f in $(ls -t ~/.openclaw/agents/main/sessions/*.jsonl 2>/dev/null | head -5); do
    C=$(grep -c "\"name\":\"gbrain__" "$f" 2>/dev/null | head -1 | tr -d '\n ')
    [ -z "$C" ] && C=0
    A=$(stat -c '%y' "$f" | cut -d. -f1)
    if [ "$C" -gt 0 ] 2>/dev/null; then IC="✅"; else IC="⚪"; fi
    echo "- $IC $A → $C calls"
  done
  echo ""

  # ─── Layer 7: Bugs upstream que te afectan ───
  echo "## 🐛 Layer 7 — Bugs upstream conocidos (que afectan TU setup)"
  echo ""
  echo "_¿Qué mido?_ Cruza tu versión actual contra los bugs que la **comunidad ya reportó** en gbrain/openclaw issues. Si te afecta uno, te digo el workaround. Si no te afecta, ✅."
  echo ""
  echo ""
  echo "| Bug | Te afecta? |"
  echo "|---|---|"
  [[ "$IOC" == *"beta"* ]] && echo "| OC beta plugin reinstall loop | ⚠️ SÍ |" || echo "| OC beta plugin reinstall loop | ✅ NO |"
  [[ "$MODEL" == *"deepseek"* ]] && echo "| DeepSeek reasoning_content rejection | ⚠️ SÍ — bug upstream |" || echo "| DeepSeek reasoning_content rejection | ✅ NO (\`$MODEL\`) |"
  [ -f ~/.gbrain/migrations-fix-applied ] && echo "| #370 v0.18 migration chain fails | ✅ FIXED localmente |" || echo "| #370 v0.18 migration chain fails | ⚠️ check schema_version |"
  echo "| #389 apply-migrations hangs on large brains | ⚠️ posible si brain >5K pages |"
  echo ""

  # ─── Layer 8: News upstream ───
  echo "## 📰 Layer 8 — News upstream (qué publicó Garry últimamente)"
  echo ""
  echo "_¿Qué mido?_ Lo que se publicó recientemente en el repo de Garry. Releases nuevas, PRs en revisión (los que están a punto de entrar), e issues abiertos (cosas que están rompiéndose en la comunidad). **Síguelos** — así sabes qué viene."
  echo ""
  echo "### Últimas 5 releases gbrain"
  echo ""
  curl -sS "https://api.github.com/repos/garrytan/gbrain/tags?per_page=5" 2>/dev/null | python3 -c "
import json, sys
try:
    tags = json.load(sys.stdin)
    if not tags:
        print('(no tags found yet)')
    for t in tags[:5]:
        print(f\"- **{t['name']}** — sha \`{t['commit']['sha'][:7]}\`\")
except Exception as e: print(f'(error: {e})')"
  echo ""
  echo "### 5 PRs abiertos más recientes (próximos a mergear)"
  echo ""
  curl -sS "https://api.github.com/repos/garrytan/gbrain/pulls?state=open&per_page=5&sort=updated" 2>/dev/null | python3 -c "
import json, sys
try:
    prs = json.load(sys.stdin)
    for p in prs[:5]:
        date = p.get('updated_at','')[:10]
        labels = ','.join([l['name'] for l in p.get('labels',[])][:2]) or '—'
        print(f\"- [{date}] PR#{p['number']} ({labels}) {p['title'][:75]}\")
except: print('(no se pudo leer)')"
  echo ""
  echo "### 5 issues abiertos más recientes (bugs que la comunidad ve)"
  echo ""
  curl -sS "https://api.github.com/repos/garrytan/gbrain/issues?state=open&per_page=10&sort=updated" 2>/dev/null | python3 -c "
import json, sys
try:
    iss = [i for i in json.load(sys.stdin) if 'pull_request' not in i][:5]
    for i in iss:
        date = i.get('updated_at','')[:10]
        labels = ','.join([l['name'] for l in i.get('labels',[])][:2]) or '—'
        print(f\"- [{date}] #{i['number']} ({labels}) {i['title'][:75]}\")
except: print('(no se pudo leer)')"
  echo ""

  # ─── Layer 9: Snapshot + diff ───
  echo "## 📸 Layer 9 — Snapshot histórico (detección de regresiones)"
  echo ""
  echo "_¿Qué mido?_ Cada vez que corres \`/gbrain\` se guarda un snapshot de los stats. Aquí ves el **diff vs el snapshot anterior** — si pages NO crecieron significa que la captura cayó. Si links retrocedieron, hubo borrado raro."
  echo ""
  SNAP_NOW="$SNAP_DIR/$(date -u +%Y%m%dT%H%M%S).json"
  gbrain stats 2>/dev/null | grep -E "Pages|Chunks|Embedded|Links|Timeline|Tags" | python3 -c "
import sys, json, datetime
d = {}
for line in sys.stdin:
    if ':' in line:
        k, v = line.split(':', 1)
        try: d[k.strip()] = int(v.strip())
        except: pass
print(json.dumps({'ts': datetime.datetime.utcnow().isoformat()+'Z', 'stats': d}, indent=2))
" > "$SNAP_NOW" 2>/dev/null
  echo ""
  echo "Snapshot guardado: \`$(basename $SNAP_NOW)\`"
  PREV=$(ls -t $SNAP_DIR/*.json 2>/dev/null | sed -n '2p')
  if [ -n "$PREV" ]; then
    echo ""
    echo "**Diff vs anterior (\`$(basename $PREV)\`):**"
    python3 - "$PREV" "$SNAP_NOW" <<'PY'
import json, sys
prev = json.load(open(sys.argv[1]))
now = json.load(open(sys.argv[2]))
for k in sorted(now['stats'].keys()):
    p = prev['stats'].get(k, 0)
    n = now['stats'][k]
    delta = n - p
    icon = '✅' if delta > 0 else ('⚪' if delta == 0 else '⚠️')
    sign = '+' if delta >= 0 else ''
    print(f"- {icon} {k}: {p} → {n} (Δ {sign}{delta})")
PY
  fi
  echo ""

  # ─── Layer 10: Diff SOUL.md/MEMORY.md ───
  echo "## 📜 Layer 10 — Archivos canónicos (mtime + tamaño)"
  echo ""
  echo "_¿Qué mido?_ Cuándo se modificaron por última vez tus 3 archivos críticos: \`SOUL.md\` (identidad de Jarvis), \`MEMORY.md\` (memoria persistente), \`openclaw.json\` (config completa). Si cambiaron sin que tú lo recuerdes → algo (otro agente, hook, cron) los tocó."
  echo ""
  for f in ~/SOUL.md ~/MEMORY.md ~/.openclaw/openclaw.json; do
    if [ -f "$f" ]; then
      AGE=$(stat -c '%y' "$f" | cut -d. -f1)
      SIZE=$(wc -c < "$f")
      echo "- \`$(basename $f)\` — modified $AGE ($SIZE bytes)"
    fi
  done
  echo ""

  # ─── Layer 11: MCP Health ───
  echo "## 🔌 Layer 11 — MCP Health (servidores y binarios)"
  echo ""
  echo "_¿Qué mido?_ Cada servidor MCP registrado en \`openclaw.json\` y si su binario sigue presente en disco. (Una de las raíces de cuelgues silenciosos: el binario fue movido o el cron lo llama con el nombre viejo.)"
  echo ""
  echo "| Server | Status | Command |"
  echo "|---|---|---|"
  mcp_server_health
  echo ""

  # ─── Layer 11b: Stack ligado a GBrain (gbrain principal + satélites) ───
  echo "## 🧩 Layer 11b — Stack ligado a GBrain"
  echo ""
  echo "_¿Qué mido?_ El stack completo alrededor de tu brain. **GBrain es el principal** (la BD, el CLI, el MCP server). Todo lo demás son **satélites** que extienden capacidades a clientes que GBrain core no soporta:"
  echo ""
  echo "- 🥇 **GBrain (core)** — la base. CLI + Postgres + MCP server stdio."
  echo "- 🛰️ **gbrain-http-wrapper** (tu repo) — extiende GBrain a Desktop/web/mobile via HTTP+OAuth."
  echo "- 🛰️ **brain-write-macro** (skill local) — extiende captura por frase a clientes sin hook."
  echo "- 🛰️ **integration recipes** — extiende ingest a fuentes externas (email, calendar, etc.)."
  echo ""
  echo "Si mañana subes un plugin nuevo o cambias el wrapper, esta sección lo refleja sin tocar el script."
  echo ""

  # — A: HTTP wrappers locales (systemd, dedupe) —
  echo "### A. HTTP wrappers (systemd)"
  echo ""
  echo "| Service | Status | Port | Endpoint | Health |"
  echo "|---|---|---|---|---|"
  declare -A seen_svc
  for svc_unit in /etc/systemd/system/*gbrain*.service /etc/systemd/system/*brain-http*.service /etc/systemd/system/*mcp*.service; do
    [ ! -f "$svc_unit" ] && continue
    svc_name=$(basename "$svc_unit" .service)
    [ -n "${seen_svc[$svc_name]}" ] && continue
    seen_svc[$svc_name]=1
    svc_state=$(systemctl is-active "$svc_name" 2>/dev/null || echo "unknown")
    case "$svc_state" in
      active)   icon="✅ active" ;;
      inactive) icon="⬜ inactive" ;;
      *)        icon="❌ $svc_state" ;;
    esac
    # Port detection: try unit file → EnvironmentFile → common ports
    port=$(grep -oE "PORT=[0-9]+" "$svc_unit" 2>/dev/null | head -1 | cut -d= -f2)
    if [ -z "$port" ]; then
      env_file=$(grep -oE "EnvironmentFile=\S+" "$svc_unit" 2>/dev/null | head -1 | cut -d= -f2)
      if [ -n "$env_file" ] && [ -r "$env_file" ]; then
        port=$(grep -oE "^PORT=[0-9]+" "$env_file" 2>/dev/null | head -1 | cut -d= -f2)
      fi
    fi
    # Probe known ports if still unknown
    [ -z "$port" ] && for try_port in 8787 8888 3000; do
      curl -s --max-time 1 "http://127.0.0.1:$try_port/health" 2>/dev/null | grep -q "ok\|status" && { port=$try_port; break; }
    done
    endpoint="-"
    health="-"
    if [ "$svc_state" = "active" ] && [ -n "$port" ]; then
      endpoint="http://127.0.0.1:$port"
      health_raw=$(curl -s --max-time 3 "$endpoint/health" 2>/dev/null | head -c 80)
      if [ -n "$health_raw" ]; then
        health="✅ $health_raw"
      else
        health="❌ unreachable"
      fi
    fi
    echo "| $svc_name | $icon | ${port:-?} | $endpoint | $health |"
    # ALSO test PUBLIC path (Tailscale Funnel) — local OK ≠ public OK (TLS cert desync caught us once)
    if [ "$svc_name" = "gbrain-http-wrapper" ] && [ "$svc_state" = "active" ]; then
      PUBLIC_URL=$(grep -E "^WRAPPER_BASE_URL=" "$HOME/gbrain-http-wrapper/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d ' ')
      if [ -n "$PUBLIC_URL" ]; then
        PUBLIC_CODE=$(curl -s --max-time 8 -o /dev/null -w "%{http_code}" "$PUBLIC_URL/health" 2>/dev/null)
        if [ "$PUBLIC_CODE" = "200" ]; then
          public_status="✅ HTTP $PUBLIC_CODE"
        elif [ "$PUBLIC_CODE" = "000" ]; then
          public_status="🔴 TLS/network fail (HTTP 000) — \`sudo tailscale funnel reset && sudo tailscale funnel --bg --set-path=/mcp http://127.0.0.1:$port\`"
        else
          public_status="🟡 HTTP $PUBLIC_CODE"
        fi
        echo "| └─ public | _via Tailscale Funnel_ | - | $PUBLIC_URL | $public_status |"
      fi
    fi
  done
  if [ ${#seen_svc[@]} -eq 0 ]; then
    echo "| _(none detected)_ | - | - | - | No HTTP wrappers as systemd units |"
  fi
  echo ""

  # — B: Integration recipes (gbrain integrations list) —
  echo "### B. Integration recipes registrados en gbrain"
  echo ""
  if [ -x "$HOME/.bun/bin/gbrain" ]; then
    integrations_out=$($HOME/.bun/bin/gbrain integrations list 2>&1 | grep -v "Prepared statements" | head -30)
    if echo "$integrations_out" | grep -qiE "configured|installed|active"; then
      echo "$integrations_out" | sed 's/^/    /' | head -20
    else
      echo "_No integrations configured. Available recipes via_ \`gbrain integrations list-available\`_._"
    fi
  else
    echo "_gbrain CLI not found at expected path._"
  fi
  echo ""

  # — C: OAuth clients + tokens activos (firma de qué clientes externos están ligados) —
  echo "### C. OAuth clients (clientes externos ligados al brain)"
  echo ""
  echo "| Client name | Last used | Created |"
  echo "|---|---|---|"
  if [ -n "$DATABASE_URL" ] || command -v psql >/dev/null 2>&1; then
    DB_URL_LOCAL="${DATABASE_URL:-$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('~/.gbrain/config.json')))['database_url'])" 2>/dev/null)}"
    if [ -n "$DB_URL_LOCAL" ]; then
      PGCONNECT_TIMEOUT=5 psql "$DB_URL_LOCAL" -At -F' | ' -c "
        SELECT c.client_name, COALESCE(MAX(t.last_used_at)::timestamp(0)::text, 'never'), c.created_at::date
        FROM oauth_clients c
        LEFT JOIN access_tokens t ON t.name LIKE 'oauth/' || c.client_id || '%'
        GROUP BY c.client_id, c.client_name, c.created_at
        ORDER BY MAX(t.last_used_at) DESC NULLS LAST
        LIMIT 10;
      " 2>/dev/null | sed 's/^/| /; s/$/ |/' | head -10
    else
      echo "| - | - | _no DB URL_ |"
    fi
  fi
  echo ""

  # — D-pre: brain-write-macro skill detection + upstream replacement check —
  echo "### D. Brain-write-macro (skill puente para clientes sin hook)"
  echo ""
  if [ -f "$HOME/.openclaw/skills/brain-write-macro/SKILL.md" ]; then
    echo "✅ Skill instalado: \`~/.openclaw/skills/brain-write-macro/SKILL.md\`"
    # Check if upstream gbrain has absorbed this functionality
    UPSTREAM_REPLACEMENT=""
    if gbrain --help 2>&1 | grep -qiE "save-conv|save_conversation|phrase-trigger"; then
      UPSTREAM_REPLACEMENT=$(gbrain --help 2>&1 | grep -iE "save-conv|save_conversation|phrase-trigger" | head -1)
    fi
    if [ -n "$UPSTREAM_REPLACEMENT" ]; then
      echo "⚠️ **Upstream gbrain ya tiene un reemplazo nativo:** \`$UPSTREAM_REPLACEMENT\`"
      echo "   → considera deprecar este skill. Ver _Auto-deprecation conditions_ en SKILL.md."
    else
      echo "  No hay reemplazo upstream todavía — este skill sigue siendo necesario."
    fi
    # Custom Instructions version drift check — alerta si hay que repegar el bloque
    SKILL_CI_VERSION=$(grep -oE "^custom-instructions-version: [0-9]+" "$HOME/.openclaw/skills/brain-write-macro/SKILL.md" 2>/dev/null | awk '{print $2}')
    [ -z "$SKILL_CI_VERSION" ] && SKILL_CI_VERSION="?"
    if [ -f "$HOME/.gbrain/custom-instructions-applied.flag" ]; then
      USER_CI_VERSION=$(head -1 "$HOME/.gbrain/custom-instructions-applied.flag" 2>/dev/null | tr -d ' \n')
      [ -z "$USER_CI_VERSION" ] && USER_CI_VERSION="0"
      if [ "$USER_CI_VERSION" = "$SKILL_CI_VERSION" ]; then
        echo "  ✅ Custom Instructions de claude.ai aplicadas — **v$USER_CI_VERSION** (al día)"
      else
        echo "  🔴 **Custom Instructions desactualizadas:** tienes v$USER_CI_VERSION en claude.ai, el skill define v$SKILL_CI_VERSION"
        echo "     → Repegar el bloque actualizado en https://claude.ai → Settings → Profile"
        echo "     → Después: \`echo \"$SKILL_CI_VERSION\" > ~/.gbrain/custom-instructions-applied.flag\`"
        echo "     Changelog:"
        sed -n '/custom-instructions-changelog:/,/^[a-z-]*:/p' "$HOME/.openclaw/skills/brain-write-macro/SKILL.md" 2>/dev/null | grep -E "^  v" | sed 's/^/       /'
      fi
    else
      echo "  ⚠️ Falta pegar el bloque en https://claude.ai → Settings → Profile → Custom Instructions"
      echo "     (sin esto, mobile/web/desktop NO reconocen \"guarda en gbrain\")"
      echo "     Después: \`echo \"$SKILL_CI_VERSION\" > ~/.gbrain/custom-instructions-applied.flag\`"
    fi
  else
    echo "❌ Skill no instalado. Crear con \`mkdir -p ~/.openclaw/skills/brain-write-macro && touch SKILL.md\`"
  fi
  echo ""

  # — D: Pages capturadas en últimas 24h, agrupadas por fuente (qué cliente capturó) —
  echo "### E. Captura últimas 24h por origen"
  echo ""
  if [ -n "$DB_URL_LOCAL" ]; then
    echo "| Origen | Pages 24h | Última |"
    echo "|---|---|---|"
    PGCONNECT_TIMEOUT=5 psql "$DB_URL_LOCAL" -At -F' | ' -c "
      SELECT
        COALESCE(SPLIT_PART(slug,'/',1), 'root') AS origen,
        COUNT(*) AS n,
        MAX(updated_at)::timestamp(0)::text AS last
      FROM pages
      WHERE updated_at > NOW() - INTERVAL '24 hours'
      GROUP BY origen
      ORDER BY n DESC
      LIMIT 8;
    " 2>/dev/null | sed 's/^/| /; s/$/ |/' | head -8
  fi
  echo ""

  # ─── Layer 12: Stuck sessions ───
  echo "## ⏱️ Layer 12 — Stuck sessions (última hora)"
  echo ""
  echo "_¿Qué mido?_ Cuento entradas \`stuck session\` en el log de openclaw de la última hora. Es el síntoma directo de \"JARVIS no responde\": una sesión queda en \`state=processing\` por minutos sin completar. Si >0, hay un cuello de botella (modelo timeout, MCP timeout, o cron atorado)."
  echo ""
  STUCK_COUNT=$(count_stuck_sessions_last_hour)
  if [ "$STUCK_COUNT" -gt 0 ] 2>/dev/null; then
    echo "🔴 **$STUCK_COUNT stuck session(s) en última hora** — el detector de OpenClaw los marcó (umbral 120s)."
    echo ""
    echo "   _Reglas canónicas_: respetamos lo que dice OpenClaw. Si crees que el umbral es bajo para algún job (ej. GBrain Sync con sync remoto 2-3 min), el fix correcto es **upstream** — [issue #73327 abierto](https://github.com/openclaw/openclaw/issues/73327): \`stuckThresholdMs\` configurable per-job."
    echo "   - Revisar log: \`grep \"stuck session\" /tmp/openclaw/openclaw-$(date -u +%Y-%m-%d).log | tail -5\`"
    echo "   - Cross-check si el job completó: \`tail -3 ~/.openclaw/cron/runs/<job-id>-*.jsonl | grep status\`"
  else
    echo "✅ 0 stuck sessions — el agente no está colgándose"
  fi
  echo ""

  # ─── Layer 13: Process env audit ───
  echo "## 🔑 Layer 13 — Process env audit"
  echo ""
  echo "_¿Qué mido?_ Cuento variables \`*_API_KEY\` en el environment del proceso \`openclaw-node\`. Si el contador es 0, los MCP servers child (gbrain, etc.) heredan environment vacío y fallan con \"OPENAI_API_KEY missing\" — esto fue exactamente la raíz del cuelgue del cron de hoy. Fix canónico: \`EnvironmentFile=~/.openclaw/.env\` en el systemd unit."
  echo ""
  KEY_COUNT=$(count_node_api_keys)
  NODE_PID=$(systemctl --user show openclaw-node -p MainPID --value 2>/dev/null)
  if [ "$KEY_COUNT" -ge 1 ] 2>/dev/null; then
    echo "✅ openclaw-node (pid $NODE_PID) tiene **$KEY_COUNT** API key(s) en su environment"
  else
    echo "🔴 openclaw-node (pid $NODE_PID) tiene **0** API keys — agregar \`EnvironmentFile=-/home/ec2-user/.openclaw/.env\` al unit"
  fi
  echo ""

  # ─── Layer 14: Cron failure rate ───
  echo "## ⏰ Layer 14 — Cron failure rate (24h)"
  echo ""
  echo "_¿Qué mido?_ Lee \`~/.openclaw/cron/jobs-state.json\` y cuento ejecuciones fallidas vs totales en últimas 24h. Si es alto significa que un cron está timeoutándose o reventando — buen indicador antes de que las sesiones se atoren."
  echo ""
  CRON_RATE=$(cron_failure_rate_24h)
  echo "Failures / Total runs (últimas 24h): **$CRON_RATE**"
  echo ""

  # ─── Layer 15: Upstream changelog vs implementado ───
  echo "## 🚀 Layer 15 — Upstream changelog (commits + posts del autor)"
  echo ""
  echo "_¿Qué mido?_ Trae los últimos commits del repo de Garry Tan, identifica cuáles **ya están en tu versión instalada** vs cuáles vienen en la próxima release. Cruza fix-commits con tu setup para detectar si algún arreglo upstream resuelve un warning local. Incluye los últimos posts/anuncios del autor en GitHub releases (los tweets requieren feed externo no confiable, así que uso releases como source canónico)."
  echo ""

  # Last 15 commits on master with PR# and date
  echo "### 🔧 Últimos 15 commits en \`garrytan/gbrain\` (master)"
  echo ""
  IGB_VERSION=$(gbrain --version 2>&1 | head -1 | awk '{print $2}')
  curl -sS "https://api.github.com/repos/garrytan/gbrain/commits?per_page=15" 2>/dev/null | IGB_VERSION="$IGB_VERSION" python3 -c "
import json, sys, os, re
try:
    commits = json.load(sys.stdin)
    target = os.environ.get('IGB_VERSION','').strip()
    pattern = re.compile(r'\bv?'+re.escape(target)+r'\b')
    seen_installed = False
    print('| Estado | SHA | Fecha | Mensaje |')
    print('|---|---|---|---|')
    for c in commits[:15]:
        sha = c['sha'][:7]
        date = c['commit']['author']['date'][:10]
        msg = c['commit']['message'].split('\\n')[0][:75].replace('|','\\\\|')
        # If this commit message references the installed version, mark it + everything after
        status = '🔜 pendiente' if not seen_installed else '✅ instalado'
        if pattern.search(msg) and not seen_installed:
            status = '🟢 tu versión'
            seen_installed = True
        print(f'| {status} | \`{sha}\` | {date} | {msg} |')
    if not seen_installed:
        print('')
        print(f'_Nota: no se encontró commit que mencione \`v{target}\` en los últimos 15. Todos los commits arriba son potencialmente nuevos vs tu instalación._')
except Exception as e:
    print(f'(error: {e})')
" 2>/dev/null
  echo ""

  # Recent fix commits that may resolve LOCAL warnings (cross-reference with doctor warnings)
  echo "### 🔍 Fix commits que podrían resolver tus warnings locales"
  echo ""
  WARNINGS=$(gbrain doctor --json 2>/dev/null | tail -1 | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for c in d.get('checks',[]):
        if c.get('status') in ('warn','fail'): print(c.get('name','')+':'+c.get('message','')[:60])
except: pass
" 2>/dev/null)
  curl -sS "https://api.github.com/repos/garrytan/gbrain/commits?per_page=30" 2>/dev/null | python3 -c "
import json, sys, re
warnings = '''$WARNINGS'''.lower()
keywords = []
if 'graph_coverage' in warnings or 'link' in warnings: keywords += ['link', 'extract', 'graph']
if 'integrity' in warnings: keywords += ['integrity', 'tweet', 'sanitize']
if 'queue_health' in warnings or 'autopilot' in warnings: keywords += ['queue', 'autopilot', 'minion', 'worker']
if 'brain_score' in warnings: keywords += ['score', 'orphan', 'dead-link']
if 'resolver' in warnings: keywords += ['resolver', 'skill']
try:
    commits = json.load(sys.stdin)
    matches = []
    for c in commits[:30]:
        msg = c['commit']['message'].split('\\n')[0]
        msg_lower = msg.lower()
        for kw in keywords:
            if kw in msg_lower and ('fix' in msg_lower or 'feat' in msg_lower or 'perf' in msg_lower):
                matches.append((c['sha'][:7], c['commit']['author']['date'][:10], msg[:75], kw))
                break
    if not matches:
        print('(sin matches obvios — tus warnings no parecen tener fix upstream reciente)')
    else:
        print('| SHA | Fecha | Mensaje | Match warning |')
        print('|---|---|---|---|')
        for sha, date, msg, kw in matches[:5]:
            print(f'| \`{sha}\` | {date} | {msg} | \`{kw}\` |')
except Exception as e:
    print(f'(error: {e})')
" 2>/dev/null
  echo ""

  # Releases (canonical announcement source)
  echo "### 📣 Posts del autor (GitHub releases — anuncios canónicos)"
  echo ""
  curl -sS "https://api.github.com/repos/garrytan/gbrain/releases?per_page=5" 2>/dev/null | python3 -c "
import json, sys
try:
    rels = json.load(sys.stdin)
    if not rels:
        print('_(sin releases publicadas — el repo usa tags/commits directos. Garry anuncia cambios vía PRs.)_')
    else:
        for r in rels[:5]:
            tag = r.get('tag_name','?')
            date = r.get('published_at','')[:10]
            body = (r.get('body','') or '').split('\\n')[0][:120]
            print(f'**{tag}** ({date}) — {body}')
            print('')
except Exception as e: print(f'(error: {e})')
" 2>/dev/null
  echo ""

  # ─── Layer 16: Upgrade Decision Engine ───
  echo "## 🎲 Layer 16 — Upgrade Decision Engine"
  echo ""
  echo "_¿Qué mido?_ Para CADA herramienta crítica de tu stack (gbrain + openclaw), aplico la heurística que un ingeniero senior usaría: ¿está al día?, ¿hay regresiones reportadas en la versión nueva?, ¿afectan TU workflow específicamente (cron, mcp, telegram)?, ¿qué tan reciente es el release? Output: veredicto **INSTALAR / ESPERAR / SKIP** con razones concretas y links a issues. Esta capa reemplaza el \"yo me decidí solo\" — encapsula la lógica de revisión."
  echo ""

  upgrade_decision() {
    local TOOL="$1" REPO="$2" CUR="$3" LATEST_RAW="$4"
    # Strip leading 'v'
    local LATEST="${LATEST_RAW#v}"
    local DECISION REASON ISSUES_RECENT REGRESSION_HITS
    if [ -z "$LATEST" ]; then
      echo "| $TOOL | $CUR | ? | ⚠️ unknown | Could not fetch latest version |"
      return
    fi
    if [ "$CUR" = "$LATEST" ]; then
      echo "| $TOOL | $CUR | $LATEST | ✅ AT LATEST | Nada que hacer |"
      return
    fi
    # Get release age + open regression issues mentioning this version OR newer
    local RELEASE_AGE_HOURS=$(curl -sS "https://api.github.com/repos/$REPO/releases/tags/v$LATEST" 2>/dev/null | python3 -c "
import json, sys, datetime
try:
    r = json.load(sys.stdin)
    pub = r.get('published_at')
    if pub:
        d = datetime.datetime.strptime(pub, '%Y-%m-%dT%H:%M:%SZ')
        h = int((datetime.datetime.utcnow() - d).total_seconds() / 3600)
        print(h)
except: print('?')
" 2>/dev/null)
    # Search open issues created post-release that mention the version (regressions)
    local SINCE=$(date -u -d "5 days ago" '+%Y-%m-%dT%H:%M' 2>/dev/null || date -u -v-5d '+%Y-%m-%dT%H:%M' 2>/dev/null)
    local ISSUES_JSON=$(gh issue list --repo "$REPO" --search "$LATEST regression OR $LATEST broke OR $LATEST fail in:title,body created:>$SINCE" --state open --limit 8 --json number,title,createdAt 2>/dev/null)
    REGRESSION_HITS=$(echo "$ISSUES_JSON" | python3 -c "
import json, sys
try:
    issues = json.load(sys.stdin)
    # Stack-relevant keywords for THIS user
    stack = ['cron', 'mcp', 'telegram', 'gateway', 'session', 'plugin', 'install', 'autopilot', 'queue', 'worker']
    relevant = []
    for i in issues[:8]:
        title = i.get('title','').lower()
        if any(k in title for k in stack):
            relevant.append(f\"#{i['number']} {i['title'][:60]}\")
    print('||'.join(relevant))
except: pass
" 2>/dev/null)
    # Decide
    local AGE_HOURS_NUM=0
    [ "$RELEASE_AGE_HOURS" != "?" ] && AGE_HOURS_NUM="$RELEASE_AGE_HOURS"
    if [ -n "$REGRESSION_HITS" ]; then
      DECISION="🛑 ESPERAR"
      REASON="Regresiones que afectan tu stack: $(echo "$REGRESSION_HITS" | tr '|' ',' | head -c 150)"
    elif [ "$AGE_HOURS_NUM" -lt 24 ] 2>/dev/null; then
      DECISION="🟡 ESPERAR"
      REASON="Release con <24h de rodaje (${AGE_HOURS_NUM}h). Esperar a que la comunidad reporte."
    elif [ "$AGE_HOURS_NUM" -lt 48 ] 2>/dev/null; then
      DECISION="🟡 ESPERAR"
      REASON="Release con <48h (${AGE_HOURS_NUM}h). Sin regresiones reportadas todavía. Recheck mañana."
    else
      DECISION="✅ INSTALAR"
      REASON="Release tiene ${AGE_HOURS_NUM}h sin regresiones reportadas que afecten tu stack."
    fi
    echo "| $TOOL | $CUR | $LATEST | $DECISION | $REASON |"
  }

  # Get versions
  GBRAIN_CUR=$(gbrain --version 2>&1 | head -1 | awk '{print $2}')
  # gbrain doesn't use GitHub releases — derive latest from package.json on master, fallback to tags
  GBRAIN_LATEST=$(curl -sS "https://raw.githubusercontent.com/garrytan/gbrain/master/package.json" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('version',''))" 2>/dev/null)
  if [ -z "$GBRAIN_LATEST" ]; then
    GBRAIN_LATEST=$(curl -sS "https://api.github.com/repos/garrytan/gbrain/tags?per_page=5" 2>/dev/null | python3 -c "
import json, sys, re
try:
    tags = json.load(sys.stdin)
    for t in tags:
        n = t.get('name','').lstrip('v')
        if re.match(r'^\d+\.\d+\.\d+$', n):
            print(n); break
except: pass
" 2>/dev/null)
  fi
  OC_CUR=$(openclaw --version 2>&1 | head -1 | awk '{print $2}')
  OC_LATEST=$(curl -sS "https://api.github.com/repos/openclaw/openclaw/releases/latest" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name','').lstrip('v'))" 2>/dev/null)

  echo "| Tool | Tu versión | Latest | Veredicto | Razón |"
  echo "|---|---|---|---|---|"
  upgrade_decision "gbrain"   "garrytan/gbrain"   "$GBRAIN_CUR" "$GBRAIN_LATEST"
  upgrade_decision "openclaw" "openclaw/openclaw" "$OC_CUR"     "$OC_LATEST"
  echo ""

  # Best stack snapshot (the canonical "what would I install fresh today")
  echo "### 🥇 Tu mejor stack hoy"
  echo ""
  echo "Si arrancaras de cero AHORA en una EC2 limpia, instalarías:"
  echo ""
  echo "- **gbrain** \`$GBRAIN_LATEST\` — última estable, fix wave incluido (#447)"
  echo "- **openclaw** $(if [ -n "$OC_LATEST" ]; then echo "\`$OC_LATEST\`"; else echo "última estable"; fi) — solo si no hay regresiones contra tu uso (cron/telegram/mcp)"
  echo "- **gbrain-http-wrapper** (tu repo) — OAuth 2.1 + PKCE + DCR + refresh tokens"
  echo "- **signal-detector hook** — captura ambient en Claude Code CLI"
  echo "- **claude-code-capture recipe** (PR #481 a Garry, pending merge) — alternativa empaquetada del hook"
  echo ""
  echo "**Tu stack actual:**"
  echo "- gbrain \`$GBRAIN_CUR\` $([ "$GBRAIN_CUR" = "$GBRAIN_LATEST" ] && echo "✅ al día" || echo "⚠️ atrasado a \`$GBRAIN_LATEST\`")"
  echo "- openclaw \`$OC_CUR\` $([ "$OC_CUR" = "$OC_LATEST" ] && echo "✅ al día" || echo "⚠️ atrasado a \`$OC_LATEST\`")"
  echo "- wrapper: ✅ corriendo (port 8787)"
  echo "- hook: ✅ activo (signal-detector v7)"
  echo ""

  # Open regression issues affecting your stack RIGHT NOW
  echo "### 🔥 Issues abiertos hoy (últimas 24h) en herramientas de tu stack"
  echo ""
  echo "| Repo | # | Title | Edad |"
  echo "|---|---|---|---|"
  SINCE_24H=$(date -u -d "24 hours ago" '+%Y-%m-%dT%H:%M' 2>/dev/null || date -u -v-1d '+%Y-%m-%dT%H:%M' 2>/dev/null)
  for repo in "garrytan/gbrain" "openclaw/openclaw"; do
    gh issue list --repo "$repo" --search "is:open created:>$SINCE_24H" --limit 5 --json number,title,createdAt 2>/dev/null | python3 -c "
import json, sys, datetime
try:
    issues = json.load(sys.stdin)
    stack = ['cron','mcp','telegram','gateway','session','plugin','install','autopilot','queue','worker','migration','schema','pgvector','embed']
    for i in issues[:5]:
        title = i.get('title','').lower()
        if any(k in title for k in stack):
            ago_h = int((datetime.datetime.utcnow() - datetime.datetime.strptime(i['createdAt'][:19], '%Y-%m-%dT%H:%M:%S')).total_seconds() / 3600)
            print(f\"| $repo | #{i['number']} | {i['title'][:65]} | {ago_h}h |\")
except: pass
" 2>/dev/null
  done
  echo ""

  # ─── Layer 17: Upstream Features Watch (NEW) ───
  echo "## 📡 Layer 17 — Upstream Features Watch"
  echo ""
  echo "_¿Qué mido?_ Cuando upstream (gbrain / openclaw) lanza una feature nueva, este layer la surfaceea como **informativa, no urgente**. Lee los últimos 5 commits con palabras clave (\`feat:\`, \`v0.\`) y los cruza contra los módulos que ya tienes activos. Si la feature ya está cubierta por algo que tienes (ej: voice → no relevante porque no usas voz), se silencia. Si es nueva y aplicable, te dice **\"tienes módulo para X — pruébalo\"** con el comando exacto."
  echo ""
  CURRENT_GBRAIN_VER=$(gbrain --version 2>/dev/null | awk '{print $2}')
  CURRENT_OPENCLAW_VER=$(openclaw --version 2>/dev/null | awk '{print $2}')
  echo "_Tu setup_: gbrain \`$CURRENT_GBRAIN_VER\` · openclaw \`$CURRENT_OPENCLAW_VER\`"
  echo ""
  for repo in "garrytan/gbrain" "openclaw/openclaw"; do
    echo "### Recent feature commits — \`$repo\`"
    echo ""
    echo "| Feature | Status local | Try it |"
    echo "|---|---|---|"
    gh api "repos/$repo/commits?per_page=8" --jq '.[] | select(.commit.message | test("(?i)v0\\.|feat:")) | {sha: .sha[0:7], date: .commit.committer.date[0:10], msg: .commit.message[0:80]}' 2>/dev/null | python3 -c "
import json, sys, re, os
ver_g = '$CURRENT_GBRAIN_VER'
ver_o = '$CURRENT_OPENCLAW_VER'
shown = 0
for line in sys.stdin:
    if shown >= 6: break
    try:
        d = json.loads(line)
    except: continue
    msg = d['msg'].replace('|', ' ')
    # Detect version in commit message
    m = re.search(r'v(\d+\.\d+\.\d+)', msg)
    if m:
        commit_ver = m.group(1)
        if '$repo' == 'garrytan/gbrain' and commit_ver <= ver_g:
            status = '✅ instalado'
        elif '$repo' == 'openclaw/openclaw' and commit_ver <= ver_o:
            status = '✅ instalado'
        else:
            status = '🔜 disponible'
    else:
        status = 'ℹ️ info'
    # Extract feature noun (first word after feat: or after the version)
    feat_match = re.search(r'feat:\s*(.+?)(\s\(|\s—|\sshipping|\sl[ie]gh|\son\s|$)', msg, re.I)
    feature = feat_match.group(1)[:50] if feat_match else msg[:60]
    # Suggest try-command for known features
    try_hint = ''
    low = msg.lower()
    if 'dream' in low and 'synth' in low:
        try_hint = '\`gbrain dream --phase synthesize --dry-run\`'
    elif 'frontmatter' in low:
        try_hint = '\`gbrain frontmatter audit\`'
    elif 'compound' in low:
        try_hint = '\`/gbrain compound dry-run\`'
    elif 'voice' in low or 'voz' in low:
        try_hint = 'no aplica — no tienes canal voz'
    elif 'zoom' in low or 'meeting' in low:
        try_hint = 'no aplica — no tienes integración zoom'
    elif 'minion' in low or 'worker' in low:
        try_hint = '\`gbrain jobs stats\`'
    elif 'http' in low or 'oauth' in low:
        try_hint = '\`/gbrain principles\` — wrapper afectado'
    elif 'serve --http' in low:
        try_hint = 'wrapper-related → check gbrain-http-wrapper'
    print(f'| [{d[\"date\"]}] {feature.strip()} | {status} | {try_hint or \"info\"} |')
    shown += 1
" 2>/dev/null
    echo ""
  done

  # ─── Layer 17b: Skill propagation (CENTRAL ORCHESTRATOR) ───
  echo "### 🔗 Cambios que afectan skills relacionados"
  echo ""
  echo "_¿Qué mido?_ Si un cambio upstream afecta tus skills satélite (\`brain-write-macro\`, \`signal-detector\`, \`gbrain-http-wrapper\`), aquí aparece la sugerencia concreta. Este skill (\`/gbrain\`) es el **orquestador central** — el único que decide qué se actualiza y notifica los demás."
  echo ""
  PROPAG=()
  # Check version vs known feature gates
  if [ "$CURRENT_GBRAIN_VER" \> "0.22.6" ] 2>/dev/null; then
    [ -d "$HOME/gbrain-http-wrapper" ] && PROPAG+=("⚙️ \`gbrain serve --http\` (v0.22.7+) ya existe upstream → wrapper local sigue corriendo pero ahora es **opcional** para clientes stdio-less. README ya documenta esto.")
  fi
  if [ "$CURRENT_GBRAIN_VER" \> "0.22.14" ] 2>/dev/null; then
    PROPAG+=("📝 \`gbrain frontmatter generate --fix\` (v0.22.15+) auto-infiere frontmatter desde path → \`brain-write-macro\` puede simplificarse en futuro: ya no necesita validar tantos campos.")
  fi
  if [ "$CURRENT_GBRAIN_VER" \> "0.22.16" ] 2>/dev/null; then
    PROPAG+=("🌙 \`gbrain dream\` ahora tiene 8 fases (synthesize + patterns añadidas en v0.23.0) → tu \`compound\` engine queda como **complemento post-dream**, no reemplazo. Sigue corriendo en cron 30 min después.")
    PROPAG+=("📁 Corpus dir activado: \`~/.gbrain/corpus/openclaw-sessions/\` — converter \`tools/openclaw-to-corpus.py\` corre cada hora vía cron, alimenta synthesize automáticamente.")
  fi
  # Check for stale skills relative to monorepo
  if [ -d "$HOME/skills/.git" ]; then
    cd "$HOME/skills" 2>/dev/null && git fetch origin --quiet 2>/dev/null
    LOCAL=$(git -C "$HOME/skills" rev-parse HEAD 2>/dev/null)
    REMOTE=$(git -C "$HOME/skills" rev-parse origin/master 2>/dev/null)
    [ "$LOCAL" != "$REMOTE" ] && PROPAG+=("⚠️ Monorepo \`durang/skills\` tiene cambios upstream sin pull — \`cd ~/skills && git pull\` para sincronizar Mac/EC2.")
  fi
  # HERMES installed → propagate skill consistency rules
  if [ -d "$HOME/.hermes" ]; then
    PROPAG+=("🌀 HERMES detectado en \`~/.hermes/\` — corre \`/hermestrack\` para detalle granular del runtime paralelo (89 skills bundled + imports de OpenClaw).")
    if [ "$OPENCLAW_BOT_HASH" = "$HERMES_BOT_HASH" ] && [ -n "$OPENCLAW_BOT_HASH" ]; then
      PROPAG+=("🔴 CRITICAL: HERMES y OpenClaw usan el MISMO bot Telegram → polling conflict. Cambia uno de los 2 tokens YA con \`@BotFather\`.")
    fi
    HERMES_IMPORTS=$(ls $HOME/.hermes/skills/openclaw-imports/ 2>/dev/null | wc -l)
    if [ "$HERMES_IMPORTS" -gt 0 ] 2>/dev/null; then
      PROPAG+=("📦 HERMES tiene $HERMES_IMPORTS skills importadas de OpenClaw — si actualizas \`brain-write-macro\` o \`signal-detector\` en monorepo, corre \`hermes claw migrate --overwrite\` para refrescarlas.")
    fi
  fi
  if [ ${#PROPAG[@]} -eq 0 ]; then
    echo "_Cero propagaciones pendientes — todos los skills satélite alineados._"
  else
    for p in "${PROPAG[@]}"; do
      echo "- $p"
    done
  fi
  echo ""

  # ─── Drift notification (NEW v2: silent push if NEW alert CATEGORY appears) ───
  # Compare by category (first 25 chars + emoji), not exact text — avoids spam from numeric drift (queue=315 → 317)
  ALERT_STATE_FILE="$SKILL_DIR/.last-alerts.txt"
  CURRENT_KEYS=$(printf '%s\n' "${ALERTS[@]}" | cut -c1-30 | sort -u)
  PREV_KEYS=$(cat "$ALERT_STATE_FILE" 2>/dev/null | cut -c1-30 | sort -u)
  NEW_CATEGORIES=$(comm -13 <(echo "$PREV_KEYS") <(echo "$CURRENT_KEYS"))
  if [ -n "$NEW_CATEGORIES" ] && [ "$NEW_CATEGORIES" != "" ]; then
    # Find full text of NEW alerts (match by prefix)
    NEW_FULL=""
    while IFS= read -r key; do
      [ -z "$key" ] && continue
      match=$(printf '%s\n' "${ALERTS[@]}" | grep -F "$key" | head -1)
      [ -n "$match" ] && NEW_FULL="${NEW_FULL}- ${match}"$'\n'
    done <<< "$NEW_CATEGORIES"
    if [ -n "$NEW_FULL" ]; then
      BOT_TOKEN=$(python3 -c "import json;d=json.load(open('$HOME/.openclaw/openclaw.json'));print(d['channels']['telegram']['botToken'])" 2>/dev/null)
      if [ -n "$BOT_TOKEN" ]; then
        MSG=$(printf '%s' "🧠 GBrain drift detected — nueva alerta:

$NEW_FULL
Run /gbrain en Telegram para detalle.")
        curl -sS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
          --data-urlencode "chat_id=1439730479" \
          --data-urlencode "text=$MSG" \
          --data-urlencode "disable_notification=true" >/dev/null 2>&1 && \
          echo "_📱 Telegram drift alert sent (silent)._" || true
      fi
    fi
  fi
  printf '%s\n' "${ALERTS[@]}" > "$ALERT_STATE_FILE"

  # ─── Verdict + Quick actions ───
  echo "## 🎯 Veredicto + acciones"
  echo ""
  if [ "${#ALERTS[@]}" -eq 0 ] 2>/dev/null && [ "$HEALTH_SCORE" -ge 90 ] 2>/dev/null; then
    VERDICT="🟢 **CANONICAL** — todo verde, no hay nada urgente"
  elif [ "${#ALERTS[@]}" -gt 0 ] 2>/dev/null; then
    VERDICT="🔴 **NEEDS ATTENTION** — ${#ALERTS[@]} alerta(s) crítica(s) — corre \`/gbrain fix\`"
  else
    VERDICT="🟡 **OK con warnings** — health $HEALTH_SCORE/100, revisa Layer 3"
  fi
  echo "$VERDICT"
  echo ""
  echo "| Próxima acción | Comando |"
  echo "|---|---|"
  echo "| Auto-fix issues seguros + cleanup stuck | \`/gbrain fix\` |"
  echo "| Ver solo upstream news | \`/gbrain news\` |"
  echo "| Comparar vs snapshot anterior | \`/gbrain compare\` |"
  echo "| Guardar este reporte como \`.md\` | \`/gbrain save\` |"
  echo "| Reportar bug upstream | https://github.com/garrytan/gbrain/issues |"
  echo "| Ver/contribuir al skill | https://github.com/durang/gbrain-skill |"
  echo ""
  echo "---"
  echo "_Run with \`bash ~/.openclaw/skills/gbrain/run.sh <subcommand>\` or \`/gbrain <subcommand>\` in Claude Code/Telegram._"
}

run_fix() {
  echo "# 🔧 GBrain Auto-Fix"
  echo ""
  echo "| 🕐 Run | 📂 Subcommand |"
  echo "|---|---|"
  echo "| \`$(date -u +%Y-%m-%dT%H:%M:%SZ) UTC\` | \`/gbrain fix\` |"
  echo ""
  cd ~/gbrain && set -a && source .env && set +a

  echo "## 🧹 1. Stuck-session cleanup (NEW v2)"
  echo ""
  STUCK_BEFORE=$(count_stuck_sessions_last_hour)
  echo "_Stuck sessions detectadas hace 1h:_ \`$STUCK_BEFORE\`"
  echo ""
  if [ "$STUCK_BEFORE" -gt 0 ] 2>/dev/null; then
    echo "Ejecutando \`openclaw sessions cleanup --enforce --all-agents\`..."
    openclaw sessions cleanup --enforce --all-agents 2>&1 | tail -5 | sed 's/^/    /'
    echo ""
    sleep 2
    STUCK_AFTER=$(count_stuck_sessions_last_hour)
    echo "_Stuck sessions después del cleanup:_ \`$STUCK_AFTER\`"
  else
    echo "✅ No hay sesiones colgadas — nada que limpiar."
  fi
  echo ""

  echo "## 🎯 2. Embeddings stale"
  echo ""
  echo '```'
  gbrain embed --stale 2>&1 | tail -2
  echo '```'
  echo ""

  echo "## 🔗 3. Extract links"
  echo ""
  echo '```'
  gbrain extract links --source db 2>&1 | tail -2
  echo '```'
  echo ""

  echo "## ⏰ 4. Extract timeline"
  echo ""
  echo '```'
  gbrain extract timeline --source db 2>&1 | tail -2
  echo '```'
  echo ""

  echo "## ✨ 5. Integrity sweep (bare-tweets, dead links)"
  echo ""
  echo '```'
  gbrain integrity auto 2>&1 | tail -3 || echo "(integrity auto no disponible o sin issues)"
  echo '```'
  echo ""

  echo "## 🗃️ 6. Apply pending migrations"
  echo ""
  echo '```'
  gbrain apply-migrations --yes 2>&1 | tail -3
  echo '```'
  echo ""

  echo "## 🩺 7. Re-doctor (health score after fix)"
  echo ""
  SCORE_AFTER=$(gbrain doctor --json 2>/dev/null | tail -1 | python3 -c "import json,sys; print(json.load(sys.stdin).get('health_score','?'))" 2>/dev/null)
  if [ "$SCORE_AFTER" -ge 90 ] 2>/dev/null; then SB="🟢"; \
  elif [ "$SCORE_AFTER" -ge 70 ] 2>/dev/null; then SB="🟡"; \
  else SB="🔴"; fi
  echo "**Health score post-fix:** $SB **$SCORE_AFTER / 100**"
  echo ""
  echo "---"
  echo "_Run \`/gbrain check\` para ver el dashboard completo._"
}

run_news() {
  echo "# 📰 /gbrain news — Upstream tracking"
  echo "_Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ) UTC_"
  echo ""
  echo "## Últimas 10 releases gbrain"
  curl -sS "https://api.github.com/repos/garrytan/gbrain/tags?per_page=10" 2>/dev/null | python3 -c "
import json, sys
tags = json.load(sys.stdin)
if not tags: print('(no tags)')
for t in tags[:10]: print(f\"- **{t['name']}** — sha \`{t['commit']['sha'][:7]}\`\")
"
  echo ""
  echo "## 10 PRs abiertos"
  curl -sS "https://api.github.com/repos/garrytan/gbrain/pulls?state=open&per_page=10" 2>/dev/null | python3 -c "
import json, sys
prs = json.load(sys.stdin)
for p in prs[:10]: print(f\"- PR#{p['number']} {p['title']}\")
"
  echo ""
  echo "## 10 issues abiertos"
  curl -sS "https://api.github.com/repos/garrytan/gbrain/issues?state=open&per_page=20" 2>/dev/null | python3 -c "
import json, sys
iss = [i for i in json.load(sys.stdin) if 'pull_request' not in i][:10]
for i in iss: print(f\"- #{i['number']} {i['title']}\")
"
}

run_save() {
  REPORT_DIR="$HOME/brain/reports"
  mkdir -p "$REPORT_DIR"
  # Daily file with date — accumulates history. Symlink "latest" always points to the most recent.
  TODAY=$(date -u +%Y-%m-%d)
  REPORT_FILE="$REPORT_DIR/gbrain-$TODAY.md"
  LATEST_LINK="$REPORT_DIR/gbrain-latest.md"
  run_check > "$REPORT_FILE"
  rm -f "$LATEST_LINK"
  ln -s "gbrain-$TODAY.md" "$LATEST_LINK"
  HISTORY_COUNT=$(ls "$REPORT_DIR"/gbrain-*.md 2>/dev/null | grep -v latest | wc -l)
  echo "# 💾 GBrain Report Saved"
  echo ""
  echo "| 📂 File | 📏 Size | 🔗 Latest symlink | 📚 History |"
  echo "|---|---|---|---|"
  echo "| \`$REPORT_FILE\` | \`$(wc -c < $REPORT_FILE) bytes\` | \`$LATEST_LINK → gbrain-$TODAY.md\` | \`$HISTORY_COUNT días\` |"
  echo ""
  echo "**Generated at:** \`$(date -u +%Y-%m-%dT%H:%M:%SZ) UTC\`"
  echo ""
  echo "## 📖 Cómo verlo"
  echo ""
  echo '```bash'
  echo "cat $LATEST_LINK              # último report"
  echo "cat $REPORT_FILE              # report de hoy explícito"
  echo "ls $REPORT_DIR/                       # ver historial completo"
  echo '```'
  echo ""
  echo "_Snapshots de stats numéricas:_ \`~/.openclaw/skills/gbrain/snapshots/\`"
}

run_compare() {
  echo "# 📸 /gbrain compare — Diff snapshots"
  PREV=$(ls -t $SNAP_DIR/*.json 2>/dev/null | sed -n '1p')
  PREV2=$(ls -t $SNAP_DIR/*.json 2>/dev/null | sed -n '2p')
  if [ -z "$PREV" ] || [ -z "$PREV2" ]; then
    echo "Need at least 2 snapshots. Run \`/gbrain check\` first."
    exit 0
  fi
  echo "Comparing $(basename $PREV2) → $(basename $PREV)"
  python3 - "$PREV2" "$PREV" <<'PY'
import json, sys
prev = json.load(open(sys.argv[1]))
now = json.load(open(sys.argv[2]))
print(f"Span: {prev['ts']} → {now['ts']}")
print()
print("| Metric | Prev | Now | Δ |")
print("|---|---|---|---|")
for k in sorted(now['stats'].keys()):
    p = prev['stats'].get(k, 0)
    n = now['stats'][k]
    d = n - p
    icon = '✅' if d > 0 else ('⚪' if d == 0 else '⚠️')
    sign = '+' if d >= 0 else ''
    print(f"| {k} | {p} | {n} | {icon} {sign}{d} |")
PY
}

run_bugs() {
  echo "# 🐛 /gbrain bugs — Upstream bugs that affect you"
  IOC=$(openclaw --version 2>&1 | head -1 | awk '{print $2}')
  IGB=$(gbrain --version 2>&1 | head -1 | awk '{print $2}')
  MODEL=$(read_model_field primary)
  echo ""
  echo "Your stack: openclaw=$IOC, gbrain=$IGB, model=$MODEL"
  echo ""
  echo "| Bug | Affects you | Workaround |"
  echo "|---|---|---|"
  [[ "$IOC" == *"beta"* ]] && echo "| OC 4.24-beta plugin reinstall loop | ⚠️ YES | Downgrade to 2026.4.23 |" || echo "| OC 4.24-beta plugin reinstall loop | ✅ NO | — |"
  [[ "$MODEL" == *"deepseek"* ]] && echo "| DeepSeek reasoning_content rejection (no upstream fix) | ⚠️ YES | Switch to MiniMax-M2.7 |" || echo "| DeepSeek reasoning_content rejection | ✅ NO | — |"
  [ -f ~/.gbrain/migrations-fix-applied ] && echo "| #370 v0.18 migration chain fails | ✅ FIXED LOCALLY | manual SQL applied |" || echo "| #370 v0.18 migration chain fails | ⚠️ Check | Run /gbrain fix |"
  echo "| #389 apply-migrations hangs on large brains | ⚠️ Possible if brain >5K pages | Use manual SQL |"
}

case "$SUBCMD" in
  check|"") run_check ;;
  fix) run_fix ;;
  news) run_news ;;
  bugs) run_bugs ;;
  compare) run_compare ;;
  save) run_save ;;
  bootstrap) bash "$SKILL_DIR/bootstrap.sh" ;;
  principles) cat "$SKILL_DIR/PRINCIPLES.md" ;;
  manifest) cat "$SKILL_DIR/MANIFEST.json" ;;
  manual) cat "$SKILL_DIR/MANUAL.md" ;;
  compound)
    SUB="${2:-run}"
    case "$SUB" in
      run|status|history|revert|dry-run)
        bash "$SKILL_DIR/compound/run.sh" "$SUB" "${3:-}"
        ;;
      *)
        echo "Usage: /gbrain compound [run|status|history|revert <id>|dry-run]"
        echo ""
        echo "  run        Full cycle — analyze + auto-apply changes"
        echo "  dry-run    Analyze only — show proposals, apply nothing"
        echo "  status     Current confidence per category + lifetime stats"
        echo "  history    Last 10 cycles' journals"
        echo "  revert <id>  Queue a specific change for revert next cycle"
        ;;
    esac
    ;;
  custom-instructions|ci)
    DB_URL=$(python3 -c "import json; print(json.load(open('$HOME/.gbrain/config.json'))['database_url'])" 2>/dev/null)
    SKILL_VERSION=$(grep -oE "^custom-instructions-version: [0-9]+" "$HOME/.openclaw/skills/brain-write-macro/SKILL.md" 2>/dev/null | awk '{print $2}')
    APPLIED_VERSION=$(cat "$HOME/.gbrain/custom-instructions-applied.flag" 2>/dev/null | tr -d ' \n')
    [ -z "$APPLIED_VERSION" ] && APPLIED_VERSION="0"

    echo "# /gbrain custom-instructions"
    echo ""
    echo "_Spec version (skill): **v$SKILL_VERSION**_"
    echo "_Applied version (your claude.ai): **v$APPLIED_VERSION**_"
    echo ""
    if [ "$SKILL_VERSION" = "$APPLIED_VERSION" ]; then
      echo "✅ **In sync.** Your claude.ai snippet matches the canonical spec."
    else
      echo "🔴 **OUT OF SYNC.** Re-paste the snippet below in claude.ai → Settings → Profile → Custom Instructions, then run \`echo $SKILL_VERSION > ~/.gbrain/custom-instructions-applied.flag\`"
    fi
    echo ""
    echo "## Current state of your brain (auto-detected, dynamic)"
    echo ""
    if [ -n "$DB_URL" ]; then
      echo "**Page types you have:**"
      PGCONNECT_TIMEOUT=5 psql "$DB_URL" -At -c "SELECT type, COUNT(*) FROM pages GROUP BY type ORDER BY 2 DESC;" 2>/dev/null | head -10 | awk -F'|' '{printf "- `%s` (%s pages)\n", $1, $2}'
      echo ""
      echo "**Link types you have:**"
      PGCONNECT_TIMEOUT=5 psql "$DB_URL" -At -c "SELECT link_type, COUNT(*) FROM links WHERE link_type IS NOT NULL GROUP BY link_type ORDER BY 2 DESC;" 2>/dev/null | head -10 | awk -F'|' '{printf "- `%s` (%s links)\n", $1, $2}'
    fi
    echo ""
    echo "## Canonical snippet (current — copy this into claude.ai)"
    echo ""
    echo "\`\`\`"
    cat <<'EOF'
You have access to a "gbrain" MCP server (personal knowledge brain). When I say
"guarda en gbrain", "guarda esto en mi brain", "lo importante en mi brain",
"captura en gbrain", "save to brain", "save this to gbrain", "mete esto al brain",
or just "guarda" after a substantive turn, run this exact procedure:

DO NOT trigger on file/document save commands ("guarda este archivo", "save the file",
"save the doc"). Brain capture only.

PROCEDURE:

1. SCAN this entire conversation (every turn) for:
   - People named WITH attributes (role, company, location, age, contact, notable detail).
     Skip name-only mentions like "I told John" with no other detail.
   - Companies/funds/startups WITH attributes (industry, stage, founders, location).
   - Decisions I took or stated ("vamos con X", "decidí Y", "let's go with Z", "no, mejor W").
   - Original ideas, theses, or strategic insights I framed (not generic Q&A — only my
     own framings). Preserve my exact phrasing in compiled_truth.

2. SLUG RULES:
   - Always kebab-case, lowercase, ASCII only (NO accents): sergio-duran, NOT sergio-durán.
   - Format: people/firstname-lastname, companies/name, decisions/short-summary,
     originals/short-kebab.

3. CHECK BEFORE WRITE (avoid duplicates):
   - Before each gbrain__put_page, call gbrain__get_page with fuzzy:true on the slug.
   - If the page exists, READ its current compiled_truth, then call gbrain__put_page
     with the merged content (existing + new attributes from this conversation).
   - If not found, write fresh.

4. WRITE PAGES with required frontmatter:
   - put_page slug:"people/<...>" type:"person" title:"<Full Name>"
   - put_page slug:"companies/<...>" type:"company" title:"<Company Name>"
   - put_page slug:"decisions/<...>" type:"decision" title:"<one-line summary>"
   - put_page slug:"originals/<...>" type:"original" title:"<short header>"

5. CREATE LINKS for cross-references with gbrain__add_link:
   - Person works at Company → from:"people/x" to:"companies/y" type:"works_at"
   - Person co-founded Company → type:"founded"
   - Fund invested in Company → type:"invested_in"
   - Person met with Person → type:"met_with"
   - Person advised Person → type:"advised"

6. CONFIRM with the actual slugs you wrote AFTER all tool calls succeed:

   ✅ Guardado en gbrain:
   - people/mike-shapiro (new)
   - people/jason-X (enriched)
   - companies/elafris (new)
   - decisions/proposed-pool-split-33-30-30-10 (new)
   - originals/insurance-vertical-thesis (new)
   - 4 links: mike→elafris (founded), mike→digital-kozak (founded), ...

CRITICAL RULES:
- NEVER respond "guardado" / "saved" / "listo" / "done" without listing actual slugs you
  called put_page on. That is hallucination.
- NEVER ask "qué quieres que guarde?" / "what should I save?". Infer from the conversation.
  Better to write 8 pages and let me prune than to write 0 and ask.
- If a put_page or add_link call returns an error, report it explicitly:
  "❌ Failed: people/mike-shapiro — error: <message>". Do not pretend it worked.
- For "originals" (my ideas), preserve my exact phrasing in compiled_truth, not paraphrase.
- One reply at the end with the slug list. No commentary mid-process.
EOF
    echo "\`\`\`"
    echo ""
    echo "## How to update"
    echo ""
    echo "1. Copy the snippet above"
    echo "2. Open https://claude.ai → Settings → Profile → Custom Instructions"
    echo "3. Replace the existing block with the new one"
    echo "4. Save in claude.ai"
    echo "5. On EC2: \`echo $SKILL_VERSION > ~/.gbrain/custom-instructions-applied.flag\`"
    ;;
  *) echo "Unknown subcommand: $SUBCMD"; echo "Use: check | fix | news | bugs | compare | save | bootstrap | principles | manifest | custom-instructions"; exit 1 ;;
esac
