# GBrain Canonical Review Protocol

Documento de cabecera para revisar GBrain + OpenClaw. Cada sección dice **qué archivo
revisar, cómo debe estar, y cómo arreglar si está mal**.

---

## 📂 Archivos canónicos a revisar (en orden)

| # | Archivo | Cómo debe estar | Si está mal |
|---|---|---|---|
| 1 | `~/.openclaw/openclaw.json` | JSON válido, `agents.defaults.model` apunta a un modelo soportado, `mcp.servers.gbrain` registrado | `python3 -c "import json; json.load(open('~/.openclaw/openclaw.json'))"` para validar; restaurar de `.bak` si rompió |
| 2 | `~/SOUL.md` | Iron Rule #1 (signal-detector) presente con tool calls explícitos. Updated date reciente | Editar y restart gateway para invalidar cache TTL=1h |
| 3 | `~/MEMORY.md` | Memoria persistente de Jarvis. Crece monotónicamente | NO borrar, solo append |
| 4 | `~/.openclaw/workspace/AGENTS.md` | System prompt extendido del agente "main" | Editar con cuidado, restart gateway |
| 5 | `~/gbrain/.env` | OPENAI_API_KEY, ANTHROPIC_API_KEY, DATABASE_URL, GBRAIN_ALLOW_SHELL_JOBS=1, TELEGRAM_BOT_TOKEN, DEEPSEEK_API_KEY | Probar cada key con `curl` directo |
| 6 | `~/.bashrc` y `~/.zshrc` | Source `~/gbrain/.env` con `set -a; . ~/gbrain/.env; set +a` | Patrón canónico per `src/commands/autopilot.ts:writeWrapperScript` |
| 7 | `~/.gbrain/preferences.json` | Trackea minion_mode + completedMigrations. Si vacío → migrations sin ledger | Bug upstream: nunca borrar |
| 8 | `~/.gbrain/autopilot.lock` | Lock file efímero | Si stuck >10min, borrar manual |
| 9 | `~/.openclaw/skills/<skill>/SKILL.md` | Frontmatter YAML válido + secciones requeridas | Validate con `openclaw skills list` |
| 10 | `~/brain/` (git repo) | Estructura MECE: people/, companies/, concepts/, meetings/, ideas/, originals/ | `gbrain doctor` chequea integrity |

---

## 🔍 6 Métodos canónicos de detección de bugs

### Método 1: GitHub Issues abiertos

```bash
curl -sS "https://api.github.com/repos/garrytan/gbrain/issues?state=open&per_page=20" \
  | python3 -c "import json,sys; [print(f\"#{i['number']} {i['title'][:90]}\") for i in json.load(sys.stdin)]"
```
**Si tu error matchea con título de un issue → no eres tú, es upstream. NO modifiques DB.**

### Método 2: Search específico de tu error

```bash
ERROR_KEYWORD="symbol_name"  # tu error específico
curl -sS "https://api.github.com/search/issues?q=repo:garrytan/gbrain+${ERROR_KEYWORD}" \
  | python3 -c "import json,sys; [print(f\"#{i['number']} [{i['state']}] {i['title']}\") for i in json.load(sys.stdin).get('items',[])[:8]]"
```

### Método 3: PRs abiertos (fixes pendientes)

```bash
curl -sS "https://api.github.com/repos/garrytan/gbrain/pulls?state=open&per_page=20" \
  | python3 -c "import json,sys; [print(f\"PR#{p['number']} {p['title']}\") for p in json.load(sys.stdin)]"
```

### Método 4: CHANGELOG local (qué cambió en cada versión)

```bash
grep -B1 -A30 "## \[0.X.0\]" ~/gbrain/CHANGELOG.md  # X = tu versión
grep -A20 "## To take advantage of v0.X" ~/gbrain/CHANGELOG.md
```
**El bloque "To take advantage of vX.Y" es la guía oficial de upgrade.**

### Método 5: Schema diff (DB real vs SQL esperado)

```bash
PGPASSWORD=$(echo $DATABASE_URL | sed 's/.*:\([^@]*\)@.*/\1/') \
  psql "$DATABASE_URL" -c "\d <table>"
grep -B2 -A20 "ALTER TABLE <table>" ~/gbrain/src/core/migrate.ts
diff <(esperado) <(real)
```

### Método 6: Doctor canónico + log scan

```bash
gbrain doctor --json | tail -1 | python3 -c "
import json,sys
d=json.load(sys.stdin)
[print(f'{c[\"status\"]}: {c[\"name\"]}: {c[\"message\"]}') for c in d['checks'] if c['status']!='ok']"

grep -E "$(date +%Y-%m-%dT%H)" /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log \
  | grep -iE "ERROR|reject|fail" \
  | grep -oE "rawErrorPreview\":\"[^\"]{0,200}" \
  | sort -u
```

