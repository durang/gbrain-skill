# Phase 4 — Connect Claude Desktop, claude.ai web, Cowork, Mobile

End-to-end recipe: HTTP wrapper around `gbrain serve` + Tailscale Funnel + OAuth 2.1, so any Anthropic surface (Desktop, web, Cowork, mobile) can read/write your shared brain. This is what unlocks the *non-stdio* clients that the canonical [CONNECT.md](CONNECT.md) compatibility matrix marks ❌ today.

Validated end-to-end on real hardware (EC2 jarvis + Mac, Supabase Postgres, Tailscale Funnel). The numbered phases below match the order you actually execute them — and after each one, `progression.sh` auto-detects the new "done" status.

## TL;DR

1. **4A** — Build the HTTP wrapper as a Bun + Hono service. Pool of 3 pre-warm `gbrain serve` children, JSON-RPC over stdio, Bearer auth against `access_tokens`.
2. **4B** — Expose the wrapper via Tailscale Funnel. Co-exists with whatever else you already serve from `/`.
3. **4C** — Add OAuth 2.1 (PKCE + Dynamic Client Registration + OIDC discovery + master-password gate) so claude.ai's connector flow can complete.
4. **4D** *(optional)* — Submit the wrapper as a PR to `garrytan/gbrain` to close the upstream "planned but not yet implemented" gap.

Total time: ~3-5 hours hands-on once you've done it once. The first time, expect 6-8h because the bug-fix loop (documented below) is real.

## Why this exists

- `gbrain serve` is stdio-only. Local clients (Claude Code, Cursor, Windsurf) work natively. Anthropic's GUI surfaces (Desktop, claude.ai web, Cowork, mobile) only speak HTTP — and *require OAuth 2.1*, not plain Bearer, since late 2025.
- Upstream `gbrain` documents this gap explicitly in `docs/mcp/DEPLOY.md`: *"`gbrain serve --http` (built-in HTTP transport) is planned but not yet implemented."*
- This guide closes the gap. The reference implementation lives at https://github.com/durang/gbrain-http-wrapper.

## Architecture

```
Internet
    │  HTTPS /mcp + OAuth 2.1
    ▼
Tailscale Funnel  (https://your-machine.ts.net)
    ├─ /        proxies → existing services (e.g. OpenClaw on port X)
    └─ /mcp     proxies → 127.0.0.1:8787   ← THE WRAPPER
                            │
                            ├─ Bearer middleware (validates against access_tokens)
                            ├─ OAuth router (.well-known/* + /oauth/*)
                            └─ Pool of 3 gbrain serve children (stdio JSON-RPC)
                                            │
                                            ▼
                                       Postgres (shared brain)
```

## What you need before starting

| Requirement | How to verify |
|---|---|
| Server with `gbrain` v0.2x.x installed and pointing at a Postgres brain | `gbrain --version && gbrain doctor --fast` |
| Tailscale running with Funnel enabled on the machine | `tailscale funnel status` (or activate per Phase 4B) |
| Bun ≥ 1.3 | `bun --version` |
| Port 8787 free | `ss -tlnp | grep :8787` (empty = free) |
| systemd available (for autostart) | `systemctl --version` |
| `gbrain auth create` works (i.e. `access_tokens` table exists) | `bun run gbrain/src/commands/auth.ts list` |

## Phase 4A — HTTP wrapper

**Reference impl:** https://github.com/durang/gbrain-http-wrapper

**Stack:** Bun + Hono + postgres-js. Single-file Python-stdlib-equivalent simplicity.

**Endpoints:**

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/health` | none | Liveness + pool status (Tailscale Funnel ping target) |
| POST | `/mcp` and `/` | Bearer | JSON-RPC requests (notifications fire-and-forget, requests await response) |
| GET | `/mcp` and `/` | Bearer | SSE stream with 15s heartbeat (some clients require this for Streamable HTTP transport) |
| GET | `/mcp/sse` and `/sse` | Bearer | Same SSE handler at the legacy path |

**Why dual mounting** (`/` and `/mcp`)? Tailscale Funnel `--set-path /mcp` strips the `/mcp` prefix when forwarding to the upstream. So a request that hits `https://host/mcp` arrives at the wrapper as `/`. Mounting both means the wrapper works whether or not you're behind Tailscale.

