# ADR-0029: Redirect `DownloadsController#create` to an addressable `/downloads/:id`

## Status
Accepted

## Context

ADR-0014 converted `DownloadsController#create` (alongside `JobDescriptions`/`Previews`) to a
`turbo_stream` response, trading the previous full-page POST-response render for an in-place DOM
swap. Its Consequences section named the cost explicitly: "the browser address bar no longer
changes across any of the three flows," and filed [#66] rather than fixing it, since #47's scope
was the `turbo_stream` conversion itself.

For downloads specifically, that cost turned out to be a real, user-facing regression rather than
a cosmetic one: `Resume::OptimizedPdfJob` runs off the request thread and can take up to a minute.
A refresh during "Preparing your download..." is now a plain `GET /resumes/:id` — idempotent, with
no more native "confirm form resubmission" dialog (a genuine win ADR-0014 already banked) — but it
silently discards the only place `download_id` ever lived: the DOM of the page that was just
replaced. The job still finishes and caches a real, cost-bearing PDF; the user has no route back
to it until it's purged.

`Resume::PdfRequest` (ADR-0022) turns out to already be exactly the record needed to answer "is a
download for this id still in flight" — it's created before `perform_later` and only destroyed on
success, so it durably covers precisely the window (enqueued-but-not-finished) that `Rails.cache`
can't answer at all. Its destroy-on-success timing wasn't built for this and didn't need to
change.

Auditing `DownloadsController#show`'s ownership handling (to confirm it was a safe foundation to
build on, before building on it) surfaced a second, independent gap: its failure-reason branch
called `find_owned_resume!` nowhere, so any session holding a `download_id` could already read
another session's PDF-generation failure reason — for `Resume::Pdf::UnrenderableCharacterError`,
that's a disclosure of *something* about the unreachable candidate's name (which Unicode block was
refused), not just a generic status leak. Folded into this ADR's fix rather than filed separately:
this decision is about to make `download_id` reachable by a real, copyable URL for the first time,
which only increases how much it circulates, and it's the same method already under revision here.

### Why a redirect-based flow, when ADR-0010/0014 already rejected one

ADR-0010's "Alternatives considered" and ADR-0014's "Alternatives considered" both reject a
redirect-based PRG flow for `JobDescriptions`/`Previews`, on the grounds that it would require
session/flash smuggling of comparison/preview state a `render` has directly available post-POST.
That reasoning doesn't transfer to downloads: the "Preparing your download" page needs nothing but
`download_id` itself, which is already the primary key of a real, persisted-or-cached record. There
is no state to reconstruct — only a lookup.

## Decision

`DownloadsController#create`'s success branch (job description present, in bounds, resume
renderable) redirects to `download_path(download_id)` immediately after enqueuing the job, instead
of rendering the "Preparing..." template in place. Turbo Drive follows the redirect from its
form-submission `fetch()` the same way it follows any Post/Redirect/Get response and updates the
address bar — so a refresh at any point afterward is a real, addressable `GET`. The three rejection
branches (blank / too long / unrenderable) are untouched: they enqueue nothing, so there is nothing
to make addressable.

`DownloadsController#show` becomes the single entry point for every state a `download_id` can be
in, with ownership checked **once**, before any branch decides what to render or send:

1. Read `Rails.cache`. If a `PdfRequest` row exists instead (nothing cached yet), that's the
   in-progress case — the only one `Rails.cache` alone can't distinguish from "never existed."
2. Resolve `resume_id` from whichever of the two was found, and call `find_owned_resume!` exactly
   once against it.
3. Branch on cached bytes (serve the PDF) / cached error (show the failure) / neither (render the
   in-progress "Preparing..." page) — all three only reachable after the single ownership check
   above passed.
4. If no `resume_id` could be resolved at all, or `find_owned_resume!` raised
   `ActiveRecord::RecordNotFound` (owner mismatch), render the exact same "That download link has
   expired" redirect either way.

That last point is deliberate and is the one place this departs from the app's own convention:
every other `find_owned_resume!` call site lets `RecordNotFound` fall through to Rails' default
404, specifically so owner-scoped resources are indistinguishable from nonexistent ones at the
*resource* level (`ApplicationController`'s own comment on the convention). `#show` needs the same
property at the *download_id* level instead — a `download_id` belonging to a different session
must produce the identical response (status, redirect target, flash copy) as one that was never
created, or the response itself becomes an oracle for "this id is real." Before this ADR that
oracle already existed in a narrower form (the failure-reason leak above); after this ADR
`download_id` sits in the address bar, where it can be copied, pasted into chat, or mailed, so the
value of closing it is materially higher than when it was merely an in-DOM value.

`app/views/downloads/create.html.erb` is renamed to `pending.html.erb` (no longer rendered by
`#create`, which only redirects now) and switched from an `@download_id` ivar to a `download_id:`
local, since `#show` renders it too. That render forces `formats: [:html]` explicitly: the redirect
Turbo Drive follows right after enqueue carries the original form submission's `Accept` header
(`text/vnd.turbo-stream.html, text/html, ...`), and there is no `pending.turbo_stream.erb` —
without forcing the format, that follow-up `GET` raises `ActionView::MissingTemplate`. A real
browser refresh doesn't carry that header at all (only Turbo Drive's own intercepted `fetch()`
does), so this only bites on the redirect-follow path, which only a real-browser system test
actually exercises.

## Alternatives considered

- **Leave `#create` rendering in place; make the browser retain `download_id` some other way**
  (e.g. `sessionStorage`, a cookie): rejected — client-only state doesn't survive a different
  device/tab picking up the same session, and it's strictly worse than a URL for the explicit goal
  ("reach the PDF while it exists"), which a URL satisfies for free once it's the address bar.
- **Poll `#ready` from `resumes/show` on load, keyed by the resume, to rediscover an in-flight
  download**: rejected — `download_id` isn't derivable from `resume_id` alone by design (a resume
  can have multiple `PdfRequest`s over time, e.g. a duplicate-submission race), so this would need
  its own new lookup (latest `PdfRequest`/cache entry for a resume) duplicating what the URL
  already gives for free.

## Consequences

- `/downloads/:id` becomes a real, bookmarkable/shareable URL for the lifetime of the underlying
  `PdfRequest`/cache entry — up to `Resume::PdfRequest::PURGE_AFTER` (15 min, unstarted) plus
  `Resume::OptimizedPdfJob::CACHE_EXPIRY` (15 min, finished) in the worst case. No retention window
  changed; this only makes the existing windows reachable.
- Partially reverses ADR-0014's stated consequence ("the address bar no longer changes across any
  of the three flows") for `Downloads` only. `JobDescriptions`/`Previews` are unaffected and keep
  the in-place `turbo_stream` behavior ADR-0014 established.
- `DownloadsController#ready`'s owner-mismatch response (404) remains distinguishable from its
  no-content response (204) for a nonexistent id — the same class of oracle just closed in
  `#show`. Not fixed here: `#ready` is a `fetch()`-only endpoint hit once by the pending page's own
  Stimulus controller, not a page a session navigates to directly — but that premise is exactly
  what this ADR undermines, since `download_id` now circulates via a real URL. Tracked as a
  separate follow-up issue rather than folded in here, since a fix for `#ready` is a decision on
  its own terms, not a mechanical extension of this one.

[#66]: https://github.com/jeanflaragao/resume-ats-optimizer/issues/66
