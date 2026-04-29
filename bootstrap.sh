#!/usr/bin/env bash
# /gbrain bootstrap — verifica que el host actual tenga TODO lo del MANIFEST.json instalado correctamente.
# Si falta algo, reporta + propone install steps. Idempotente.
#
# Diseño:
#   - NO hace cambios sin confirmación explícita (todos los install_cmd se imprimen, no se ejecutan)
#   - Lee MANIFEST.json como fuente única de verdad
#   - Output diferenciado: ✅ OK / 🟡 manual action needed / 🔴 missing/broken
#   - Exit 0 si todo OK, exit 1 si hay missing/broken (para CI/cron uso)

set -uo pipefail

MANIFEST="$HOME/.openclaw/skills/gbrain/MANIFEST.json"
[ ! -f "$MANIFEST" ] && { echo "❌ MANIFEST.json no existe en $MANIFEST"; exit 2; }

# Helper: jq-lite via python3 to avoid external dep
manifest_get() {
  python3 -c "import json,sys; d=json.load(open('$MANIFEST')); v=d
for k in '$1'.split('.'):
    v = v.get(k, {}) if isinstance(v, dict) else v
print(json.dumps(v))" 2>/dev/null
}

ISSUES=0
PASS=0
TOTAL=0

echo "# /gbrain bootstrap — canonical state verification"
echo ""
echo "_Manifest version: $(manifest_get version | tr -d '\"')_"
echo "_Last updated: $(manifest_get last_updated | tr -d '\"')_"
echo ""

# ═════════════ Section 1: core_tools ═════════════
echo "## 🔧 Core tools"
echo ""
echo "| Tool | Path | Version | Status |"
echo "|---|---|---|---|"
python3 << EOF
import json, os, subprocess
m = json.load(open('$MANIFEST'))
for tool in m['components']['core_tools']:
    # Resolve path: prefer resolve_path_cmd if defined, else use expected_path with envvar expansion
    if tool.get('resolve_path_cmd'):
        try:
            path = subprocess.check_output(tool['resolve_path_cmd'], shell=True, text=True, stderr=subprocess.DEVNULL).strip().split('\n')[0]
        except Exception:
            path = ''
    else:
        path = os.path.expandvars(tool.get('expected_path', ''))
    exists = path and os.path.exists(path)
    status = "❌ missing" if not exists else "✅"
    version = "-"
    if exists:
        try:
            v = subprocess.check_output(tool['version_cmd'], shell=True, text=True, stderr=subprocess.DEVNULL).strip()
            version = v or "?"
            if v < tool.get('expected_version_min', '0'):
                status = f"🟡 v{v} < min v{tool['expected_version_min']}"
        except Exception as e:
            version = f"err: {str(e)[:30]}"
            status = "🔴 cannot run"
    display_path = (path or '?')[:60]
    print(f"| \`{tool['id']}\` | \`{display_path}\` | {version} | {status} |")
    if not exists:
        install = tool.get('install_cmd', '_(no install_cmd in manifest)_')
        print(f"|   | _Install:_ \`{install}\` | | |")
EOF
echo ""

# ═════════════ Section 2: skills ═════════════
echo "## 🎯 Skills"
echo ""
echo "| Skill | Path | Files OK | Manual action |"
echo "|---|---|---|---|"
python3 << EOF
import json, os
m = json.load(open('$MANIFEST'))
for sk in m['components']['skills']:
    path = os.path.expandvars(sk['path'])
    if not os.path.isdir(path):
        print(f"| \`{sk['id']}\` | \`{path}\` | ❌ dir missing | mkdir -p \`{path}\` |")
        continue
    missing = [f for f in sk['required_files'] if not os.path.isfile(os.path.join(path, f))]
    files_ok = "✅ all" if not missing else f"🔴 missing: {', '.join(missing)}"
    manual = "—"
    if sk.get('manual_user_action'):
        flag = sk.get('custom_instructions_flag', '')
        if flag:
            flag = os.path.expandvars(flag)
            if os.path.exists(flag):
                with open(flag) as f: applied_v = f.read().strip() or "0"
                req_v = str(sk.get('custom_instructions_version', ''))
                if applied_v == req_v:
                    manual = f"✅ v{applied_v} applied"
                else:
                    manual = f"🟡 v{applied_v} applied, need v{req_v} — repaste at claude.ai"
            else:
                manual = "🟡 not applied — see SKILL.md for snippet"
    print(f"| \`{sk['id']}\` | \`{path[:40]}\` | {files_ok} | {manual} |")
EOF
echo ""

# ═════════════ Section 3: wrappers + services ═════════════
echo "## 🛰️ Wrappers & services"
echo ""
echo "| Service | Status | Health probe |"
echo "|---|---|---|"
python3 << EOF
import json, os, subprocess
m = json.load(open('$MANIFEST'))
for w in m['components']['wrappers_and_services']:
    if w['kind'] == 'systemd-service':
        sname = w['service_name']
        try:
            active = subprocess.check_output(['systemctl', 'is-active', sname], text=True, stderr=subprocess.DEVNULL).strip()
        except subprocess.CalledProcessError as e:
            active = e.output.strip() if e.output else 'inactive'
        status = "✅ active" if active == 'active' else f"🔴 {active}"
        health = "—"
        try:
            h = subprocess.check_output(w['verify_cmd'], shell=True, text=True, stderr=subprocess.DEVNULL, timeout=5).strip()
            health = "✅" if w.get('verify_expected', '') in h else f"⚠️ {h[:30]}"
        except Exception:
            health = "🔴 unreachable"
        print(f"| \`{w['id']}\` | {status} | {health} |")
