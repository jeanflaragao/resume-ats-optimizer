# ADR-0001: Use a Rails 8 Hotwire monolith instead of a separate API + SPA frontend

## Status
Accepted

## Context
resume-ats-optimizer is a hosted, multi-user tool: upload a LinkedIn data export, paste a job
description, get back an ATS-friendly PDF. Issue #1 asked for candidate backend/frontend
architectures, to be decided in Plan Mode before any code was written. The full roadmap
(issues #4-#18) already implied a linear, mostly-server-driven flow: upload → parse → analyze →
preview → download, with no requirement for offline support, a mobile app, or a public JSON API
consumed by third parties. The project is maintained by a single person and will be deployed to
a single VPS via Kamal, which weighs against any architecture that adds moving parts without a
concrete need.

## Decision
Build a standard Rails 8 application (not `--api` mode): server-rendered ERB views, with Turbo
Frames/Streams driving the upload → analyze → preview → download flow and Stimulus for light
client-side interactivity (e.g. keeping a hidden field in sync with a visible textarea). No
hand-rolled JSON API layer and no separate JavaScript frontend framework. JS/CSS ship via
`importmap-rails` (no Node build step) and `tailwindcss-rails`, keeping the Docker image
Node-free.

## Alternatives considered
- **Separate JSON API (Rails `--api` mode) + SPA frontend (React/Vue)**: would have required
  building and maintaining a client-side routing/state layer for a flow that is fundamentally a
  sequence of server-driven steps, plus a second toolchain (Node, bundler, separate deploy
  artifact) purely to reproduce what Turbo/Stimulus already provide. Rejected as unjustified
  complexity for a solo-maintainer project with no API-consumer requirement.
- **Rails API mode + Hotwire-on-top hybrid**: considered and rejected implicitly — Hotwire's own
  value proposition is server-rendered HTML with progressive enhancement; running it against a
  pure JSON API would mean serializing to JSON and back to HTML for no benefit.

## Consequences
- Every new page/flow is added as a standard Rails controller + view, not an API endpoint plus
  client state management — lower per-feature cost, consistent with the rest of this project's
  choices favoring operational simplicity over flexibility not currently needed.
- Turbo Drive's Post/Redirect/Get expectations become a real constraint on controller responses.
  This was not fully internalized until issue #47 found that `JobDescriptionsController`,
  `PreviewsController`, and `DownloadsController` all violated it by `render`-ing HTML directly
  after a POST — see ADR-0010 for that specific, still-open follow-up.
- If the product ever needs a true third-party API or a native mobile client, this decision
  would need revisiting; nothing here precludes adding a JSON API later, but none exists today.
