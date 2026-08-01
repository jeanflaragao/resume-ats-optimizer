# ADR-0012: Wire Solid Cache as the production cache store

## Status
Accepted

## Context
ADR-0002 decided to back Solid Queue, Solid Cache, and Solid Cable off the existing Postgres
instance instead of Redis, and its first Consequence states "one Postgres instance is the only
stateful dependency in production." Issue #18 built `Resume::OptimizedPdfJob`/
`DownloadsController` directly on `Rails.cache`, and CLAUDE.md's own description of that issue
says the PDF bytes are written to "Solid Cache, no new schema/table for a transient artifact."

None of that was actually true. Three independent checks confirmed the gap:
- `config/environments/production.rb` never set `config.cache_store` — it was still the
  scaffold's commented-out `# config.cache_store = :mem_cache_store`.
- `config/cache.yml` never existed.
- `db/cache_schema.rb` never existed, despite `config/database.yml` already declaring a `cache`
  entry under `production` since scaffolding, alongside `queue` and `cable`.

Production therefore silently fell back to Rails' default `ActiveSupport::Cache::FileStore` at
`tmp/cache`. Under Kamal, the Solid Queue worker and the Puma web process are separate containers
with separate filesystems: the job writes the rendered PDF to one container's disk, and
`DownloadsController` reads a different, empty one. Every download fails with "That download link
has expired. Please generate a new one." — for every user, every time (issue #54). The same
broken store also silently defeats `LlmCallGuard`'s daily call-count cap (a per-container counter,
wiped on every deploy), the app's only guard against runaway Anthropic spend. This blocked issue
#48 (Kamal deployment) from shipping a working download feature.

## Decision
Actually wire Solid Cache in production:
- Add `config/cache.yml`, copied from the `solid_cache` gem's own generator template, with
  `store_options` (`max_size: 256.megabytes`, `namespace: Rails.env`) and `database: cache` under
  `production` — pointing at the `cache` entry `config/database.yml` already declared.
- Set `config.cache_store = :solid_cache_store` in `config/environments/production.rb`.
- Commit `db/cache_schema.rb` (the `solid_cache_entries` table, from the same gem template) so
  `bin/rails db:prepare` creates it in the `cache` database, matching the existing
  `db/queue_schema.rb`/`db/cable_schema.rb` pattern.

Development (`:memory_store`) and test (`:null_store`) are untouched — ADR-0002's dev/test
consequence was correct and deliberate; only the production wiring was missing.

## Alternatives considered
- **A real `downloads` table or Active Storage instead of `Rails.cache`**: would sidestep the
  cache-store question entirely, but is a materially bigger architectural change than closing a
  configuration gap. Issue #18's design — a transient, cache-scoped artifact with no independent
  identity — was never in question, only its wiring. Rejected for this fix; would need its own
  ADR if ever pursued.
- **`bin/rails solid_cache:install` generator**: the fastest path to the same config, but its
  generator rewrites `config/environments/production.rb` wholesale and risks clobbering the
  existing `solid_queue`/`config.active_job.queue_adapter` block already there. Rejected in favor
  of the same manual, template-sourced approach already used for `db/queue_schema.rb`/
  `db/cable_schema.rb`.

## Consequences
- ADR-0002's Decision and first Consequence ("one Postgres instance is the only stateful
  dependency in production") are now actually true, not just asserted — closing the gap this ADR
  documents. ADR-0002's `## Status` now carries a pointer to this ADR.
- `LlmCallGuard`'s daily call cap now persists across container boundaries and deploys, since
  `Rails.cache` is durable Postgres-backed storage instead of a per-container in-memory/file
  fallback.
- Issue #48 (Kamal deployment) was blocked on this; #54 unblocks it.
