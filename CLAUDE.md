# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
`Resume::Extractors::Llm` surgically drops/nulls unverified fields; see Project layout below).
No PDF template yet (issues #12-#18 onward, minus #4/#5/#7/#8/#9/#10/#11). The project is named
`resume-ats-optimizer`, a hosted, multi-user tool for
optimizing resumes against Applicant Tracking Systems (ATS): upload a LinkedIn data export,
paste a job description, and get back an ATS-friendly, tailored resume as a downloadable PDF.

## Stack

**Rails 8, Hotwire monolith, single Docker image, deployed with Kamal to a VPS.**

- **App structure**: standard Rails app (not `--api` mode) — server-rendered views with Turbo
  Frames/Streams driving the upload → analyze → preview → download flow, Stimulus for light
  client-side interactivity. No separate JS frontend framework or hand-rolled JSON API.
- **JS/CSS**: `importmap-rails` (no Node build step) + `tailwindcss-rails`. Keeps the Docker
  image Node-free, simplifying the Kamal deploy.
- **Database**: Postgres only, no Redis. Rails 8's Solid trio (Solid Queue, Solid Cache, Solid
  Cable) runs background jobs, caching, and pub/sub off the same Postgres instance — one fewer
  service for a solo maintainer to run under Kamal.
- **Background jobs**: LLM calls and PDF rendering are slow and cost-bearing, so they run as
  Solid Queue jobs rather than inline in the request, with Turbo Streams pushing results back to
  the page. This is also where per-user rate limiting on LLM/PDF usage should live.
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
(`docker-compose.yml` + `Dockerfile.dev`, dev-only; production still builds from the root
`Dockerfile` via Kamal per `config/deploy.yml`).

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

- **`app/models`**: `Resume` (`summary:text`, `skills:jsonb` array of strings) `has_many
  :experiences` and `:educations`, both ordered by a `position:integer` column (preserves the
  source resume's original ordering independent of dates, which may be missing/ambiguous from a
  parsed export) and `dependent: :destroy`. `Experience` (`company`/`title` required,
  `bullets:jsonb` array of strings) and `Education` (`school` required) each `belongs_to
  :resume`. Bullets and skills are jsonb string arrays rather than their own tables —
  unstructured lists don't need independent identity yet; structured fields (`company`, `title`,
  `school`, dates) are real columns. No `User`/auth model exists yet, so `Resume` has no owner —
  that's a follow-on migration whenever auth is implemented, not part of the resume schema
  itself. Table/model were originally named `Cv`/`cvs`, renamed to `Resume`/`resumes` via a
  dedicated `rename_table`/`rename_column` migration (not by editing the original migrations)
  since they'd already run in dev.
- **`app/services/resume/`**: resume import/extraction, all under the `Resume::` namespace
  (nested under the `Resume` model itself — a supported Zeitwerk "class as namespace" pattern).
  - `Import` — entry point, `Resume::Import.call(file:, strategy: "llm" | "regex")`. Infers
    format (pdf/json) from the filename, picks the matching extractor, and persists the result
    inside a transaction (`create!`, not `create` — an extraction that can't satisfy
    `Experience`/`Education` validations rolls back and raises rather than silently persisting
    partial data). Records which extractor ran in `resumes.source`.
  - `ExtractionSchema` — the `RubyLLM::Schema` used by the LLM extractor; defines the shared
    normalized hash shape (`summary`, `skills`, `experiences[]`, `educations[]`) that every
    extractor returns and `Import` consumes.
  - `Extractors::Llm` — sends the file directly to Claude (`chat.with_schema(...).ask(prompt,
    with: file_path)`), works unmodified for PDF or JSON. Takes `chat:` as a keyword arg
    (default `RubyLLM.chat`) so tests can inject a fake instead of hitting the network. Since
    issue #11, the prompt alone isn't trusted: every field is verified against the file's own
    text before being returned (see `FidelityCheck` below) — unverified bullets/skills/dates are
    dropped/nulled in place, an unverified `company`/`title`/`school` drops the whole
    experience/education entry (nulling would still fail `Resume::Import`'s `create!` and roll
    back the entire resume). Reading the file's text for this (via `pdf-reader` for PDFs)
    reintroduces `PdfRegex`'s layout-reliability ceiling as a verification floor here too — some
    false-positive drops on PDFs are an accepted trade-off, not a bug.
  - `Extractors::PdfRegex` — deterministic PDF path: `pdf-reader` for text, then a small state
    machine over the lines (section headers → date-range lines → bullet-prefixed lines) to find
    entry boundaries. Best-effort by nature; see the Stack section above for the trade-off.
  - `Extractors::JsonMapper` — deterministic JSON path: parses and maps a JSON file already
    shaped like the normalized hash above.
  - Note: `config/initializers/ruby_llm.rb` has `require "ruby_llm/schema"` — the schema DSL
    isn't auto-required by the `ruby_llm` gem itself.
- **`app/services/job_description/`** (issue #7): `JobDescription::Extractor.call(text:, chat:
  RubyLLM.chat)` pulls ATS-relevant requirements out of a pasted job description — no file
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
  `BulletRewriter.call(bullets:, job_description_text:, chat: RubyLLM.chat)` rephrases an array
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
- As the remaining pipeline issues (#12-#18) land, expect: PDF rendering as a Solid Queue job
  (`app/jobs`), and Turbo-driven views per pipeline stage (`app/views`, `app/controllers`).

## Next steps for Claude

As the pipeline issues (#6 onward) add real structure (jobs, controllers, views), update the
Project layout section above to describe how the major pieces fit together, rather than
speculating ahead of the code that exists.
