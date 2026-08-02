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

The Rails app is scaffolded (issue #3) per the Stack decided in issue #1, the resume data model
exists (issue #5: `Resume`/`Experience`/`Education` — originally named `Cv`, renamed to `Resume`
for clarity), resume import/parsing exists (issue #4: `Resume::Import` with LLM and
deterministic extraction strategies), the job-description requirement extraction prompt exists
(issue #7: `JobDescription::Extractor`, LLM-only — pasted text, no file upload or deterministic
strategy), resume/job comparison exists (issue #8: `Comparison`, deterministic — see Project
layout below), the bullet point rewriting prompt exists (issue #9: `BulletRewriter`, LLM-only),
ATS match score calculation exists (issue #10: `MatchScore`, deterministic, built on
`Comparison::Result`), and hallucination safeguards exist for both LLM call sites (issue #11:
`FidelityCheck`, deterministic — `BulletRewriter` falls back to the original bullet on failure,
`Resume::Extractors::Llm` surgically drops/nulls unverified fields; see Project layout below), and
`Resume` has `name`/`email`/`phone` (issue #41, a prerequisite filed ahead of #12 specifically so
the PDF template has real data for an identity header — extracted via the LLM strategy and
`JsonMapper`, not yet via `PdfRegex`), the ATS-friendly PDF template exists (issue #12:
`Resume::Pdf`, deterministic — Prawn, see Project layout below), and PDF generation from
optimized (bullet-rewritten) resume data exists (issue #13: `Resume::Optimization`, LLM-only via
`BulletRewriter`, non-persisting — see Project layout below), and the LinkedIn export upload form
exists (issue #15: `ResumesController`/`app/views/resumes` — the app's first controller/routes/
views, plus a `LlmCallGuard` safety net added as a prerequisite so local/manual testing can't
trigger real Anthropic API calls by accident, and a placeholder session-based `owner_token` on
`Resume` since real auth doesn't exist yet; see Project layout below), and the job description
input field exists (issue #16: `JobDescriptionsController`, wiring the already-existing
`JobDescription::Extractor`/`Comparison`/`MatchScore` pipeline to a form on `resumes/show` — see
Project layout below), and the resume preview screen exists (issue #17: `PreviewsController`,
wiring the already-existing `Resume::Optimization` to a second button on that same form, plus a
new `app/views/previews/show.html.erb` — see Project layout below), and the PDF download flow
exists (issue #18: `DownloadsController` + `Resume::OptimizedPdfJob`, the app's first real
Solid Queue/Turbo Stream usage — see Project layout below). Phase 5 (Frontend) is complete;
issue #47 (the Turbo Drive `data: turbo: false` stopgap — see Stack) is closed. Follow-up
infrastructure issue #48 (Kamal deployment doesn't exist yet, so the Solid Queue worker has
nowhere to actually run in production) remains open, alongside two smaller UX follow-ups #47
itself surfaced rather than fixed (#65, #66 — see Stack). The project is named
`resume-ats-optimizer`, a hosted, multi-user tool for
optimizing resumes against Applicant Tracking Systems (ATS): upload a LinkedIn data export,
paste a job description, and get back an ATS-friendly, tailored resume as a downloadable PDF.

## Stack

**Rails 8, Hotwire monolith, single Docker image, deployed with Kamal to a VPS.**

- **App structure**: standard Rails app (not `--api` mode) — server-rendered views with Turbo
  Frames/Streams driving the upload → analyze → preview → download flow, Stimulus for light
  client-side interactivity. No separate JS frontend framework or hand-rolled JSON API.
  **Resolved (issue #47)**: `JobDescriptionsController#create` (#16), `PreviewsController#
  create` (#17), and `DownloadsController#create` (#18) originally all `render`ed an HTML
  template directly in response to a POST — Turbo Drive rejects that client-side ("Form
  responses must redirect to another location") unless the response is either a redirect or
  `turbo_stream`. This was only caught once #18 added the repo's first system test
  (`test/system/resume_downloads_test.rb`) — no earlier issue had one, since integration tests
  don't run real browser JS and can't see Turbo Drive reject a response. The interim stopgap
  (`data: { turbo: false }` on all three affected forms, forcing a real full-page submit instead
  of a Turbo-intercepted fetch) is gone: all three actions now `respond_to` with both
  `format.html` (declared first — empirically, a plain integration-test POST never sends an
  `Accept` header that could make declaration order matter, confirmed via `bin/rails runner`,
  but it costs nothing to be defensive) and `format.turbo_stream`. Every `format.turbo_stream`
  branch renders the *exact same template* `format.html` renders for that branch — no new
  partials, so the two formats can't drift the way the bugs below did — via two
  `turbo_stream.update` actions against two ids the layout now always provides:
  `div#main_content` (wraps `yield` in `app/views/layouts/application.html.erb`) and `div#flash`
  (the flash loop, extracted to `app/views/layouts/_flash.html.erb`, given Tailwind's
  `empty:hidden` so an always-present-but-empty flash container doesn't add gap spacing on
  flashless pages — `<main>` is `flex flex-col gap-4`, so this needed checking, not assuming).
  Swapping the *entire* `main_content` region (rather than smaller, targeted streams) is a
  deliberate tradeoff, not a neutral default: it buys single-template parity between formats at
  the cost of destroying whatever element currently has focus on every swap (focus falls to
  `<body>`, a real accessibility regression relative to the full navigation this replaces) —
  recorded, with the alternative it forwent, in ADR-0010's amendment. The address bar no longer
  changes across any of the three flows post-conversion either (a `turbo_stream` response never
  pushes history), which surfaced two follow-ups filed rather than fixed in #47: #65
  (`DownloadsController`'s already-UI-unreachable blank-input error render becomes more
  confusing, not less, once there's no URL change to hint at what happened) and #66 (refreshing
  mid-download now silently strands an already-generated PDF, since nothing survives the
  refresh to reconstruct the in-flight `download_id` from).
  **A second, since-fixed bug found the same way**: `resumes/show.html.erb`'s "Preview optimized
  resume" button originally shared one `<form>` with "Check match" via a `formaction`-overridden
  submit button (same textarea, two destinations) — this crashed with
  `ActionController::InvalidAuthenticityToken` on a real (non-Turbo) POST. `config.load_defaults
  8.0` enables per-form CSRF tokens, which bind a form's `authenticity_token` to its own declared
  `action`; `formaction` submits somewhere else, so the token no longer matches. Fixed (not
  deferred) by giving that button its own `<form>` (correctly scoped, its own valid token) with a
  hidden `job_description_text` field kept in sync with the visible textarea by
  `app/javascript/controllers/sync_controller.js`. **This class of bug was invisible to every
  automated test in this repo until issue #57**: `config/environments/test.rb` still sets
  `config.action_controller.allow_forgery_protection = false` (a common, otherwise-reasonable
  Rails default) for integration tests, which run in-process and never render real forms or
  carry tokens — that part is by design, not a gap, since there's nothing real CSRF verification
  would exercise there. System tests, which do drive real forms in a real browser, now opt back
  into forgery protection for the duration of each example (`test/application_system_test_case.rb`,
  see ADR-0010's amendment/ADR-0013), so the exact class of bug that shipped in #17 and was only
  caught by hand during #18 (and again, deliberately reproduced by hand once more during #57's
  own implementation) now fails a system test instead of requiring manual browser testing to
  catch. A dedicated `test/system/forgery_protection_test.rb` guards against this mechanism being
  silently deleted later. Both this bug and the `formaction` issue above were originally found via
  manual browser testing against the dev server while implementing #18, not by any test in the
  suite at the time.
- **JS/CSS**: `importmap-rails` (no Node build step) + `tailwindcss-rails`. Keeps the Docker
  image Node-free, simplifying the Kamal deploy.
- **Database**: Postgres only, no Redis. Rails 8's Solid trio (Solid Queue, Solid Cache, Solid
  Cable) runs background jobs, caching, and pub/sub off the same Postgres instance — one fewer
  service for a solo maintainer to run under Kamal.
- **Background jobs**: LLM calls and PDF rendering are slow and cost-bearing, so in **production**
  they run as Solid Queue jobs (`config.active_job.queue_adapter = :solid_queue`, wired in #18)
  rather than inline in the request, with Turbo Streams pushing results back to the page. This is
  also where per-user rate limiting on LLM/PDF usage should live. **Development/test intentionally
  stay on Rails' default `:async` in-process adapter** rather than also running real Solid Queue
  locally (decided in #18) — no separate local `queue` database, no extra docker-compose worker
  service. This isn't a lesser architecture for dev, just a smaller one: Turbo Stream broadcast
  behavior is identical from the browser's perspective regardless of which ActiveJob adapter ran
  the job, and durability/admin-visibility across process restarts — the actual reasons to want
  Solid Queue — don't matter for a local dev/test run. Production's queue *and* Solid Cable
  (`config/cable.yml`, needed the moment #18 added the app's first real ActionCable broadcast)
  both already had unused database entries in `config/database.yml` from the initial scaffold;
  #18 is what actually wired them up (and fixed `cable.yml`'s production adapter, which was still
  the Rails-default `redis`, contradicting "no Redis" above, until #18 pointed it at `solid_cable`
  instead — the gem was already in the Gemfile but never actually configured).
- **LLM client**: `RubyLLM` gem (not `ruby-anthropic`) for the Claude API calls that power
  requirement extraction and bullet rewriting. Chosen over a thin API wrapper because it can
  persist prompt/response pairs against ActiveRecord, which the anti-hallucination safeguard
  tests need to inspect.
- **PDF generation**: Prawn (pure Ruby, programmatic), not Grover/Puppeteer. The required resume
  template is deliberately simple — no tables, columns, or images, standard fonts — so
  Prawn's flow layout is sufficient and avoids bundling headless Chrome into the Kamal image.
- **LinkedIn export parsing**: two selectable strategies (issue #4) — an LLM extractor that sends
  the uploaded file straight to Claude via RubyLLM's structured output (`with_schema`, robust to
  arbitrary resume layouts — though issue #11 added a `pdf-reader` read of the same file
  purely to verify the LLM's output against it, so this strategy isn't `pdf-reader`-free
  anymore; see Project layout) and a deterministic extractor
  (`pdf-reader` + regex/heuristics for PDF, direct `JSON` mapping for JSON) that's free and fully
  unit-testable but only reliable on LinkedIn's fairly consistent PDF export layout.
- **Auth**: Rails 8's built-in authentication generator, not Devise.
- **Testing**: Minitest, the Rails default — no extra gem needed.

**Why Rails**: chosen directly by the user rather than picked from a generic framework
comparison — the priority was the "most modern" idiomatic Rails setup (Hotwire, Solid trio,
Kamal) for a solo-maintainer, low-ops-overhead deploy. Comparison logic and match scoring
(deterministic, not LLM output) are kept as plain Ruby service objects so they stay testable and
free of hallucination risk. Full reasoning and alternatives considered are recorded on
[issue #1](https://github.com/jeanflaragao/resume-ats-optimizer/issues/1).

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
  calls the LLM (extraction, bullet rewriting). `.env` is gitignored (`.gitignore`'s `/.env*`
  rule, with `!/.env.example` as the one committed exception) and read automatically by
  `docker compose` at the project root; `docker-compose.yml`'s `web` service passes it through
  to the container as `ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY}` — a reference, never a literal
  key — for `config/initializers/ruby_llm.rb` to pick up. Without it, LLM-calling code raises/
  fails auth; everything else (deterministic services, PDF rendering) works fine without a key.
  `.env.example` also documents `ENABLE_REAL_LLM_CALLS` (default `false`) and
  `MAX_LLM_CALLS_PER_DAY` (default `10`) — see `LlmCallGuard` in Project layout below. Leave
  `ENABLE_REAL_LLM_CALLS` unset for local/manual testing (including through the browser); every
  LLM call site returns a labeled stub instead of hitting the real API. Only set it to `true`
  (with a real `ANTHROPIC_API_KEY`) to deliberately test real extraction/rewrite quality.
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

- **`app/models`**: `Resume` (`name`/`email`/`phone` — all nullable, added ahead of issue #12
  specifically so the PDF template has real data for an identity header; `summary:text`,
  `skills:jsonb` array of strings) `has_many :experiences` and `:educations`, both ordered by a
  `position:integer` column (preserves the source resume's original ordering independent of
  dates, which may be missing/ambiguous from a parsed export) and `dependent: :destroy`.
  `Experience` (`company`/`title` required, `bullets:jsonb` array of strings) and `Education`
  (`school` required) each `belongs_to :resume`. Bullets and skills are jsonb string arrays
  rather than their own tables — unstructured lists don't need independent identity yet;
  structured fields (`company`, `title`, `school`, dates) are real columns. No `User`/auth model
  exists yet, so `Resume` has a nullable `owner_token:string` (indexed; issue #15) instead of a
  real owner — a placeholder populated from `ApplicationController#current_owner_token` (an
  opaque per-browser-session token, `session[:owner_token] ||= SecureRandom.hex(32)`) rather than
  a `user_id` FK. Existing service-object/console usage that creates a `Resume` with no HTTP
  session context (tests, `Resume::Import` called directly) leaves it `nil`, which is fine — it's
  only enforced at the controller layer (`ResumesController#show` scopes by it). Replace with a
  real `user_id` FK once the Rails 8 auth generator lands; this was never meant to be permanent.
  Table/model were originally named
  `Cv`/`cvs`, renamed to `Resume`/`resumes` via a dedicated `rename_table`/`rename_column`
  migration (not by editing the original migrations) since they'd already run in dev.
- **`app/services/resume/`**: resume import/extraction, all under the `Resume::` namespace
  (nested under the `Resume` model itself — a supported Zeitwerk "class as namespace" pattern).
  - `Import` — entry point, `Resume::Import.call(file:, strategy: "llm" | "regex")`. Infers
    format (pdf/json) from the filename, picks the matching extractor, and persists the result
    inside a transaction (`create!`, not `create` — an extraction that can't satisfy
    `Experience`/`Education` validations rolls back and raises rather than silently persisting
    partial data). Records which extractor ran in `resumes.source`.
  - `ExtractionSchema` — the `RubyLLM::Schema` used by the LLM extractor; defines the shared
    normalized hash shape (`name`, `email`, `phone`, `summary`, `skills`, `experiences[]`,
    `educations[]`) that every extractor returns and `Import` consumes.
  - `Extractors::Llm` — sends the file directly to Claude (`chat.with_schema(...).ask(prompt,
    with: file_path)`), works unmodified for PDF or JSON. Takes `chat:` as a keyword arg
    (default `LlmCallGuard.chat`, see below; tests inject a hand-rolled fake directly instead).
    Since
    issue #11, the prompt alone isn't trusted: every field is verified against the file's own
    text before being returned (see `FidelityCheck` below) — unverified bullets/skills/dates are
    dropped/nulled in place, an unverified `company`/`title`/`school` drops the whole
    experience/education entry (nulling would still fail `Resume::Import`'s `create!` and roll
    back the entire resume). Reading the file's text for this (via `pdf-reader` for PDFs)
    reintroduces `PdfRegex`'s layout-reliability ceiling as a verification floor here too — some
    false-positive drops on PDFs are an accepted trade-off, not a bug. `phone` is verified by its
    digit-only representation rather than a literal match (legitimate reformatting is expected,
    same idea as the date year-check). Every dropped field, not just `email`/`phone`, is logged
    without its raw value (field name/reason only) — ADR-0015 extended what was originally an
    email/phone-only exception to every field, since name, bullets, summary, company/school
    names, and skills are all personal data too; see Logging and PII above.
  - `Extractors::PdfRegex` — deterministic PDF path: `pdf-reader` for text, then a small state
    machine over the lines (section headers → date-range lines → bullet-prefixed lines) to find
    entry boundaries. Best-effort by nature; see the Stack section above for the trade-off. Does
    **not** extract `name`/`email`/`phone` (would need new heuristics for a pre-section-header
    name line) — those stay `nil` for the `"regex"` strategy, consistent with its lesser-fidelity
    character elsewhere.
  - `Extractors::JsonMapper` — deterministic JSON path: parses and maps a JSON file already
    shaped like the normalized hash above.
  - Note: `config/initializers/ruby_llm.rb` has `require "ruby_llm/schema"` — the schema DSL
    isn't auto-required by the `ruby_llm` gem itself.
- **`app/services/job_description/`** (issue #7): `JobDescription::Extractor.call(text:, chat:
  LlmCallGuard.chat)` pulls ATS-relevant requirements out of a pasted job description — no file
  upload, so unlike `Resume::Extractors::Llm` it embeds the text directly in the prompt instead
  of using `with:`. `JobDescription::ExtractionSchema` defines the shape it returns: `title`,
  `required_skills[]`, `preferred_skills[]`, `keywords[]` (catch-all for ATS-relevant terms —
  tools, certifications, methodologies — not already captured as a skill). No persistence model
  yet — extracted requirements are passed straight into `Comparison` (below) rather than stored.
- **`app/services/concerns/word_boundary_matchable.rb`** (issue #11): `word_boundary_match?(term,
  text)` — a case-insensitive, word-boundary text match (so "Go" doesn't false-positive against
  "Google") shared by `Comparison` and `FidelityCheck`, the two places that need "is this term
  actually present in this text" as a primitive.
- **`app/services/comparison.rb`** (issue #8): `Comparison.call(resume:, requirements:)` is a
  plain, deterministic (non-LLM) Ruby object — see the Stack section's rationale for keeping
  match logic hallucination-free. It sorts each of `requirements`'s `required_skills[]`,
  `preferred_skills[]`, and `keywords[]` into matched/missing via `WordBoundaryMatchable` against
  the resume's `skills`, `summary`, and every experience's `bullets`. Returns a
  `Comparison::Result` (a `Data.define`) with `matched_required_skills`/`missing_required_skills`/
  etc. `requirements` is the plain hash `JobDescription::Extractor` returns — not persisted, so
  nothing new to store or relate to a `Resume` yet.
- **`app/services/fidelity_check.rb`** (issue #11): `FidelityCheck.call(candidate_text:,
  source_text:, min_token_coverage:)` — the paraphrase-tolerant counterpart to
  `WordBoundaryMatchable`'s exact match, used wherever legitimate rewording/condensing is
  expected (rewritten bullets, extracted bullets/summary) rather than verbatim content. Any
  digit sequence in `candidate_text` absent from `source_text` fails immediately (zero
  tolerance — a new number is the strongest hallucination signal and paraphrase essentially
  never introduces one); everything else must clear a caller-supplied `min_token_coverage`
  ratio of significant (non-stopword) words traceable back to `source_text`. Returns a
  `Data.define(:passed, :unverifiable_tokens)`. Deliberately deterministic, not an LLM judge —
  see the Stack section and Architecture Conventions' "no LLM calls inside deterministic
  services" rule; known limitation, accepted: can't catch purely semantic hallucination that
  introduces no new lexical tokens.
- **`app/services/bullet_rewriter.rb`** (issue #9, hallucination safeguard added in #11):
  `BulletRewriter.call(bullets:, job_description_text:, chat: LlmCallGuard.chat)` rephrases an array
  of resume bullets to pick up the job posting's terminology/keywords, one rewritten bullet per
  input bullet, same order. Unlike `Comparison`/`FidelityCheck` this *is* an LLM call (rewording
  is generative; deciding what counts as a match isn't) — the prompt explicitly forbids adding
  any skill/achievement/metric not already in the original bullet, and `call` raises
  `MismatchedBulletCountError` if the response doesn't come back 1:1, rather than silently
  misaligning rewrites to the wrong experience. Beyond that structural check, every rewritten
  bullet is run through `FidelityCheck` against *only* its own original bullet (not the job
  description, not the rest of the resume — grounding it in JD text would let a hallucinated
  achievement phrased in the JD's own vocabulary sail through unverified); a failing bullet
  falls back to its original wording and logs a warning rather than raising, since a safe 1:1
  recovery always exists here (unlike the count mismatch). Returns a plain array, no
  persistence — same pattern as `JobDescription::Extractor`/`Comparison`.
- **`app/services/match_score.rb`** (issue #10): `MatchScore.call(comparison:)` takes a
  `Comparison::Result` and reduces it to a single 0-100 integer, or `nil` if the job description
  had no required/preferred skills or keywords at all to score against (rather than a misleading
  0 or 100). Deterministic, like `Comparison` — no LLM call, nothing to hallucinate. Required
  skills count 3x toward the score, preferred skills 2x, keywords 1x (`MatchScore::WEIGHTS`),
  reflecting that a missing required skill should hurt the score more than a missing keyword.
- **`app/services/resume/pdf.rb`** (issue #12): `Resume::Pdf.call(resume:)` renders a resume as
  ATS-friendly PDF bytes (Prawn, single-column, no tables/images) — Header (name/email/phone,
  degrading gracefully per-field, omitted entirely if all three are blank) → Summary →
  Experience → Education → Skills, each section skipped outright when its underlying data is
  blank (`Array(...)`/`.present?` guards) rather than rendering empty whitespace. Accent color
  (`Resume::Pdf::ACCENT_COLOR`) is reserved for section headers/dividers only. Pagination uses a
  private `ensure_space` helper (via Prawn's `height_of`/`cursor`) so a section header can't be
  stranded alone at the bottom of a page. Deliberately duck-typed against `resume` — reads only
  plain attributes (`name`, `experiences.each { |e| e.company... }`, etc.), no
  `ActiveRecord`-specific calls — which is what lets `Resume::Optimization` (below) feed it a
  non-persisted value object with zero changes to this file.
- **`app/services/resume/optimization.rb`** (issue #13): `Resume::Optimization.call(resume:,
  job_description_text:, chat: LlmCallGuard.chat)` bridges `BulletRewriter` (#9) and `Resume::Pdf`
  (#12) — runs `BulletRewriter` once per experience against `job_description_text` and returns a
  `Resume::Optimization::Result` (a `Data.define` mirroring the exact attribute names
  `Resume::Pdf` reads off a real `Resume`/`Experience`, so `Resume::Pdf.call(resume:
  Resume::Optimization.call(...))` needs no adapter or interface change). Never persists or
  mutates the source `Resume`/`Experience` records — same resume can be re-optimized for
  different job descriptions. `educations` pass through untouched (no bullets to rewrite there).
  No caching/memoization of repeated `resume`+`job_description_text` calls yet (e.g. a future
  preview-then-download flow re-requesting the same pair) — deferred to whichever of #17/#18/#22
  ends up needing it, rather than guessing at a cache key strategy now. Also not yet wired to a
  Solid Queue job (still called synchronously, like `BulletRewriter`/`JobDescription::Extractor`)
  — that wiring is issue #18's scope, with rate limiting layered on in #22.
- **`app/services/llm_call_guard.rb`** (added as a prerequisite to issue #15): `LlmCallGuard.chat`
  is the shared `chat:` default for every LLM call site above (`Resume::Extractors::Llm`,
  `BulletRewriter`, `JobDescription::Extractor`, `Resume::Optimization`'s passthrough), replacing
  their previous bare `RubyLLM.chat` default. A blunt, process-wide stopgap against accidental
  real Anthropic API usage during local/manual testing — not a replacement for real rate
  limiting (see issue #22, and [issue #45](https://github.com/jeanflaragao/resume-ats-optimizer/issues/45)
  which tracks folding this into #22 once it lands):
  - `ENABLE_REAL_LLM_CALLS` (default `false`): when false, `.chat` returns a `StubChat` that
    duck-types `with_schema(schema).ask(prompt, with: nil).content` and returns clearly-labeled
    canned data per schema class, never touching the network.
  - `MAX_LLM_CALLS_PER_DAY` (default `10`): once real calls are enabled, `.chat` counts them via
    `Rails.cache` (a day-scoped key, so it resets automatically at midnight) and raises
    `LlmCallGuard::DailyLimitExceededError` rather than proceeding once the cap is hit.
  - Test env's `cache_store` is `:null_store` (see `config/environments/test.rb`), which no-ops
    `increment` — `test/services/llm_call_guard_test.rb` swaps in a real `MemoryStore` for the
    cap-counting tests rather than relying on the app's configured store.
- **`app/controllers/resumes_controller.rb`** + **`app/views/resumes/`** (issue #15, the app's
  first controller/routes/views): `new`/`create`/`show`. `create` passes the raw multipart
  upload (`params[:file]`, an `ActionDispatch::Http::UploadedFile`) straight into
  `Resume::Import.call` — no Active Storage, since the file is fully consumed at import time and
  nothing downstream ever re-reads it. Strategy is hardcoded to `ResumesController::DEFAULT_STRATEGY
  ("llm")`, not exposed as a form field — `"regex"` is a lesser-fidelity fallback with no basis
  for an end user to choose between them. On `ActiveRecord::RecordInvalid` (transactional
  rollback) or `Resume::Import::UnsupportedFormatError`, re-renders `:new` with
  `status: :unprocessable_entity` and a flash message rather than a separate error page. `show`
  scopes by `current_owner_token` (404s otherwise). Routes: `resources :resumes, only: %i[new
  create show]`, `root "resumes#new"`. Covered by `test/integration/resume_uploads_test.rb`
  (`ActionDispatch::IntegrationTest`, not a full `ApplicationSystemTestCase` browser test — #15
  has no Turbo Stream/Stimulus behavior yet to justify one, and running in-process is what lets
  the happy-path test rely on `LlmCallGuard`'s stub instead of a real API call; revisit this
  choice once #18 adds real async/Turbo Stream behavior worth exercising in-browser — #17
  stayed synchronous too, see below).
- **`app/controllers/job_descriptions_controller.rb`** (issue #16): single `create` action
  wiring the job-description textarea on `resumes/show.html.erb` to the already-existing
  `JobDescription::Extractor` (#7) → `Comparison` (#8) → `MatchScore` (#10) pipeline — none of
  those services changed for this issue. `job_description_text` is never persisted, only passed
  through as a request param (consistent with those services already being
  persistence-free). Blank text re-renders `resumes/show` with a `flash.now` alert (same pattern
  as `ResumesController#create`'s file-upload validation); non-blank text re-renders the same
  template with `@comparison`/`@match_score` set, which the view uses to show matched/missing
  required skills, preferred skills, and keywords, and the score itself — `MatchScore.call`'s
  documented `nil` case (job description had nothing to score against) renders a distinct
  message rather than a misleading 0%. Routes: `resources :resumes { resource :job_description,
  only: :create }`. Reuses a new `ApplicationController#find_owned_resume!` helper (extracted
  from `ResumesController#show`'s existing owner-token scoping, now shared by both controllers).
  Covered by `test/integration/job_description_comparisons_test.rb`, same
  `ActionDispatch::IntegrationTest` convention as #15.
- **`app/controllers/previews_controller.rb`** + **`app/views/previews/show.html.erb`** (issue
  #17): single `create` action wiring a "Preview optimized resume" button on `resumes/show.html.erb`
  to the already-existing `Resume::Optimization` (#13) — unchanged for this issue, including its
  `chat: LlmCallGuard.chat` default, so previewing goes through the same stub/daily-cap guard as
  every other LLM call site. `job_description_text` is never persisted here either, for the same
  reason as #16 — CLAUDE.md's own `Resume::Optimization` entry already anticipated "a future
  preview-then-download flow re-requesting the same pair" rather than caching, so #18 is expected
  to independently call `Resume::Optimization` again at download time. Renders a Tailwind HTML
  template (not an embedded/iframed PDF — cheaper, avoids a wasted Prawn render on every preview,
  and #18 renders the real PDF anyway) mirroring `Resume::Pdf`'s section order and blank-guarding,
  including its date-range formatting (inlined per-section rather than extracted — two call sites
  in one file, and `Resume::Pdf#date_range` stays a private implementation detail of that
  service rather than being pulled into a shared helper). Stays
  synchronous (no Solid Queue), consistent with #16 — that wiring remains #18's scope per
  `Resume::Optimization`'s own doc comment. Routes: `resources :resumes { resource :preview, only:
  :create }`. Reuses `find_owned_resume!` (#16). Its button now lives in its own `<form>` on
  `resumes/show.html.erb`, kept in sync with the job-description textarea by
  `app/javascript/controllers/sync_controller.js` — see the Stack section's CSRF note (found/fixed
  in #18) for why. Covered by
  `test/integration/resume_previews_test.rb`, same `ActionDispatch::IntegrationTest` convention —
  note its happy-path test asserts on `BulletRewriter`'s logged fidelity-check fallback (same
  technique `test/services/resume/optimization_test.rb` uses) rather than on `LlmCallGuard`'s stub
  label appearing verbatim, since the stub's label text itself always fails `BulletRewriter`'s own
  fidelity check and falls back to the original bullet — that fallback, not a bypass, is what
  proves the real pipeline ran.
- **`app/jobs/resume/optimized_pdf_job.rb`** + **`app/controllers/downloads_controller.rb`** +
  **`app/views/downloads/`** (issue #18): the app's first real Solid Queue job and first real
  Turbo Stream broadcast. `DownloadsController#create` validates `job_description_text`
  (resubmitted via a hidden field on `previews/show.html.erb`'s own form, same "never persisted"
  pattern as #16/#17), generates a `download_id` (`SecureRandom.uuid`), enqueues
  `Resume::OptimizedPdfJob.perform_later`, and renders a status page
  (`downloads/create.html.erb`) subscribed via `turbo_stream_from "download_#{download_id}"`.
  The job re-runs `Resume::Optimization` (#13) → `Resume::Pdf` (#12) — deliberately not reusing
  whatever #17's preview already computed, see below — then `Rails.cache.write`s the bytes
  (intended as Solid Cache, no new schema/table for a transient artifact — though the production
  cache store was never actually wired up until issue #54 closed the gap; see ADR-0012) and
  broadcasts a
  `turbo_stream.replace` of `#download_status` to either `downloads/_ready` (a link to
  `DownloadsController#show`) or `downloads/_failed` (rescued error path, so a raised exception
  doesn't leave the user staring at "Generating..." forever). **A second, real race was found and
  fixed via manual browser testing**: the job can finish and broadcast before the status page's
  ActionCable subscription has actually connected — broadcasts aren't queued for late subscribers,
  so that update is just lost, leaving "Generating..." stuck forever even though the download was
  ready the whole time (confirmed happening locally, where stub-mode LLM responses are
  near-instant; a resume with few/no bullets to rewrite could hit the same race in production,
  since there'd be little to no LLM latency there either). Fixed with a small, deliberately
  narrow fallback rather than full polling: `DownloadsController#ready`
  (`GET /downloads/:id/ready`) returns `204` if the job hasn't finished or the rendered
  `downloads/_ready` partial if it has (still owner-scoped via `find_owned_resume!`), and
  `app/javascript/controllers/download_status_controller.js` calls it exactly once, on connect,
  swapping in the result if already ready. If the normal broadcast arrives first, this is a no-op
  (`204`, nothing to swap). `DownloadsController#show` reads
  `Rails.cache.read("download/\#{id}")`, re-verifies ownership via `find_owned_resume!` against
  the cached `resume_id` before `send_data`-ing the bytes, and redirects with a flash if the
  `download_id` is missing/expired instead of erroring — the cached download_id is *not* treated
  as a bearer capability on its own, staying consistent with every other action's owner_token
  scoping. Routes: `resources :resumes { resources :downloads, only: :create }` +
  `resources :downloads, only: :show` (top-level, since the id is the opaque download_id, not
  scoped to a resume in the URL). No caching of the `Resume::Optimization` step itself (i.e. a
  preview-then-download not skipping a redundant LLM rewrite) — decided against for a first
  version: going async already removes the *latency* half of that concern (the user isn't
  blocked waiting through a second rewrite anymore, just paying for extra API calls), a correct
  cache key would need real invalidation design nothing in this app has yet, and the remaining
  concern is cost-shaped, better addressed holistically alongside #22 than as a one-off cache
  bolted on ahead of it. Tests: `test/jobs/resume/optimized_pdf_job_test.rb` (byte-level —
  `%PDF` header + `PDF::Reader` text extraction, same rigor as `resume/pdf_test.rb` — plus
  `assert_turbo_stream_broadcasts`), `test/integration/resume_downloads_test.rb`
  (enqueue/serve/expired/cross-session), and the repo's first system test,
  `test/system/resume_downloads_test.rb` (Capybara + Selenium — the Gemfile/
  `test/application_system_test_case.rb` had these configured since scaffolding but nothing had
  exercised them; needed `chromium` added to `Dockerfile.dev` and `--no-sandbox`/
  `--disable-dev-shm-usage` Chrome args added to the driver config to actually run in a
  container — see that file). Deliberately doesn't assert the live broadcast landing
  client-side (real ActionCable-over-websocket-in-a-headless-browser is a known flakiness
  source for little extra coverage beyond what `assert_turbo_stream_broadcasts` already verifies
  precisely) — just that a real browser reaches the subscribed status page, which is the one
  thing the job/integration tests can't verify. This same system test is what caught issue #47
  (see Stack) — a real, pre-existing bug in #16/#17's already-merged controllers that no
  integration test could have found.
- Phase 5 (Frontend) is complete. Follow-ups: #47 (Turbo Drive stopgap, see Stack), #48 (Kamal
  deployment doesn't exist yet — `config/deploy.yml` was never actually created despite this
  file referencing it, so #18's Solid Queue worker has nowhere to run in production yet).

## Repository setup (issue #46)

- **CI** (`.github/workflows/ci.yml`, scaffolded with the app, fixed in #46): four parallel jobs
  on every push to `master` and every PR — `test` (`bin/rails db:prepare test test:system`,
  Postgres 16 service container, Chrome installed for system tests; SimpleCov's
  `minimum_coverage 90` in `test/test_helper.rb` already fails this job below that threshold, no
  separate coverage-gate step needed), `lint` (`bin/rubocop`), `scan_ruby` (`bin/brakeman`),
  `scan_js` (`bin/importmap audit`). The originally-scaffolded workflow called
  `db:test:prepare`, a rake task that doesn't exist in Rails 8 — would have failed the `test` job
  outright; fixed to `db:prepare` (already `RAILS_ENV`-scoped to the test database).
- **Branch protection on `master`**: required status checks = all four CI job names above,
  `strict` (branches must be up to date before merging), `enforce_admins` (no bypass, including
  for the repo owner), no direct pushes. **Required making the repo public** — GitHub's Free plan
  doesn't support branch protection (classic or the newer Rulesets API) on private repos at all;
  confirmed by both APIs returning "Upgrade to GitHub Pro or make this repository public." Git
  history was checked first and confirmed clean (no `.env`, no `master.key`, no committed
  credentials — `.env` was never anything but gitignored, per the Local development section).
- **Secret scanning + push protection**: both enabled (`security_and_analysis.secret_scanning` /
  `.secret_scanning_push_protection`, both `"enabled"`). Also blocked on the private tier
  (GitHub Advanced Security, a paid add-on) until the repo went public.
- **Dependabot**: `.github/dependabot.yml` (also scaffolded with the app) keeps its original
  config — automatic version-update PRs for both `bundler` and `github-actions`, daily, up to 10
  open PRs each. Vulnerability alerts (`GET /repos/:owner/:repo/vulnerability-alerts` → `204`)
  are separately confirmed enabled — a distinct repo-level toggle from this file, which only
  governs general version-bump PRs, not vulnerability notifications.
- All four settings above were re-verified with a fresh `gh api` read after each change, not
  just trusted from the mutating call's own response (the `secret_scanning_push_protection`
  PATCH once returned 200 with the field still showing `disabled` in its own response body).

## Next steps for Claude

As the pipeline issues (#6 onward) add real structure (jobs, controllers, views), update the
Project layout section above to describe how the major pieces fit together, rather than
speculating ahead of the code that exists.
