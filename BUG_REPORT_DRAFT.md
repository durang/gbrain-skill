# Issue draft for github.com/garrytan/gbrain/issues

**Title:** `apply-migrations --yes succeeds but DB schema lags: v25/v26/v27 columns missing on real Postgres after 0.16 → 0.21 upgrade`

**Body:**

## Symptom

Running `gbrain apply-migrations --yes` after upgrading from v0.16.4 → v0.21.0 reports
"Migration v0.21.0 complete" but the underlying Postgres schema is silently behind.
Specifically `content_chunks` is missing the columns added in v25 (`page_kind`),
v26 (`language`, `symbol_name`, `symbol_type`, `start_line`, `end_line`),
v27 (`parent_symbol_path`, `doc_comment`, `symbol_name_qualified`, `search_vector`).

`gbrain doctor` reports `schema_version: Version 23, latest is 29` and
`fail rls: 10 tables WITHOUT Row Level Security` (the v24 backfill list).

## Reproducer

1. Run a brain on Postgres (Supabase, transaction pooler port 6543) on v0.16.4 with ~1200 pages.
2. `gbrain upgrade` to v0.21.0 (npm).
3. `gbrain apply-migrations --yes`.
4. Observe orchestrator output:
   ```
   relation "idx_chunks_embedding" already exists, skipping
   column "symbol_name" does not exist
   Migration v0.18.0 reported status=failed.
   ```
5. `gbrain doctor` shows schema_version=23 (not 29), 10 RLS gaps, missing columns.

## Root cause hypothesis

`~/.gbrain/preferences.json` has no `completedMigrations` history (perhaps was never
written by older versions). The orchestrator chain runs from the start, and
`v0_18_0.ts → phaseBBackfillStorage → ...` (or a downstream consumer) references
columns that the per-step DDL in `src/core/migrate.ts` should have added — but
`gbrain init --migrate-only` apparently halts before reaching v25/v26/v27 on a
real Postgres pooler with prepared-statement defaults disabled.

After the orchestrator failure, the pre-existing tables (e.g. `content_chunks`)
remain at their pre-v25 shape. The new tables added in v27 (`code_edges_chunk`,
`code_edges_symbol`) are also absent.

## Fix that worked locally

Applied each missing migration's SQL directly via `psql` (all idempotent,
`ADD COLUMN IF NOT EXISTS` / `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS`
copied verbatim from `src/core/migrate.ts` versions 25, 26, 27, 28, 29 + the v24 RLS
backfill block). After that, `gbrain apply-migrations --yes` re-ran and reported
"Migration v0.21.0 complete". `gbrain doctor` jumped from `health_score=50` to `75`,
`schema_version` to 29, RLS to 25/25.

## Suggested upstream fix

Either:
1. **`gbrain init --migrate-only` should iterate `MIGRATIONS` array** and apply each
   in order with idempotent SQL, breaking on actual error (not silently halting).
2. **Or `apply-migrations` should detect the schema gap** before running orchestrator
   phases that depend on later-version columns.

Tracked-version-vs-actual-DB drift detection in `gbrain doctor` would also catch this
class of issue earlier (e.g. `fail schema_drift: pages.page_kind missing despite
v25 marked complete`).

## Related issues

- #370 v0.18 migration chain fails: `column "X" does not exist`
- #378 Upgrade v0.17.x → v0.18.x fails: SCHEMA_SQL runs before migrations
- #389 apply-migrations hangs indefinitely on large brains

Likely the same family of bug (orchestrator vs. raw-SQL-migration ordering).

## Environment

- gbrain `0.21.0`
- openclaw `2026.4.23` (latest stable; tried 4.24-beta.5/6 but those have a separate plugin reinstall loop)
- Postgres via Supabase transaction pooler (port 6543), `GBRAIN_PREPARE` unset
- 1207 pages, 4095 chunks
- Linux EC2 (Amazon Linux 2023), Bun 1.x, Node 24

## Output of `gbrain doctor` BEFORE fix

```
health_score=50/100
warn  resolver_health: 7 issue(s)
ok    skill_conformance: 29/29
ok    connection: Connected, 1207 pages
ok    pgvector
fail  rls: 10 tables WITHOUT Row Level Security
warn  schema_version: Version 23, latest is 29
ok    embeddings: 99% coverage
warn  graph_coverage: 26%
warn  brain_score: 47/100
```

## Output AFTER fix (manual SQL application)

```
health_score=75/100
ok    schema_version: Version 29 (latest: 29)
ok    rls: 25/25 public tables
ok    embeddings: 100%
```

## Willing to PR

If maintainers point me at the right place in `src/core/migrate.ts` or `src/commands/init.ts`
to make the orchestrator iterate the MIGRATIONS array deterministically (and respect
`completedMigrations` ledger), happy to open a PR with tests.
