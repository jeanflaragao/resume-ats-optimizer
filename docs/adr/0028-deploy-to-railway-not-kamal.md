# ADR-0028: Deploy to Railway now; keep Kamal as the documented path to AWS later

## Status
Accepted — supersedes, for the deployment mechanism only, the one Kamal-assuming sentence in
[ADR-0001](0001-rails-8-hotwire-monolith.md)'s Context

## Context

Issue #48 asked for Kamal specifically: initialize `config/deploy.yml`, add a worker role
running `bin/jobs`, confirm the queue/cache/cable databases are reachable. Its actual goal is
narrower than its stated scope — a Solid Queue worker running in production — and that goal is
what this ADR resolves. The mechanism changes: **Railway, not Kamal**, a platform decision made
outside the issue and recorded here rather than silently substituted.

Worth naming directly: **ADR-0001 never actually decided "Kamal."** Read in full before writing
this one — its Context has a single sentence assuming Kamal as background ("the project ... will
be deployed to a single VPS via Kamal") while deciding something else (monolith vs. SPA), with no
alternatives-to-Kamal section and no Kamal-specific consequences anywhere in it. This ADR is the
first place the deployment mechanism itself is actually evaluated, not a reversal of a considered
decision.

`kamal` and `thruster` stay in the Gemfile, unused, as the documented path to a possible later
move to AWS — removing them was explicitly out of scope for this change.

## What was verified before deciding this was workable, not assumed

Issue #48's own review flagged the multi-database provisioning question as unverified and the
single most likely first-deploy break: `config/database.yml`'s production `cache`/`queue`/`cable`
entries declare `migrations_paths` pointing at directories that don't exist. Tested directly
against a real local Postgres rather than reasoned about:

- `RAILS_ENV=production bin/rails db:prepare` correctly creates and fully schema-loads all four
  databases from their committed `*_schema.rb` files — the missing `migrations_paths` directories
  are not a problem, and re-running it against already-provisioned databases is a safe no-op.
- Naively having both the web and worker roles run `db:prepare` independently — the obvious fix
  for "the worker provisions nothing" — is not safe on a genuinely fresh deploy. Two concurrent
  `db:prepare` invocations race in two distinct ways: a `PG::UniqueViolation` when both try to
  `CREATE DATABASE` at once, and a subtler failure where one process sees the database the other
  just created and concludes there's nothing to migrate *before* the other's schema load has
  actually finished — the loser then execs `bin/jobs` against tables that don't exist yet. A
  first attempt at fixing this with a plain retry loop caught the first race but not the second,
  since `db:prepare` reports success in the second case. The actual fix, verified across multiple
  concurrent runs including a three-way race: a Postgres advisory lock held for the entire
  `db:prepare` call, taken against the always-present `postgres` maintenance database.
- Thruster (fronting Puma per the Dockerfile's `CMD`) listens on `HTTP_PORT`, default 80, and does
  not read Railway's injected `PORT` itself. Railway's port injection happens at container
  runtime, not at its dashboard's variable-reference resolution time, so the mapping has to
  happen inside the running container (`bin/docker-entrypoint`), not in Railway's config.
- `ANTHROPIC_API_KEY`'s bare `ENV[]` read in `config/initializers/ruby_llm.rb` turned out to
  already be indirectly safe: `LlmCallGuard.validate_api_key!` (ADR-0020) already raises at boot
  when real calls are enabled and the key is missing. What was genuinely missing was a test
  proving that refusal happens, and a structural (not load-order-accidental) guarantee that
  `RubyLLM.configure` never runs before that check has had a chance to abort boot.

## Decision

**Deploy to Railway**: two services from the same repo/Dockerfile — a web service (default `CMD`,
Thruster fronting Puma) and a worker service (start command `bin/jobs`, the Solid Queue
supervisor), against Railway's Postgres plugin. Both services provision their own databases on
boot via the now-serialized `bin/docker-entrypoint`, so neither depends on Railway guaranteeing
start order between them (no such guarantee is documented, and none was found).

Supporting repo changes, all in this PR:
- `bin/docker-entrypoint`: broadened `db:prepare` trigger (`bin/jobs` in addition to
  `./bin/rails server`), wrapped in the advisory lock described above, plus `HTTP_PORT` mapped
  from Railway's runtime `PORT`.
- `config/initializers/ruby_llm.rb`: `RubyLLM.configure` moved into `Rails.application.config
  .to_prepare`, so it structurally runs after `LlmCallGuard.validate_api_key!` has had the chance
  to abort boot, not merely after it by alphabetical initializer-load coincidence.
- `test/config/llm_call_guard_boot_test.rb`: added the missing case — real calls enabled, no key,
  refuses to boot — closing the gap between "the behavior exists" and "the behavior is proven."
- `config/environments/production.rb`: `config.hosts` wired to Railway's `RAILWAY_PUBLIC_DOMAIN`
  runtime env var (empty/deny-all during the Docker build's asset-precompile boot, which never
  serves a request), with `/up` excluded from host authorization since Railway's health checker
  may not present a matching Host header; `action_mailer.default_url_options` wired to the same
  domain instead of the `example.com` placeholder — no mailer exists yet, so this is forward-
  looking hygiene, not an active fix.

**`MAX_LLM_CALLS_PER_DAY`**: set to `200` in the runbook for the first deploy, sized against
ADR-0020's `2 + 2E` per-flow formula (worst case, a download that misses the optimization cache)
for a small, invite-only initial audience. **This does not resolve issue #106.** The global cap
has no per-caller dimension — exhausting it denies service to every user, not just whoever
exhausted it — and deploying with that gap open is a deliberate, recorded choice made because the
alternative (staying undeployed until #106 is fixed) was judged worse than shipping with a known,
documented gap. #106 stays open, unaffected by the value chosen here.

## Alternatives considered

- **Follow issue #48 literally and initialize Kamal.** Not rejected outright — recorded as the
  documented path to a later AWS move, which is why the gem stays in the Gemfile unused. Deferred
  because Railway was the platform decision handed down for this deploy, made outside this issue.
- **`SOLID_QUEUE_IN_PUMA=true`, running the Solid Queue supervisor inside the web process instead
  of a second service.** `config/puma.rb` already supports this via a plugin toggle. Rejected:
  the explicit ask for this deploy was two services (web, worker), and a single-process deploy
  trades away the isolation a separate worker service gives (a slow/stuck job doesn't compete
  with request-serving Puma workers for the same process).
- **Relying on Railway service start-order** instead of having both roles provision
  independently. No Railway feature equivalent to `depends_on: condition: service_healthy` was
  found; the advisory-lock fix makes the ordering question moot rather than depending on a
  platform guarantee that doesn't exist.

## Consequences

- The Postgres role `config/database.yml`'s production block hardcodes (`resume_ats_optimizer`)
  does not exist by default on Railway's Postgres plugin, which provisions a `postgres`
  superuser via `DATABASE_URL`/`PGUSER`/`POSTGRES_PASSWORD`. The runbook has a one-time manual
  step — connect with Railway's provided credentials, run a single `CREATE ROLE ... CREATEDB`
  statement — before the first deploy. This was rehearsed locally, identically, before every test
  described above.
- `bin/docker-entrypoint` now requires the `postgresql-client` package (`psql`) at runtime for the
  advisory lock; already present in the production `Dockerfile`, not present in `Dockerfile.dev`
  (dev/test never exercise this path, so this is not a local-development change).
- A future move to AWS via Kamal would need `config/deploy.yml`/`.kamal/` initialized from
  scratch — nothing here builds toward that beyond leaving the gems in place — but would inherit
  the `bin/docker-entrypoint`/`ruby_llm.rb`/`production.rb` fixes in this PR for free, since none
  of them are Railway-specific except the `RAILWAY_PUBLIC_DOMAIN` env var name itself.
