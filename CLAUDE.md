# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git workflow — non-negotiable

- NEVER push to `master`. No exceptions, no "just this once". Always: branch off
  freshly-pulled master → commit → push the branch → open a PR with `gh pr create`.
- Never merge. Stop after opening the PR and wait for explicit human approval. Merges are
  done with `gh pr merge --squash --delete-branch`, by the human.
- Branch naming: `<type>/<short-description>`, type matching the commit type (feat, fix,
  docs, test, chore, refactor, perf, security).

## Commit messages

- Conventional Commits: `type(scope): short description`.
- Do NOT append an issue or PR number to the subject line. The `(#NN)` visible in git
  history is added automatically by GitHub on squash merge — it is not part of the
  authored message.
- Do NOT add any attribution trailer, co-author trailer, or session link.

## Closing issues

- `Closes #NN` goes in the PR body, not the commit subject — one line per issue. A PR
  resolving three issues needs three `Closes #NN` lines.
- A PR that only partially addresses an issue uses `Part of #NN`, not `Closes`.
- After merging, verify with `gh issue view NN --json state`. A missing reference fails
  silently — GitHub won't auto-close an issue it can't find a keyword for.

## Conflicts between a prompt and an issue body

List every conflict explicitly rather than resolving any silently — even when the
resolution seems obviously correct. The issue body is the source of truth; the prompt may
be based on stale context.

## Working agreements

**List every departure from the prompt.** If the instructions given conflict
with what the repo actually contains — a taken ADR number, a signature that
would break an existing behaviour, a config that does not exist — surface the
conflict and your recommendation before writing code. Do not silently resolve
it, and do not follow the prompt into a known-wrong outcome. The prompt is
input to be reviewed, not a spec to be executed.

**Prove new safety assertions are non-vacuous.** Any test that asserts a
security or privacy property must be run against the unfixed code first and
shown to fail. Record that it failed in the PR body. A green test that would
also be green without the fix is worse than no test.

## Verification — all inside the container

- `docker compose run --rm web bin/rails test`
- `docker compose run --rm web bin/rubocop`
- `docker compose run --rm web bin/brakeman`
- `docker compose run --rm web bin/importmap audit`

## Logging and PII

Per ADR-0015 and ADR-0016: no raw resume field value or job description content in logs,
ever. This includes exception messages — `RubyLLM::Error#message` falls back to the raw
API response body. Log `e.class` plus HTTP status where available, never `e.message`.

## Project status

`resume-ats-optimizer` is a hosted, multi-user tool for optimizing resumes against Applicant
Tracking Systems: upload a LinkedIn data export, paste a job description, and get back an
ATS-friendly, tailored resume as a downloadable PDF. The full upload → analyze → preview →
download pipeline exists end to end (see Project layout below for what each piece does); Phase 5
(Frontend) is complete and Phase 6 (automation & quality, this issue included) is in progress.
Open follow-up work: issue #48 (Kamal deployment/`config/deploy.yml` doesn't exist yet, so the
Solid Queue worker has nowhere to run in production), plus two smaller UX gaps surfaced by the
turbo_stream conversion (#65, #66 — see ADR-0014). Per-issue history lives in `git log` and the
GitHub issue tracker, not here; architectural decisions live in `docs/adr/`, linked from Stack
and Project layout below where relevant.

## Stack

**Rails 8, Hotwire monolith, single Docker image, deployed with Kamal to a VPS.**

- **App structure**: standard Rails app (not `--api` mode) — server-rendered views with Turbo
  Frames/Streams driving the upload → analyze → preview → download flow, Stimulus for light
  client-side interactivity. No separate JS frontend framework or hand-rolled JSON API.
  `JobDescriptionsController#create`, `PreviewsController#create`, and `DownloadsController#
  create` each `respond_to` with both `format.html` and `format.turbo_stream`, rendering the
  *same* template either way — no partials that can drift between the two formats (ADR-0014).
  System tests run with real CSRF forgery protection enabled, unlike integration tests
  (`test/application_system_test_case.rb`; ADR-0013) — a deliberate, narrow scope, not a global
  `config/environments/test.rb` change. Two smaller UX follow-ups from the turbo_stream
  conversion remain open: #65, #66 (see ADR-0014's Consequences).
- **JS/CSS**: `importmap-rails` (no Node build step) + `tailwindcss-rails`. Keeps the Docker
  image Node-free, simplifying the Kamal deploy.
- **Database**: Postgres only, no Redis. Rails 8's Solid trio (Solid Queue, Solid Cache, Solid
  Cable) runs background jobs, caching, and pub/sub off the same Postgres instance — one fewer
  service for a solo maintainer to run under Kamal.
