# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

No source code has been written yet. The project is named `resume-ats-optimizer`, a hosted,
multi-user tool for optimizing resumes against Applicant Tracking Systems (ATS): upload a
LinkedIn data export, paste a job description, and get back an ATS-friendly, tailored CV as a
downloadable PDF. The architecture has been decided (see Stack below, from issue #1); the app
itself has not yet been scaffolded (issue #3).

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

## Next steps for Claude

When the app is scaffolded (issue #3) and code is added, update this file with:
- Build, lint, and test commands (and how to run a single test)
- Project layout (where models, jobs, services, and views for each pipeline stage live)
- High-level architecture describing how the major pieces fit together
