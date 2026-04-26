#!/bin/bash
# /gbrain — runnable script. Usage:
#   bash ~/.openclaw/skills/gbrain/run.sh           → full dashboard
#   bash ~/.openclaw/skills/gbrain/run.sh fix       → auto-fix safe issues
#   bash ~/.openclaw/skills/gbrain/run.sh news      → upstream news only
#   bash ~/.openclaw/skills/gbrain/run.sh bugs      → bugs that affect you
#   bash ~/.openclaw/skills/gbrain/run.sh compare   → diff vs last snapshot
#   bash ~/.openclaw/skills/gbrain/run.sh save      → full + save markdown to ~/brain/reports/

set -e
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
  echo "# 🧠 GBrain Canonical Dashboard"
  echo "_Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ) UTC_"
  echo ""
  echo "> **Hola Sergio 👋** — Este es tu panel de control de GBrain + OpenClaw."
  echo "> Te explico cada sección abajo. Si algo está ⚠️ o ❌, te digo cómo arreglarlo."
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
  [ "$STUCK" -gt 0 ] 2>/dev/null && ALERTS+=("🔴 **$STUCK stuck session(s)** en última hora — el agente está colgándose")
  [ "$KEYS" -eq 0 ] 2>/dev/null && ALERTS+=("🔴 **openclaw-node sin API keys** en su environment — fix: \`EnvironmentFile=\` en el systemd unit")
  [ "$FB_COUNT" -eq 0 ] 2>/dev/null && ALERTS+=("🟠 **Modelo sin fallbacks** — si MiniMax timeouts, la sesión muere. Configura \`agents.defaults.model.fallbacks\`")
  [ "$QUEUE_DEPTH" -gt 100 ] 2>/dev/null && ALERTS+=("🟠 **Queue depth=$QUEUE_DEPTH** en autopilot-cycle — workers atorados")
  if [ "${#ALERTS[@]}" -gt 0 ]; then
    echo "## 🚨 Alertas críticas"
    echo ""
    for a in "${ALERTS[@]}"; do echo "- $a"; done
    echo ""
    echo "---"
    echo ""
  fi

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

  # ─── Layer 12: Stuck sessions ───
  echo "## ⏱️ Layer 12 — Stuck sessions (última hora)"
  echo ""
  echo "_¿Qué mido?_ Cuento entradas \`stuck session\` en el log de openclaw de la última hora. Es el síntoma directo de \"JARVIS no responde\": una sesión queda en \`state=processing\` por minutos sin completar. Si >0, hay un cuello de botella (modelo timeout, MCP timeout, o cron atorado)."
  echo ""
  STUCK_COUNT=$(count_stuck_sessions_last_hour)
  if [ "$STUCK_COUNT" -gt 0 ] 2>/dev/null; then
    echo "🔴 **$STUCK_COUNT stuck session(s) en última hora** — revisar en \`/tmp/openclaw/openclaw-$(date -u +%Y-%m-%d).log\`"
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

  # ─── Verdict ───
  echo "## 🎯 Verdict"
  echo ""
  echo "Si todo es ✅ → GBrain canónico al 100%."
  echo "Si hay ⚠️/❌ → corre \`bash ~/.openclaw/skills/gbrain/run.sh fix\` para auto-fix de issues seguros."
  echo "Bugs upstream → reportar en https://github.com/garrytan/gbrain/issues"
}

run_fix() {
  echo "# 🔧 /gbrain fix — Auto-fix issues seguros"
  echo "_Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ) UTC_"
  echo ""
  cd ~/gbrain && set -a && source .env && set +a
  echo "## 1. Embeddings stale"
  gbrain embed --stale 2>&1 | tail -2
  echo ""
  echo "## 2. Extract links"
  gbrain extract links --source db 2>&1 | tail -2
  echo ""
  echo "## 3. Extract timeline"
  gbrain extract timeline --source db 2>&1 | tail -2
  echo ""
  echo "## 4. Integrity sweep (auto-fix bare-tweets, dead links)"
  gbrain integrity auto 2>&1 | tail -3 || echo "(integrity auto no disponible o sin issues)"
  echo ""
  echo "## 5. Apply pending migrations"
  gbrain apply-migrations --yes 2>&1 | tail -3
  echo ""
  echo "## 6. Re-doctor"
  gbrain doctor --json 2>&1 | tail -1 | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'**Health score: {d[\"health_score\"]}/100**')"
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
  # Single canonical file — overwrites every time. No accumulation.
  REPORT_FILE="$REPORT_DIR/gbrain-latest.md"
  run_check > "$REPORT_FILE"
  echo "📝 Reporte guardado (sobreescrito): $REPORT_FILE"
  echo "Tamaño: $(wc -c < $REPORT_FILE) bytes"
  echo "Última corrida: $(date -u +%Y-%m-%dT%H:%M:%SZ) UTC"
  echo ""
  echo "Para verlo: cat $REPORT_FILE"
  echo "Para ver historial: los snapshots de stats (pages/links/etc.) se guardan en:"
  echo "  ~/.openclaw/skills/gbrain/snapshots/"
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
  *) echo "Unknown subcommand: $SUBCMD"; echo "Use: check | fix | news | bugs | compare | save"; exit 1 ;;
esac