- **Background jobs**: LLM calls and PDF rendering are slow and cost-bearing, so in **production**
  they run as Solid Queue jobs (`config.active_job.queue_adapter = :solid_queue`) rather than
  inline in the request, with Turbo Streams pushing results back to the page. This is also where
  per-user rate limiting on LLM/PDF usage should live. **Development/test intentionally stay on
  Rails' default `:async` in-process adapter** rather than also running real Solid Queue locally —
  no separate local `queue` database, no extra docker-compose worker service; Turbo Stream
  broadcast behavior is identical from the browser's perspective regardless of which ActiveJob
  adapter ran the job. `config/cable.yml`'s production adapter is `solid_cable`, not the
  Rails-default `redis` — consistent with "no Redis" above.
- **LLM client**: `RubyLLM` gem (not `ruby-anthropic`) for the Claude API calls that power
  requirement extraction and bullet rewriting. Chosen over a thin API wrapper because it can
  persist prompt/response pairs against ActiveRecord, which the anti-hallucination safeguard
  tests need to inspect.
- **PDF generation**: Prawn (pure Ruby, programmatic), not Grover/Puppeteer. The required resume
  template is deliberately simple — no tables, columns, or images — so Prawn's flow layout is
  sufficient and avoids bundling headless Chrome into the Kamal image. Fonts are **embedded from
  `vendor/fonts/`, not Prawn's built-in base-14 faces**, which are Windows-1252 only and crashed on
  any name outside that set (ADR-0018).
- **LinkedIn export parsing**: two selectable strategies (issue #4) — an LLM extractor that sends
  the uploaded file straight to Claude via RubyLLM's structured output (`with_schema`, robust to
  arbitrary resume layouts — though issue #11 added a `pdf-reader` read of the same file
  purely to verify the LLM's output against it, so this strategy isn't `pdf-reader`-free
  anymore; see Project layout) and a deterministic extractor
  (`pdf-reader` + regex/heuristics for PDF, direct `JSON` mapping for JSON) that's free and fully
  unit-testable but only reliable on LinkedIn's fairly consistent PDF export layout.
- **Auth**: Rails 8's built-in authentication generator, not Devise.
- **Testing**: Minitest, the Rails default — no extra gem needed.