EOF
echo ""

# ═════════════ Section 4: configs ═════════════
echo "## 📋 Configs"
echo ""
echo "| Config | Permissions | Required keys | Status |"
echo "|---|---|---|---|"
python3 << EOF
import json, os, stat
m = json.load(open('$MANIFEST'))
for c in m['components']['configs']:
    path = os.path.expandvars(c['path'])
    if not os.path.isfile(path):
        print(f"| \`{c['id']}\` | - | - | 🔴 missing |")
        continue
    perms = oct(stat.S_IMODE(os.stat(path).st_mode))[2:]
    expected_perms = c.get('permissions')
    if expected_perms is None:
        perms_ok = f"({perms} — no spec)"
    else:
        perms_ok = "✅" if perms == expected_perms else f"🟡 {perms} (want {expected_perms})"
    keys_ok = "✅"
    if c.get('must_contain_keys') and path.endswith('.json'):
        try:
            d = json.load(open(path))
            missing = []
            for k in c['must_contain_keys']:
                cur = d
                for part in k.split('.'):
                    if isinstance(cur, dict) and part in cur:
                        cur = cur[part]
                    else:
                        missing.append(k); break
            keys_ok = "✅" if not missing else f"🔴 missing: {', '.join(missing)}"
        except Exception:
            keys_ok = "⚠️ parse error"
    elif c.get('must_contain_substring'):
        try:
            content = open(path).read()
            keys_ok = "✅" if c['must_contain_substring'] in content else "🔴 substring missing"
        except Exception:
            keys_ok = "⚠️ read error"
    print(f"| \`{c['id']}\` | {perms_ok} | {keys_ok} | |")
EOF
echo ""

# ═════════════ Section 5: upstream issues being tracked ═════════════
echo "## 🔥 Upstream issues being tracked"
echo ""
echo "| Issue | Title | Status | Auto-resolve when |"
echo "|---|---|---|---|"
python3 << EOF
import json
m = json.load(open('$MANIFEST'))
for i in m['components']['upstream_issues_open']:
    print(f"| {i['url']} | {i['title'][:40]} | OPEN | {i['auto_resolve_when'][:80]} |")
EOF
echo ""

# ═════════════ Section 6: evidence tests ═════════════
echo "## 🧪 Evidence tests (used by /gbrain learn)"
echo ""
echo "| Test | Pass? |"
echo "|---|---|"
python3 << EOF
import json, subprocess, os
m = json.load(open('$MANIFEST'))
for name, cmd in m['evidence_tests']['tests'].items():
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, timeout=10, env=os.environ)
        passed = "✅" if r.returncode == 0 else "❌"
    except Exception:
        passed = "⏱️ timeout"
    print(f"| \`{name}\` | {passed} |")
EOF
echo ""

# ═════════════ Skills monorepo (durang/skills) ═════════════
echo "## 📦 Skills monorepo (durang/skills)"
echo ""
SKILLS_REPO="$HOME/skills"
if [ ! -d "$SKILLS_REPO/.git" ]; then
  echo "🟡 NOT installed at \`$SKILLS_REPO\`"
  echo ""
  echo "  To install (one command, idempotent, safe):"
  echo "  \`\`\`bash"
  echo "  git clone git@github.com:durang/skills.git ~/skills && cd ~/skills && ./install.sh && git config core.hooksPath .githooks"
  echo "  \`\`\`"
  echo ""
  echo "  After install, this dashboard will show sync status here."
else
  cd "$SKILLS_REPO" || true
  REMOTE_HASH=$(git ls-remote origin master 2>/dev/null | awk '{print $1}' | head -c 7)
  LOCAL_HASH=$(git rev-parse master 2>/dev/null | head -c 7)
  HOOK_PATH=$(git config core.hooksPath 2>/dev/null)
  REPO_SKILLS=$(find "$SKILLS_REPO/claude" "$SKILLS_REPO/openclaw" "$SKILLS_REPO/shared" -name "SKILL.md" 2>/dev/null | wc -l)
  if [ -z "$LOCAL_HASH" ]; then
    echo "🔴 \`$SKILLS_REPO\` exists but is not a valid git repo. Recovery: \`mv $SKILLS_REPO ${SKILLS_REPO}.bak && git clone git@github.com:durang/skills.git $SKILLS_REPO && cd $SKILLS_REPO && ./install.sh\`"
  elif [ "$LOCAL_HASH" != "$REMOTE_HASH" ] && [ -n "$REMOTE_HASH" ]; then
    echo "🟡 Local behind remote — \`cd $SKILLS_REPO && git pull && ./install.sh\`"
    echo "  - Local:  \`$LOCAL_HASH\`"
    echo "  - Remote: \`$REMOTE_HASH\`"
  else
    echo "✅ Up to date with remote (\`$LOCAL_HASH\`) — $REPO_SKILLS skills tracked"
  fi
  if [ "$HOOK_PATH" != ".githooks" ]; then
    echo "🟡 Git hooks NOT activated. Run: \`cd $SKILLS_REPO && git config core.hooksPath .githooks\`"
  else
    echo "✅ Git hooks activated (\`.githooks\`)"
  fi
fi
echo ""

echo "## Verdict"
echo ""
echo "Run \`/gbrain check\` for full health dashboard."
echo "Run \`/gbrain principles\` to read operational rules."
echo "Run \`/gbrain manifest\` to see canonical state inventory."
echo "Run \`/gbrain custom-instructions\` to see/regenerate the claude.ai snippet."
