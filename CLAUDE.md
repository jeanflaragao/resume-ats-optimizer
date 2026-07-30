# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

The Rails app is scaffolded (issue #3) per the Stack decided in issue #1, but no product code
exists yet — no CV schema, parsing, prompts, or PDF template (issues #4 onward). The project is
named `resume-ats-optimizer`, a hosted, multi-user tool for optimizing resumes against Applicant
Tracking Systems (ATS): upload a LinkedIn data export, paste a job description, and get back an
ATS-friendly, tailored CV as a downloadable PDF.

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
- **PDF generation**: Prawn (pure Ruby, programmatic), not Grover/Puppeteer. The required CV
  template is deliberately simple — no tables, columns, or images, standard fonts — so
  Prawn's flow layout is sufficient and avoids bundling headless Chrome into the Kamal image.
- **LinkedIn export parsing**: `pdf-reader` for the PDF export path (text extraction only), Ruby's
  built-in `JSON` for the JSON export path.
- **Auth**: Rails 8's built-in authentication generator, not Devise.
- **Testing**: Minitest, the Rails default — no extra gem needed.

**Why Rails**: chosen directly by the user rather than picked from a generic framework
comparison — the priority was the "most modern" idiomatic Rails setup (Hotwire, Solid trio,
Kamal) for a solo-maintainer, low-ops-overhead deploy. Comparison logic and match scoring
(deterministic, not LLM output) are kept as plain Ruby service objects so they stay testable and
free of hallucination risk. Full reasoning and alternatives considered are recorded on
[issue #1](https://github.com/jeanflaragao/resume-ats-optimizer/issues/1).

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

Standard Rails 8 conventions — no app-specific structure exists yet beyond the generated
skeleton (`app/`, `config/`, `db/`, `test/`). As the pipeline issues (#4-#18) land, expect:
CV/job data as ActiveRecord models (`app/models`), LLM calls and PDF rendering as Solid Queue
jobs (`app/jobs`), comparison/scoring as plain Ruby service objects (`app/services`), and
Turbo-driven views per pipeline stage (`app/views`, `app/controllers`). Update this section as
that structure is actually created, rather than in advance of it.

## Next steps for Claude

As the pipeline issues (#4 onward) add real structure (models, jobs, services), update the
Project layout section above to describe how the major pieces fit together, rather than
speculating ahead of the code that exists.