---

## 📰 Tracking upstream (mantener al día)

### Última versión disponible

```bash
# GBrain
curl -sS https://raw.githubusercontent.com/garrytan/gbrain/master/VERSION

# OpenClaw
npm view openclaw dist-tags  # latest=stable, beta=preview
```

### Tweets recientes de Garry Tan
- @garrytan en X — anuncia releases con "GBrain v0.X.Y now adds..."
- Pin tweet del repo: muestra latest feature
- Nitter / TweetDeck para search histórico

### Releases con changelog completo
- `https://github.com/garrytan/gbrain/releases` — release notes con "To take advantage of"
- `https://github.com/openclaw/openclaw/releases` — para OpenClaw

---

## 🚨 Bugs upstream conocidos al día de hoy (2026-04-25)

| Issue | Título | Afecta | Workaround |
|---|---|---|---|
| #389 | apply-migrations hangs indefinitely on large brains | Brains con 8800+ pages, schema v10→v24 | Esperar fix upstream |
| #378 | Upgrade v0.17.x → v0.18.x fails: SCHEMA_SQL runs before migrations | Cualquiera upgrading from 0.17 | Aplicar migrations 24-28 manualmente con SQL idempotente |
| #370 | v0.18 migration chain fails: `column "X" does not exist` | Brains que upgradean de v16→v24 | Bug RAÍZ del nuestro |
| #391 | v0.19 WASM crash on macOS 25.3 / Bun 1.3.12 | macOS users (no afecta Linux/EC2) | N/A para nuestro setup |
| OpenClaw 4.24-betas | Plugin runtime deps install loop | Cualquiera en betas | ⚠️ Persiste en 2026.4.24 stable — verificado 2026-04-26: dispara `npm install` con ~80 paquetes, gateway colgado >10 min. Quedarse en `2026.4.23` |
| OpenClaw + DeepSeek | `reasoning_content must be passed back` | DeepSeek-Reasoner / V4-Pro / V4-Flash | ✅ FIXED upstream en 2026.4.24 (issue #71372) — pero requiere v2026.4.24 instalable. Esperar fix del install loop |

---

## ⚙️ Setup canónico verificado al 2026-04-25

| Componente | Versión | Razón |
|---|---|---|
| OpenClaw | `2026.4.23` (stable estable) | v2026.4.24 stable disponible pero tiene plugin install loop bug verificado 2026-04-26 — esperar fix |
| GBrain | `0.21.0` | Última de Garry, tweet del 25-abr |
| Modelo agente main | `minimax-portal/MiniMax-M2.7` | DeepSeek bug; Sonnet caro; MiniMax compatible y sigue SOUL.md |
| MCP gbrain | registrado en `mcp.servers` | Expone 28 tools al agente |
| Skills gbrain copiadas a `~/.openclaw/skills/` | signal-detector, brain-ops, idea-ingest, media-ingest, meeting-ingestion, soul-audit, cross-modal-review, citation-fixer | Symlinks rechazados por security; copy hasta que se haga PR upstream |

---

## ✅ ¿Es normal este proceso de batalla?

**SÍ, es normal y la comunidad lo vive igual.**

GBrain está en versión 0.X (pre-1.0). Es proyecto activo de Garry Tan con commits diarios. Cada 2-3 días sale versión nueva. Los issues #370, #378, #389 muestran que la migration path tiene rough edges. La comunidad reporta bugs y Garry corrige rápido (40+ issues abiertos hoy = mucha actividad sana).

**Lo que la comunidad batalla típicamente:**
1. Migration chain con DBs heterogéneos (postgres vs pglite, schemas mixtas)
2. OpenClaw integration: el plugin runtime gbrain v0.4.1 no implementa el SDK (solo manifest)
3. DeepSeek thinking — provider rechaza schema sin reasoning_content handler — fix upstream existe en v2026.4.24 pero esa versión tiene plugin install loop bug separado, así que el bug DeepSeek aún bloquea uso real
4. Cache TTL: cambios a SOUL.md no toman efecto hasta restart gateway o /new session

**Fix canónico para cada uno:**
1. → `gbrain apply-migrations --yes`, si falla aplicar SQL idempotente manual (migrations en `migrate.ts` están con `IF NOT EXISTS`, son safe)
2. → Copiar skills + registrar MCP server (NO usar el bundle-plugin runtime)
3. → MiniMax-M2.7 hasta fix upstream
4. → Después de cada edit a SOUL.md o openclaw.json: `openclaw gateway restart` + en Telegram `/new`