**Pool design:** 3 long-running `gbrain serve` children. Each handles one request at a time; pool serializes additional requests via a queue. Auto-respawn on child crash. Spawning per-request would add ~200-500ms latency on each call.

**Critical implementation details:**

- Spawn with `bun run` explicit (not relying on shebang) — see [bug #3](#bugs-found-and-fixed) below.
- Inherit env with `PATH` augmented to include `~/.bun/bin` so `gbrain` finds `bun`.
- `prepare: false` on the postgres client (PgBouncer transaction-mode safe).
- Set `GBRAIN_HOOK_RUNNING=1` in the inherited env so any nested `claude -p` call from inside `gbrain serve` doesn't recursively trigger Stop hooks.
- 60s request timeout on the pool side. If a worker doesn't respond, reject with timeout (don't hang the HTTP request forever).

**systemd unit:**

```ini
[Unit]
Description=GBrain HTTP Wrapper
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/home/ec2-user/gbrain-http-wrapper
EnvironmentFile=/home/ec2-user/gbrain-http-wrapper/.env
ExecStart=/home/ec2-user/.bun/bin/bun run src/server.ts
Restart=always
RestartSec=5
TimeoutStartSec=30

# Hardening (relaxed: gbrain CLI lives in HOME and needs to spawn child bun
# processes which may write logs / state under HOME)
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

Don't use `ProtectHome=read-only` — it blocks `gbrain` (which lives in `~/.bun/bin/`) from executing. See [bug #2](#bugs-found-and-fixed).

**Smoke test after install:**

```bash
TOKEN=$(bun run gbrain/src/commands/auth.ts create "smoke" 2>&1 | grep -oE 'gbrain_[a-f0-9]+')
curl -s http://127.0.0.1:8787/health | jq
curl -s -X POST http://127.0.0.1:8787/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq '.result.tools | length'
# expect: 41 (or however many tools your gbrain version exposes)
bun run gbrain/src/commands/auth.ts revoke "smoke"
```

## Phase 4B — Tailscale Funnel

```bash
sudo tailscale set --operator=$USER  # one-time, allows funnel without sudo afterward
tailscale funnel --bg --set-path /mcp 8787
tailscale funnel status
# Expected:
#   https://your-machine.ts.net/mcp proxy http://127.0.0.1:8787
```

**Co-existence:** if you already serve other things from `/` (e.g. OpenClaw gateway), they keep working. `--set-path` only routes the matching prefix.

**Verify externally:**

```bash
curl -s "https://your-machine.ts.net/mcp/health" | jq
# Should return the same JSON as the local 127.0.0.1:8787/health
```

## Phase 4C — OAuth 2.1

This is what unlocks claude.ai's GUI flow. Without it, the GUI rejects custom connectors with `step=start_error` before ever reaching your server.

**MCP authorization spec (Anthropic, 2025+) requires:**

1. **Protected resource metadata** at `/.well-known/oauth-protected-resource` (RFC 9728)
2. **Authorization server metadata** at `/.well-known/oauth-authorization-server` (RFC 8414)
3. **OpenID Connect discovery** at `/.well-known/openid-configuration` — claude.ai probes this as a fallback (see [bug #7](#bugs-found-and-fixed))
4. **Dynamic Client Registration** at `/oauth/register` (RFC 7591)
5. **Authorization endpoint** at `/oauth/authorize` (with PKCE S256)
6. **Token endpoint** at `/oauth/token` (authorization_code + refresh_token grants)

**WWW-Authenticate header on 401** must point to the protected resource metadata URL so MCP-aware clients can auto-discover OAuth:

```
Bearer realm="gbrain", resource_metadata="https://your-machine.ts.net/mcp/.well-known/oauth-protected-resource"
```

### Master password consent gate

A single-user OAuth deployment doesn't need a real user database. We gate consent with `GBRAIN_OAUTH_PASSWORD` (env var). When claude.ai redirects the user to the authorize endpoint, the wrapper renders an HTML form: enter the password to approve. On match (constant-time comparison), the wrapper issues an authorization code, redirects back to claude.ai with `code=...&state=...`, and claude.ai exchanges the code for a Bearer token at `/oauth/token`.

The token issued via OAuth lands in the **same** `access_tokens` table that the rest of the wrapper validates against. CLI-issued tokens (`gbrain auth create`) and OAuth-issued tokens are interchangeable from the validation path's perspective.

### URL prefix matters — every endpoint must include `/mcp/`

Because Tailscale Funnel strips the `/mcp` prefix, all OAuth endpoints we **advertise to clients** must include `/mcp/` in the URL — but the wrapper handles them at the unprefixed path internally:

```
Client sees:                                                Wrapper handles:
https://host/mcp/.well-known/oauth-protected-resource  →   /.well-known/oauth-protected-resource
https://host/mcp/.well-known/openid-configuration      →   /.well-known/openid-configuration
https://host/mcp/oauth/authorize                       →   /oauth/authorize
https://host/mcp/oauth/token                           →   /oauth/token
https://host/mcp/oauth/register                        →   /oauth/register
```

So `issuer` in metadata must be `https://host/mcp` (not just `https://host`). And HTML form actions inside the consent page must use absolute URLs with the `/mcp` prefix — see [bug #8](#bugs-found-and-fixed).

