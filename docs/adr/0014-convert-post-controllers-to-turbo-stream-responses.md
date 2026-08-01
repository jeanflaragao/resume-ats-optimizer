# ADR-0014: Convert `JobDescriptions`/`Previews`/`Downloads` to `turbo_stream` responses

## Status
Accepted

## Context
ADR-0010 accepted `data: { turbo: false }` on three forms (`resumes/show.html.erb`'s
job-description and preview forms, `previews/show.html.erb`'s download form) as an interim fix
for Turbo Drive rejecting a plain `200 OK` render in response to a POST. That ADR explicitly
recorded the stopgap as a real, acknowledged UX regression relative to ADR-0001's own
Turbo-Streams architecture, tracked issue #47 as the proper fix, and predicted its own Status
would be superseded once #47 landed. Issue #57 (ADR-0013) closed a related gap first — system
tests now run with real CSRF forgery protection enabled — specifically so this conversion could
happen with real token coverage already in place instead of after.

## Decision
`JobDescriptionsController#create`, `PreviewsController#create`, and `DownloadsController#
create` each now `respond_to` with both `format.html` and `format.turbo_stream`, rather than
`turbo_stream`-only:

- `format.html` is declared first and renders exactly what each action already rendered before
  this ADR — required because the app's own integration tests post with no Turbo `Accept` header
  and assert directly on full-HTML `response.body`, and because it remains the real fallback for
  JS-disabled clients. Empirically confirmed (`bin/rails runner`, not assumed) that a plain
  integration-test POST's default `Accept` header never contains `text/vnd.turbo-stream.html`, so
  format resolution is unambiguous either way — `format.html` first is defensive insurance, not a
  fix for an observed ambiguity.
- `format.turbo_stream` renders the **exact same template** `format.html` renders for that
  branch — no divergent partials between the two formats, which is what let the ADR-0010/ADR-0013
  bugs happen in the first place (a code path only one of the two ever exercised). Two
  `turbo_stream.update` actions run per response, against two ids the layout now always provides:
  `div#main_content` (wraps `<%= yield %>` in `app/views/layouts/application.html.erb`) and
  `div#flash` (the flash loop, extracted to `app/views/layouts/_flash.html.erb`). `div#flash`
  needed Tailwind's `empty:hidden`, since `<main>` is `flex flex-col gap-4` and an
  always-present-but-empty flash container would otherwise add real gap spacing on every
  flashless page — checked empirically via `bin/rails runner` (confirmed zero child nodes when
  flash is blank), not assumed correct on sight.

**Tradeoff, not a neutral default**: swapping the entire `main_content` region (via
`turbo_stream.update`, an innerHTML swap) rather than smaller, targeted per-section streams was a
deliberate choice. It buys single-template parity between `format.html` and `format.turbo_stream`
— the same format-divergence root cause behind the original bugs doesn't get a second entry point
here. It costs focus: an innerHTML swap destroys whatever element currently has focus (e.g. the
job-description textarea mid-edit), which falls back to `<body>` — a real accessibility
regression relative to the full navigation this replaces, which at least reset focus to a
predictable state. Smaller, targeted streams (e.g. updating just a match-results div, leaving the
form untouched) remain possible as a later, narrower change; not pursued here because it would
mean each controller's `format.turbo_stream` branch touching a different, bespoke set of partials
instead of reusing one shared template per branch.

## Alternatives considered
- **Targeted per-region `turbo_stream` actions instead of a full `main_content` swap**: rejected
  for this first conversion for the reason above (more moving parts, format divergence risk
  returns) — noted as a legitimate future narrowing, not ruled out permanently.
- **A redirect-based PRG flow** (satisfies Turbo Drive without `turbo_stream`): already rejected
  in ADR-0010 as requiring session/flash smuggling of comparison/preview state that `render`
  currently has directly available; nothing about this conversion changed that calculus.

## Consequences
- All three forms drop `data: { turbo: false }`; Turbo Drive now intercepts them normally and
  gets a real `turbo_stream` response, matching ADR-0001's intended architecture. The two-form +
  `sync_controller.js` split (originally added for the `formaction`/per-form-CSRF-token bug) is
  **not removed** — it's still required for the `format.html` fallback's real, non-Turbo POSTs,
  which this ADR does not remove.
- **The browser address bar no longer changes across any of the three flows.** A `turbo_stream`
  response never pushes a history entry, unlike the full-page POST-response navigation the
  stopgap performed. This is a net UX improvement (refreshing is now an idempotent `GET`, with no
  more native "confirm form resubmission" dialog) but it surfaced two follow-ups, filed rather
  than fixed as part of #47:
  - [#65](https://github.com/jeanflaragao/resume-ats-optimizer/issues/65) —
    `DownloadsController#create`'s blank-input branch (already confirmed unreachable through the
    real UI) renders more confusingly after this change: a same-URL `turbo_stream` swap instead
    of a full-page render at a URL that at least hinted at the downloads endpoint.
  - [#66](https://github.com/jeanflaragao/resume-ats-optimizer/issues/66) — refreshing mid-
    "Preparing your download..." now silently strands an already-generated PDF, since nothing
    survives the refresh to reconstruct the in-flight `download_id` from (previously, refreshing
    at least re-enqueued a new, reachable job, even though a duplicate one).
- This supersedes the stopgap ADR-0010 accepted; its Status now points here.
