# Railway deploy runbook

For you to run yourself — nothing in this file was executed by Claude. See
[ADR-0028](adr/0028-deploy-to-railway-not-kamal.md) for why Railway and what was verified before
writing this.

## 1. Create the Railway project

1. In Railway, create a new project and connect this GitHub repo. Railway auto-detects the root
   `Dockerfile` (capital D, which this repo already has) and uses it as the build input — no
   Railway-specific config file is needed for the build itself.
2. Add a **Postgres** plugin/service to the project.
3. From the same repo, create **two services**, both pointing at the same Dockerfile:
   - **web** — leave the start command as the Dockerfile's default (`./bin/thrust ./bin/rails
     server`). Enable a public domain for this service under its Networking settings (this is
     what populates `RAILWAY_PUBLIC_DOMAIN` at runtime — `config.hosts` in
     `config/environments/production.rb` depends on it existing, or every request 403s).
   - **worker** — override the start command to `bin/jobs`. No public domain needed; it never
     serves HTTP.

## 2. Create the Postgres role this app expects

Railway's Postgres plugin provisions a `postgres` superuser (via `DATABASE_URL`/`PGUSER`/
`POSTGRES_PASSWORD`), not a role named `resume_ats_optimizer` — which
`config/database.yml`'s production block hardcodes as the username for all four of this app's
databases (primary, cache, queue, cable). This is a one-time step before the first deploy:

1. In Railway's Postgres service, open the **Connect** tab and copy the provided `psql` command
   (uses the `postgres` superuser).
2. Run it, then execute:
   ```sql
   CREATE ROLE resume_ats_optimizer WITH LOGIN CREATEDB PASSWORD 'choose-a-strong-password-here';
   ```
   `CREATEDB` is required — `bin/docker-entrypoint` runs `db:prepare`, which creates all four
   databases (verified locally, see ADR-0028) the first time either service boots.
3. Save that password — it's `RESUME_ATS_OPTIMIZER_DATABASE_PASSWORD` below.

## 3. Environment variables

Set on **both** the web and worker services unless noted otherwise. Each row states what
actually breaks if it's missing, not just "required."

| Variable | Value | What breaks if missing |
|---|---|---|
| `RESUME_ATS_OPTIMIZER_DATABASE_PASSWORD` | the password from step 2 | Postgres auth fails at boot for every database. |
| `DB_HOST` | `${{Postgres.RAILWAY_PRIVATE_DOMAIN}}` (Railway variable reference — private networking, no egress cost) | Can't reach Postgres at all. |
| `DB_PORT` | `5432` | Same. |
| `RAILS_MASTER_KEY` | the contents of your local `config/master.key` (never commit this) | **Blocking.** `config/credentials.yml.enc` can't be decrypted; `Resume::PdfRequest#text`'s `encrypts :text` (ADR-0022) raises, and every download fails. |
| `ENABLE_REAL_LLM_CALLS` | `true` | **Blocking, no default in production** (ADR-0020). Unset refuses to boot. |
| `ANTHROPIC_API_KEY` | your real Anthropic key | **Blocking** whenever `ENABLE_REAL_LLM_CALLS=true` (ADR-0020, and now covered by `test/config/llm_call_guard_boot_test.rb`). Refuses to boot rather than silently shipping placeholder text. |
| `MAX_LLM_CALLS_PER_DAY` | `200` | **Blocking, no default.** See the sizing note below — and the #106 caveat, which this value does not fix. |
| `RATE_LIMIT_RESUME_EXTRACTION_PER_DAY` | `5` | **Blocking, no default** (ADR-0023). |
| `RATE_LIMIT_REQUIREMENT_EXTRACTION_PER_DAY` | `25` | Same. |
| `RATE_LIMIT_BULLET_REWRITING_PER_DAY` | `15` | Same. |
| `RATE_LIMIT_PDF_GENERATION_PER_DAY` | `15` | Same. |
| `RAILS_LOG_LEVEL` | unset | Optional — defaults to `info`. |
| `JOB_CONCURRENCY` | unset, or `2` on the worker service | Optional — defaults to `1` Solid Queue process. The worker now has its own service (not sharing resources with web), so `2` is a reasonable bump if the queue backs up; not required for the first deploy. |
| `RAILWAY_PUBLIC_DOMAIN` | *(don't set — Railway provides this automatically)* | If the web service never gets a public domain assigned, this stays unset, `config.hosts` stays empty, and every request 403s. |
| `PORT` | *(don't set — Railway injects this automatically)* | `bin/docker-entrypoint` maps it to Thruster's `HTTP_PORT`; without it Thruster falls back to port 80, which may not match what Railway routes to. |
| `GOOGLE_OAUTH_CLIENT_ID` | from the Google Cloud Console OAuth client (see note below) | **Blocking, no default in production.** Refuses to boot without it (ADR-0032, `Authentication::ConfigGuard`). Since accounts are mandatory (issue #120), this isn't a degraded mode — nobody can sign in. |
| `GOOGLE_OAUTH_CLIENT_SECRET` | same client, never commit this | Same. |

**Setting up Google OAuth**: register **one** Google Cloud OAuth 2.0 Client (Web application
type), and add **both** of these as Authorized redirect URIs on that single client — not two
separate clients:
- `http://localhost:3000/auth/google_oauth2/callback` (local dev)
- `https://<the web service's RAILWAY_PUBLIC_DOMAIN>/auth/google_oauth2/callback` (production —
  not knowable until the web service has a public domain, so this half of the registration
  happens after/alongside the first deploy in step 4 below, not before it)

Use the same `GOOGLE_OAUTH_CLIENT_ID`/`GOOGLE_OAUTH_CLIENT_SECRET` pair in your local `.env` and in
Railway's env vars — the code never branches on environment for the callback URL itself
(`omniauth-google-oauth2` builds it from the incoming request's own host); only which redirect
URIs are registered in Google Cloud Console differs.

**Sizing `MAX_LLM_CALLS_PER_DAY` and the `RATE_LIMIT_*` values**: no production usage data exists
yet (this is the first deploy), so these are inherited from the same values already used for
local/dev sanity-checking, not derived from real traffic — ADR-0020's own sizing formula
(`2 + 2E` provider requests per full flow, worst case) puts `200` comfortably above what a small,
invite-only audience would need in a day. Revisit both once real usage data exists, per #48's own
comment 2 and #45.

**Stated plainly, per this deploy's explicit instruction**: setting `MAX_LLM_CALLS_PER_DAY` here
does **not** resolve issue #106. That cap has no per-caller dimension — exhausting it (by
accident or on purpose) denies service to every user for the rest of the day, not just whoever
exhausted it. Deploying with that gap open is a deliberate, recorded choice (ADR-0028), not an
oversight.

## 4. First deploy

Deploy the web service first, watch its logs for `db:prepare` completing (four `Created
database` lines, or a silent no-op if they already exist — see ADR-0028), then deploy the worker
service. They don't strictly need to be sequenced — both provision independently and safely even
if started together (tested, see ADR-0028) — but deploying web first lets you confirm the app is
reachable before adding the worker.

Confirm end to end: visit the public domain, upload a resume, check match, preview, and download
— the download exercises the worker (`Resume::OptimizedPdfJob`) and the real ActionCable/Solid
Cable broadcast back to the browser.

## 5. Backups — a `pg_dump` you can run yourself

Only the **primary** database (`resume_ats_optimizer_production`) holds real user data —
`resumes`, `experiences`, `educations`, `resume_pdf_requests`, `usage_counters`. The cache,
queue, and cable databases are operational/ephemeral (Solid Cache entries, Solid Queue jobs,
Solid Cable messages) and don't need backing up; `db:prepare` regenerates their schema from
scratch on any fresh deploy.

This intentionally does not use a Railway-proprietary export feature, so it never depends on
Railway's dashboard or CLI being reachable — only standard `pg_dump` connectivity:

1. In Railway's Postgres service, open the **Connect** tab and switch to **Public Network** (not
   the private/internal one — that only works from inside Railway). Copy the public connection
   string.
2. From your own machine, with the `postgres` client tools installed:
   ```sh
   pg_dump "postgresql://resume_ats_optimizer:<password>@<public-host>:<public-port>/resume_ats_optimizer_production" \
     -F c -f "resume-ats-optimizer-$(date +%Y%m%d).dump"
   ```
   (`-F c`: pg_dump's custom compressed format, restorable with `pg_restore`; swap in `resume_ats_optimizer`'s
   own credentials from step 2 above, not the Postgres plugin's superuser — either works, since
   `resume_ats_optimizer` owns the tables it created.)
3. Restore, if ever needed, with:
   ```sh
   pg_restore -d "<connection string to the target database>" resume-ats-optimizer-YYYYMMDD.dump
   ```

Run this on whatever cadence you're comfortable with (there's no automation for it in this repo
— it's a manual, on-demand procedure by design, matching the "don't depend on the platform being
reachable" requirement).