### Claude.ai connector flow (what actually happens)

```
1. User clicks "Add Custom Connector" in claude.ai/settings/connectors,
   pastes https://host.ts.net/mcp
2. claude.ai calls POST / 401 to detect MCP server (your WWW-Authenticate
   header tells it where the OAuth metadata lives)
3. claude.ai fetches /.well-known/oauth-protected-resource and
   /.well-known/openid-configuration to discover OAuth
4. claude.ai POSTs /oauth/register (Dynamic Client Registration)
   → server returns client_id
5. claude.ai redirects user's browser to /oauth/authorize?response_type=code&...
6. User enters master password, clicks Approve
7. Server validates, generates auth code (10 min TTL), redirects browser to
   redirect_uri with code+state
8. claude.ai POSTs /oauth/token with code+verifier+redirect_uri
   → server issues access_token + refresh_token (PKCE S256 verified)
9. claude.ai stores token, calls POST /mcp with Bearer
   → wrapper proxies to gbrain serve stdio → returns tools list
10. Connector shows as connected. Future requests use the OAuth-issued
    access_token, refreshed when expired
```

When this works, Anthropic's connector registry is updated at the **account level**: Claude Desktop on Mac, claude.ai web, Cowork, and mobile *all* see the connector automatically. You don't configure anything per-client.

## Phase 4D *(optional)* — Upstream PR

Once your wrapper has been stable for ~1 week of real use, consider contributing it to `garrytan/gbrain`:

- Path A: as a `recipes/gbrain-http-wrapper.md` recipe pointing at your repo (low risk, easily merged)
- Path B: as `gbrain serve --http` native subcommand in the binary (higher risk, more work, larger impact)

Both are valuable. Path A gives the community a documented canon; Path B makes it default behavior for everyone. Garry tends to merge well-documented recipes — see existing examples in `recipes/*-to-brain.md`.

## Bugs found and fixed

These all bit us during real implementation and validation. Document them so the next person doesn't burn 6 hours rediscovering them.

1. **Wrong table name.** The auth schema's table is `access_tokens`, not `mcp_tokens`. Caught by the wrapper logging `relation "mcp_tokens" does not exist` from postgres-js.

2. **systemd `ProtectHome=read-only` blocks `gbrain` execution.** `gbrain` lives in `~/.bun/bin/` and needs read+execute. Drop that flag, keep `NoNewPrivileges=true` and `PrivateTmp=true`.

3. **`gbrain` shebang is `#!/usr/bin/env bun`, but systemd-spawned children get a stripped PATH that doesn't include `~/.bun/bin/`.** `env bun` fails with exit 127, child crashes, pool tries to respawn → infinite restart loop. Fix: spawn the child with `bun run /path/to/gbrain serve` explicitly.

4. **Tailscale Funnel strips the path prefix.** `/mcp` → `/` at the upstream. Wrapper must mount both `/` and `/mcp` for every route. Same for OAuth endpoints — every URL we advertise externally must include `/mcp/`.