**Why Rails**: full reasoning and alternatives considered are recorded in
[ADR-0001](docs/adr/0001-rails-8-hotwire-monolith.md) and
[issue #1](https://github.com/jeanflaragao/resume-ats-optimizer/issues/1) — not repeated here.

## Architecture Conventions

Pragmatic Rails, borrowing specific DDD vocabulary/patterns — not full
DDD layering. No `app/domain/`, `app/application/`, `app/infrastructure/`
folders. Everything lives in standard Rails locations (`app/models/`,
`app/services/`), organized by domain namespace, not technical layer.

- **Namespace by domain, not by technical type**: `Resume::`, `JobDescription::`
  — not a generic `Services::` catch-all. (Already the pattern in use.)
- **Entities**: ActiveRecord models (`Resume`, `Experience`, `Education`).
  Keep them thin — validations, associations, scopes. No business logic
  that spans multiple models; that belongs in a service object.
- **Service Objects**: plain Ruby class, single `.call` class method, one
  responsibility (e.g. `Comparison`, `MatchScore`, `BulletRewriter`,
  `Resume::Import`). This is the primary pattern for business logic — not
  repositories, not abstracted persistence layers. ActiveRecord *is* the
  data access layer; don't hide it behind an interface.
- **Value Objects**: immutable, no identity, use `Data.define`
  (e.g. `Comparison::Result`). Prefer these over plain hashes for
  structured data passed between service objects.
- **Query Objects**: only introduce when a query is genuinely complex
  and reused (e.g. `Experience::ByRelevance.call(resume)`) — not by default.
  A normal AR scope is fine until it isn't.
- **No magic numbers**: any non-obvious constant (weights, thresholds,
  limits) must be a named, documented constant (e.g. `MatchScore::WEIGHTS`)
  — not an inline literal.
- **Ubiquitous language**: class/method names should match the language
  used in GitHub issues and this file (e.g. "requirements", "comparison",
  "match score"), not implementation-detail names.
- **No LLM calls inside deterministic services**: `Comparison` and
  `MatchScore` must remain LLM-free. Only extractors
  (`Resume::Extractors::Llm`, `JobDescription::Extractor`) and `BulletRewriter`
  call the LLM.
- **Don't reach for repository/aggregate patterns**: full DDD abstraction
  over ActiveRecord is unnecessary indirection at this project's scale.
  `resume.experiences` direct access is fine; no enforced "access only through
  the aggregate root" rule.

## Local development

No Postgres or `libpq` is required on the host — everything runs through Docker Compose
(`docker-compose.yml` + `Dockerfile.dev`, dev-only; production is intended to build from the
root `Dockerfile` via Kamal, but `config/deploy.yml` doesn't actually exist yet — see issue #48).

- Copy `.env.example` to `.env` and fill in `ANTHROPIC_API_KEY` before running anything that
  calls the LLM (extraction, bullet rewriting) — gitignored, read automatically by
  `docker compose`. Without it, LLM-calling code fails auth; everything else (deterministic
  services, PDF rendering) works fine without a key. Leave `ENABLE_REAL_LLM_CALLS` unset for
  local/manual testing — every LLM call site returns a labeled stub instead of hitting the real
  API (see `LlmCallGuard` in Project layout below). Only set it to `true` to deliberately test
  real extraction/rewrite quality.
- `docker compose run --rm web bundle install` — install/update gems (writes `Gemfile.lock`
  back to the host, runs as a non-root user matching your host UID so files aren't root-owned).
- `docker compose run --rm web bin/rails db:prepare` — create/migrate dev & test databases.
- `docker compose up web` — boot the app at `localhost:3000` (health check at `/up`).
- `docker compose run --rm web bin/rails test` — run the Minitest suite (add a file path to run
  a single file, `TEST=path/to/test.rb LINE=n` or `bin/rails test path/to/test.rb:n` for a
  single test).
- `docker compose run --rm web bin/rubocop` — lint (rubocop-rails-omakase config).
- `docker compose down` — stop containers; add `-v` to also wipe the `db_data`/`bundle_data`
  volumes for a clean slate.

## Project layout

Otherwise standard Rails 8 conventions.

- **`app/models`**: `Resume` (`name`/`email`/`phone` nullable, `summary:text`, `skills:jsonb`)
  `has_many :experiences`/`:educations`, ordered by `position:integer`, `dependent: :destroy`.
  `Experience` (`company`/`title` required, `bullets:jsonb`) and `Education` (`school` required)
  `belongs_to :resume`. `Resume.owner_token` (nullable, indexed) is a placeholder for a real
  `user_id` FK once auth lands — populated from `current_owner_token`, enforced only at the
  controller layer. `Resume::PdfRequest` (`resume_pdf_requests`: `download_id:uuid` unique,
  `text` **Active-Record-encrypted, non-deterministic**, `created_at` only) holds a download's
  pasted job description so it does *not* travel as an Active Job argument — Solid Queue
  serializes those into a plaintext column that nothing clears for a failed job (issue #76,
  ADR-0022). Destroyed by the job on success; `.purge_stale!` (`PURGE_AFTER`, 15 minutes, derived
  on the constant — **not** inherited from ADR-0012) collects the rest from `config/recurring.yml`.
- **`app/services/resume/`**: import/extraction under the `Resume::` namespace.
  - `Import.call(file:, strategy: "llm" | "regex")` — infers pdf/json from the filename, picks
    the matching extractor, persists via `create!` (rolls back on invalid data rather than
    persisting partial results). Records the extractor in `resumes.source`.
  - `Extractors::Llm` — sends the file to Claude (`with_schema`). Verifies every field against
    the file's own text before returning it (`FidelityCheck` below): an unverified `company`/
    `title`/`school` drops the whole entry, unverified bullets/skills/dates are dropped/nulled in
    place. Every dropped field is logged without its raw value — ADR-0015.
  - `Extractors::PdfRegex`/`JsonMapper` — deterministic fallbacks (best-effort PDF heuristics /
    direct JSON mapping); `PdfRegex` doesn't extract `name`/`email`/`phone`.
- **`app/services/job_description/extractor.rb`**: `JobDescription::Extractor.call(text:, chat:
  LlmCallGuard.chat)` pulls `title`/`required_skills[]`/`preferred_skills[]`/`keywords[]` out of
  pasted job-posting text. Not persisted — passed straight into `Comparison`.
- **`app/services/comparison.rb`**: `Comparison.call(resume:, requirements:)` — deterministic,
  LLM-free. Matches requirement lists against the resume's skills/summary/bullets via
  `WordBoundaryMatchable` (`app/services/concerns/`, case-insensitive word-boundary match, shared
  with `FidelityCheck`). Returns a `Comparison::Result` (`Data.define`).
- **`app/services/fidelity_check.rb`**: `FidelityCheck.call(candidate_text:, source_text:,
  min_token_coverage:)` — paraphrase-tolerant verification used wherever legitimate rewording is
  expected (rewritten bullets, extracted text). Any new digit sequence in `candidate_text` fails
  immediately; otherwise a `min_token_coverage` ratio of significant words must trace back to
  `source_text`. Deterministic, not an LLM judge.
- **`app/services/bullet_rewriter.rb`**: `BulletRewriter.call(bullets:, job_description_text:,
  chat: LlmCallGuard.chat)` rephrases bullets 1:1, same order (raises
  `MismatchedBulletCountError` otherwise). Each rewrite is checked via `FidelityCheck` against
  *only* its own original bullet — not the job description, which would let a hallucination
  phrased in the JD's own vocabulary pass unverified. A failing bullet falls back to the original.
- **`app/services/match_score.rb`**: `MatchScore.call(comparison:)` — 0-100 integer, or `nil` if
  there was nothing to score against. Required skills weight 3x, preferred 2x, keywords 1x
  (`MatchScore::WEIGHTS`).
- **`app/services/resume/pdf.rb`**: `Resume::Pdf.call(resume:)` — Prawn, single-column PDF.
  Header → Summary → Experience → Education → Skills, each section skipped when blank.
  Duck-typed against `resume` (no `ActiveRecord`-specific calls), which lets
  `Resume::Optimization` below feed it a non-persisted value object unchanged. Renders in embedded
  Liberation Sans (metric-compatible with Helvetica, so the layout is unchanged) with DejaVu Sans
  as a glyph fallback. Prawn draws a missing glyph as an invisible `.notdef` rather than raising,
  so a pre-render guard raises `Resume::Pdf::UnrenderableCharacterError` for any script no embedded
  font covers (CJK, Hebrew, Arabic, Devanagari, emoji) instead of shipping a blank name line — see
  ADR-0018. The error carries a Unicode block name and a count, never the characters or codepoints
  (ADR-0015: for a CJK name the codepoints *are* the name).
- **`app/services/resume/optimization.rb`**: `Resume::Optimization.call(resume:,
  job_description_text:, chat: LlmCallGuard.chat)` bridges `BulletRewriter` and `Resume::Pdf` —
  runs `BulletRewriter` once per experience, returns a `Resume::Optimization::Result`
  (`Data.define` mirroring `Resume::Pdf`'s expected attribute names — `experiences` *and*
  `educations` are value objects, so the Result carries no ActiveRecord relation and can be cached
  across processes). Never persists or mutates the source records. `.rewrite_request_count(resume)`
  is the fan-out width (experiences with bullets), used by the daily-cap pre-flight and by
  `Resume::CachedOptimization`'s lock timing.
- **`app/services/resume/cached_optimization.rb`**: `Resume::CachedOptimization.call(resume:,
  job_description_text:, context: :preview | :download, chat: LlmCallGuard.chat)` — the entry point
  **both** the preview and the download use, so one preview-then-download journey pays for one
  bullet-rewrite fan-out, not two, and the downloaded PDF is rendered from the rewrites the user
  approved on screen (issue #83, ADR-0021). Caches the `Result` in `Rails.cache` for `CACHE_TTL`
  (15 minutes, matching `Resume::OptimizedPdfJob::CACHE_EXPIRY` — the same sitting), keyed by
  `KEY_VERSION` + `BulletRewriter.prompt_fingerprint` + a digest of the resume's and its children's
  `cache_key_with_version` + a **digest** of the normalized job description text. The text itself is
  never stored. A `write(unless_exist:)` lock keeps a double-submit from running two pipelines; its
  wait and TTL scale with the number of experiences, from a measured per-request latency recorded in
  the constants' comment **against a specific model** — changing `config.default_model` invalidates
  them. On a miss it re-runs rather than failing the download, and counts the miss per context
  (`resume_optimization/<context>_<outcome>_on/<date>`), so a download that had to re-run is visible
  rather than assumed.
- **`app/services/llm_call_guard.rb`**: `LlmCallGuard.chat` is the shared `chat:` default for
  every LLM call site above — a stopgap against accidental real Anthropic API usage locally, not
  real rate limiting (issue #22). `ENABLE_REAL_LLM_CALLS` (default `false`) returns a labeled
  `StubChat` instead of touching the network. When enabled it returns a **stateless `MeteredChat`
  handle, not a live `RubyLLM::Chat`**: resolving a chat is free, and each `ask` counts one call
  and issues it against a freshly built chat, so a handle threaded through N rewrites bills N and
  counts N with a flat payload (ADR-0019). `with_schema` returns a new handle rather than mutating
  self. The cap (`MAX_LLM_CALLS_PER_DAY`, default `10`) is enforced twice: `ensure_headroom!(n)`
  pre-flights a whole flow where the count is knowable — `Resume::Optimization` knows it from the
  experiences that have bullets — and the per-request check inside `ask` backstops it, since
  pre-flight deliberately does not reserve. Both raise
  `LlmCallGuard::DailyLimitExceededError`. **Neither variable defaults in production**:
  `LlmCallGuard.validate_configuration!`, called from `config/initializers/llm_call_guard.rb`,
  refuses to finish booting unless `ENABLE_REAL_LLM_CALLS` and `MAX_LLM_CALLS_PER_DAY` (a positive
  Integer) are both set, plus `ANTHROPIC_API_KEY` when real calls are on — otherwise a deploy ships
  stub placeholder text into users' PDFs, or a global 10-request/day ceiling, and finds out from a
  user (ADR-0020). Stub mode outside dev needs a second explicit `ALLOW_STUB_LLM=true`, and then
  every page carries a "Demo mode" banner (`app/views/layouts/_stub_mode_banner.html.erb`). The one
  exemption is `SECRET_KEY_BASE_DUMMY`, set by `Dockerfile:50`'s `assets:precompile` — the image
  build boots Rails under `RAILS_ENV=production` with no deploy environment and makes no LLM calls.
  Sizing input for the production cap: one full user flow costs `2 + E` provider requests, `E` =
  experiences with bullets — `2 + 2E` before ADR-0021, and still `2 + 2E` whenever a download misses
  the optimization cache. A counter that can't be read (`Rails.cache.increment`
  returning `nil`: `:null_store`, or a transient error Solid Cache's failsafe swallows) **fails
  closed** with the distinct `LlmCallGuard::BudgetUnavailableError` — "we can't see the budget"
  gets "try again in a moment", not the cap's "try again tomorrow".
- **`app/controllers/resumes_controller.rb`**: `new`/`create`/`show`. `create` passes the upload
  straight into `Resume::Import.call` (strategy hardcoded to `"llm"`, not user-selectable),
  enforcing `MAX_UPLOAD_BYTES` first (ADR-0017). Rescues invalid/unsupported-format and
  file-parsing errors (ADR-0016) by re-rendering `:new` with a flash. `show` scopes by
  `current_owner_token`.
- **`app/controllers/job_descriptions_controller.rb`**: `create` wires the job-description
  textarea on `resumes/show.html.erb` to `JobDescription::Extractor` → `Comparison` →
  `MatchScore`, enforcing `MAX_JOB_DESCRIPTION_LENGTH` (ADR-0017). `MatchScore.call`'s `nil` case
  renders a distinct message rather than a misleading 0%. Uses `find_owned_resume!` (shared by
  every controller below).
- **`app/controllers/previews_controller.rb`**: `create` wires the "Preview optimized resume"
  button to `Resume::CachedOptimization` (`context: :preview`), same length-bound pattern. `job_description_text` is
  resubmitted via a hidden field kept in sync with the visible textarea
  (`sync_controller.js`), each form independently CSRF-scoped (ADR-0013). Renders a Tailwind
  HTML template (not an embedded PDF) mirroring `Resume::Pdf`'s layout. Synchronous, no Solid
  Queue.
- **`app/jobs/resume/optimized_pdf_job.rb`** + **`app/controllers/downloads_controller.rb`**:
  `create` validates `job_description_text` (same length bound), writes it to an encrypted
  `Resume::PdfRequest`, enqueues `Resume::OptimizedPdfJob.perform_later(resume_id:,
  pdf_request_id:, download_id:)` — **the text itself is never a job argument** (issue #76,
  ADR-0022) — and renders a status page subscribed via
  `turbo_stream_from`. `resume_id`/`download_id` stay in the signature because `record_failure`
  needs them when the record is gone; a missing request broadcasts `EXPIRED_REQUEST_MESSAGE`
  rather than hanging the page. The job runs `Resume::CachedOptimization` (`context: :download`) →
  `Resume::Pdf` — within `CACHE_TTL` of the preview this **reuses** the preview's rewrites rather
  than re-running them, which is both the cost fix and the reason the downloaded PDF matches what
  the user approved on screen (issue #83, ADR-0021; on a miss it re-runs, and the bullets then
  legitimately differ). It writes the
  PDF bytes to `Rails.cache` (Solid Cache in production, ADR-0012), and broadcasts to
  `downloads/_ready` or `_failed`. A broadcast can arrive before the page's ActionCable
  subscription connects, so `DownloadsController#ready` gives a one-shot fallback check on
  connect — see [issue #72](https://github.com/jeanflaragao/resume-ats-optimizer/issues/72) for
  revisiting this properly. A **failed** job also writes `{ resume_id:, error: }` under the same
  cache key, so `#ready` can tell "failed" from "still running" — without it a lost failure
  broadcast left the page on "Generating…" forever (ADR-0018). `show` re-verifies ownership via `find_owned_resume!` before
  `send_data`-ing the bytes. `test/system/resume_downloads_test.rb` is the repo's first system
  test, and what caught the ADR-0010/ADR-0014 Turbo Drive gap.
- **`config/recurring.yml`**: production-only Solid Queue schedule — clears finished Solid Queue
  jobs hourly, and runs `Resume::PdfRequest.purge_stale!` every 5 minutes. Nothing runs this in
  dev/test (and nothing runs it in production yet either — issue #48), so
  `test/config/recurring_test.rb` asserts the entries resolve and that the purge interval stays
  under `PURGE_AFTER` instead.
- **Active Record Encryption**: keys live in `config/credentials.yml.enc`. `config/environments/
  test.rb` sets **throwaway** keys that override them, because CI has no `config/master.key`
  (gitignored, and the workflow sets no `RAILS_MASTER_KEY`) — without that, anything using
  `encrypts` raises there. Environment config wins over credentials by design
  (`activerecord`'s `active_record_encryption.configuration` initializer).

## Repository setup

- **CI** (`.github/workflows/ci.yml`): four required parallel jobs on every push to `master` and
  every PR — `test` (`bin/rails db:prepare test test:system`, Postgres 16 service container,
  Chrome for system tests; SimpleCov's `minimum_coverage 90` in `test/test_helper.rb` fails this
  job below that threshold), `lint` (`bin/rubocop`), `scan_ruby` (`bin/brakeman`), `scan_js`
  (`bin/importmap audit`).
- **Branch protection on `master`**: all four CI jobs required, `strict` + `enforce_admins`, no
  direct pushes. The repo is public (required for branch protection on GitHub's Free plan) with
  secret scanning + push protection enabled, and Dependabot configured for automatic
  version-update PRs (`.github/dependabot.yml`).

## Next steps for Claude

When a past decision needs documenting, prefer writing a new ADR (`docs/adr/`, see
`docs/adr/README.md` for the format and the never-rewrite convention) over expanding narrative
here — see issue #21 for why this file used to be 508 lines. Keep Project layout in sync with the
code as Phase 6 (automation & quality) work lands, but as a current-state file map, not a
chronological retelling.