5. **CORS preflight** required for browser flows. Without `Access-Control-Allow-Origin`, `Allow-Headers` (must include `Authorization`, `Mcp-Session-Id`, `mcp-protocol-version`), and OPTIONS handler returning 204, claude.ai's web flow fails CORS validation before reaching auth.

6. **MCP Streamable HTTP transport requires GET on the JSON-RPC endpoint.** Some clients open an SSE stream there to receive server-initiated messages. We respond with text/event-stream + heartbeats; even if we don't push anything, the connection-open is required.

7. **`/.well-known/openid-configuration` 404 → connector marks server as "Couldn't reach the MCP server".** claude.ai falls back from `oauth-authorization-server` to OIDC discovery. Implement OIDC discovery returning the same metadata as the OAuth one, with the OIDC required fields (`subject_types_supported`, `id_token_signing_alg_values_supported`) declared minimally.

8. **HTML form `action="/oauth/authorize"`** (relative) resolves against the host root, NOT the `/mcp` prefix the user visited. The browser POSTs to the wrong URL. Fix: use absolute URL `${ISSUER}/oauth/authorize`.

9. **MCP notifications hang the wrapper for 60s.** JSON-RPC 2.0 notifications have no `id` and expect no response. The wrapper was awaiting a response that never came → 60s timeout → 500 to the client. Fix: detect missing `id`, write to stdin, return 202 immediately.

10. **OAuth `resource` field had `/mcp/mcp`.** Setting `ISSUER = BASE_URL + '/mcp'` and then computing `resource: ${ISSUER}/mcp` doubled the prefix. Use `RESOURCE_URL = ISSUER` because in our setup the resource and authorization server are at the same URL.

11. **PAT in auto-committed brain history (security incident).** Unrelated to the wrapper but discovered in the same milestone: the auto-commit cron pulled `unsafe-local-memory-*.md` files into the brain repo, and one of those contained a real GitHub PAT. Mitigation: chmod 600 the leaked files, add `memory/sources/unsafe-local-memory-*` to `.gitignore`, run `git filter-repo --invert-paths --path-glob 'memory/sources/unsafe-local-memory-*'` to scrub the historical commits before the first push, and rotate the PAT in GitHub. **Always check brain repo history for secrets before the first push.**

## Verification ladder

After build, walk through these in order. Each one tests one new piece of the stack.

```bash
# 1. Wrapper alive
curl -s http://127.0.0.1:8787/health | jq

# 2. Bearer auth working (issue a token via auth.ts, use it)
curl -s -X POST http://127.0.0.1:8787/mcp -H "Authorization: Bearer $T" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq '.result.tools | length'

# 3. Notifications fire-and-forget (should be 202 in <100ms)
curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" -X POST http://127.0.0.1:8787/mcp \
  -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

# 4. Tailscale Funnel exposed
curl -s "https://your-machine.ts.net/mcp/health" | jq

# 5. OAuth discovery
curl -s "https://your-machine.ts.net/mcp/.well-known/oauth-protected-resource" | jq
curl -s "https://your-machine.ts.net/mcp/.well-known/openid-configuration" | jq

# 6. Full OAuth flow (DCR → authorize → token → tools/list)
# This is what claude.ai's connector flow does. The reference repo has a
# scripted version in test/oauth-e2e.sh.

# 7. claude.ai web actually uses it
# Settings → Connectors → Add Custom → URL → Save → password → Approve.
# Then in a new chat: "search my brain for X". Should call tools.
sudo journalctl -u gbrain-http-wrapper -f
# Watch the logs as you make the request — you'll see initialize,
# notifications/initialized, tools/list, tools/call land.
```

## See also

- [README.md](README.md) — what this skill is
- [SKILL.md](SKILL.md) — `/gbrain` slash-command spec (health dashboard)
- [INSTALL.md](INSTALL.md) — bootstrap installer for stdio-only setup
- [CONNECT.md](CONNECT.md) — multi-client compatibility matrix (HTTP clients now ✅ via this guide)
- [CAPTURE.md](CAPTURE.md) — ambient capture from Claude Code sessions
- [ARCHITECTURE.md](ARCHITECTURE.md) — end-to-end audit of the multi-client setup
- Reference impl: https://github.com/durang/gbrain-http-wrapper
- Upstream: https://github.com/garrytan/gbrain (`docs/mcp/DEPLOY.md`)
