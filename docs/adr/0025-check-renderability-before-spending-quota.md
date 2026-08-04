# ADR-0025: Check PDF renderability before spending quota, and resolve fallback fonts lazily

## Status
Accepted — builds on [ADR-0024](0024-refuse-scripts-requiring-shaping.md) and
[ADR-0023](0023-per-session-usage-quotas-in-postgres.md)

## Context

`DownloadsController#create` calls `enforce_quota!(:pdf_generation)` (issue #92, ADR-0023) before
`Resume::OptimizedPdfJob` is even enqueued — before `Resume::CachedOptimization` or
`Resume::Pdf.call` (and so `Resume::Pdf.guard_renderable!`) ever run, since PDF rendering happens
asynchronously inside the job. Before this change, a resume ADR-0024 now refuses on sight — a
Hebrew, Arabic, Devanagari, or (pre-ADR-0024) CJK name — could only discover that after the job
ran, by which point the request had already consumed one `pdf_generation` quota slot
(`Usage::Quota`'s default: 15/day). For Hebrew, Arabic, and Devanagari that refusal is now
permanent, unscheduled-follow-up scope (issue #103), not a transient failure — so a user with one
of these names could burn their entire daily quota on a product that structurally cannot produce
their PDF, and only find out after each job ran.

`Usage::Quota.consume!`'s own comment states, deliberately: *"Nothing is refunded when the work
that follows fails... a refund path would need every caller to know which failures were free."*
This is uniform policy across every job failure today (the LLM daily cap, a budget-unavailable
cache read, a generic error) — not something specific to this guard, and not something this ADR
touches.

## Decision

**This is an ordering change, not a refund.** `Resume::Pdf.guard_renderable!`'s inputs — resume
name, email, phone, summary, skills, and each experience's/education's fields, including
*original* bullets — are real `Resume`/`Experience`/`Education` attributes that exist at
controller time and never touch the LLM. Only `BulletRewriter`'s *rewritten* bullets are unknown
until the job runs. So `DownloadsController#create` now calls
`Resume::Pdf.guard_renderable!(resume: @resume)` against the pre-rewrite record, between the
existing length check and `enforce_quota!`, in the same position and for the same reason the
length check already runs first: *"a refused download leaves no job-description copy on disk and
never occupies a worker."* A refusal that's knowable this early costs nothing — no `Usage::Counter`
increment, no `Resume::PdfRequest` row, no `perform_later`. This required making
`Resume::Pdf.guard_renderable!` a public class method (previously a private instance method run
only from inside `#call`) — see the refactor below.

**The job's own `guard_renderable!` call remains, as a backstop.** It is reached only for the one
case the controller's check cannot see: a bullet rewrite introducing a character the original text
didn't have. That path still spends quota on refusal, exactly as before this ADR, because it
genuinely cannot be known any earlier — there is no refund path, and none is added.

`Usage::Quota`'s "nothing is refunded" comment remains accurate and is left untouched: this ADR
never refunds anything, it just runs a free, deterministic check before a paid one.

## The refactor this requires, and the performance regression it surfaced

Both the controller and the job need the same check, and neither should need a full `Resume::Pdf`
instance (with its `Prawn::Document`) just to run it. `guard_renderable!`'s dependents
(`renderable_text`, `renderable?`, the font-cmap lookup, `unicode_block`) never touched instance
state beyond `resume` in the first place, so they moved to class-level methods taking `resume:`
directly.

This had a side effect worth measuring rather than assuming benign: the pre-existing `font_cmaps`
memoized `@font_cmaps ||=` **per `Resume::Pdf` instance** — a fresh one on every single render —
and opened **every** font in `FONT_FAMILIES` eagerly on the first character checked, whether or
not that character needed any of them. Benchmarked `TTFunk::File.open(path).cmap.unicode.first`
directly against the fonts this app now embeds:

| font | first parse | repeat parse |
|---|---|---|
| LiberationSans-Regular.ttf | 3.6ms | 0.9ms |
| DejaVuSans.ttf | 5.6ms | 3.2ms |
| NotoSansCJKsc-Regular.ttf (ADR-0024) | 102.3ms | 63.1ms |

Eagerly opening all three for the first character checked costs roughly the sum of the "first
parse" column — on the order of 110ms — for **every resume, including an all-ASCII one that only
ever needed Liberation Sans**. This was already true before ADR-0024 (Liberation + DejaVu alone),
but adding the ~19MB CJK font makes it an order of magnitude worse, and this ADR's own ordering
change means a successful download now runs the check twice (controller, then the job's backstop)
where it previously ran once.

**Fix: resolve fonts lazily, in `FONT_FAMILIES` declaration order, and cache each opened font's
cmap at the class level** (not per-instance): `renderable?` does `font_paths.any? { |path|
(cmap_for(path)[char.ord] || 0) != 0 }` — `Array#any?` short-circuits on the first font with the
glyph, and `cmap_for` memoizes per path in a class-level hash. An all-ASCII resume now opens only
`LiberationSans-Regular.ttf`, once per process, in either the controller's check or the job's —
never DejaVu, never the CJK font.

## Alternatives considered
- **Add a refund path** (e.g. `Usage::Counter.refund!` called from the job's rescue clause) —
  rejected. Contradicts `Usage::Quota`'s stated, uniform no-refund design for a single failure
  type, and needs its own concurrency-safety argument (the same overlapping-request race
  `Usage::Counter.consume!`'s single `upsert_all` exists to close) for comparatively little gain
  over simply not charging in the first place when the check can run earlier.
- **Leave the gap undocumented, defer to a follow-up issue** — rejected once it became clear the
  check's inputs don't actually depend on the async work; ordering was directly achievable in this
  PR, not a larger separate effort.
- **Defer the lazy-loading fix, ship eager loading and revisit only if it regresses in
  production** — rejected. The regression was cheap to measure directly (a few TTFunk benchmark
  calls) rather than guessed at, and the measured cost (~110ms of avoidable font parsing on every
  ASCII-only render, now potentially twice per successful download) was large enough relative to
  PDF generation's other costs to fix now rather than carry into production unmeasured.

## Consequences
- A Hebrew, Arabic, or Devanagari name (or, before ADR-0024, a CJK one) is refused for free at the
  controller, not charged to the session's daily `pdf_generation` quota.
- `Resume::Pdf.guard_renderable!` and `Resume::Pdf.font_paths`/`cmap_for` are now public/class-level
  surface area rather than private instance methods — a deliberate widening, not an oversight, so
  `DownloadsController` can call the exact same check `Resume::Pdf#call` runs internally.
- `font_cmaps`' cache lives for the lifetime of the process (a Puma worker), not a single render.
  A future change to `FONT_FAMILIES`' declaration order changes which fonts are consulted first —
  this is now a real priority ordering, not an arbitrary hash literal order.
- The job's backstop guard still spends quota on the rare rewrite-introduces-a-new-character case.
  This is accepted, not a gap: it genuinely cannot be known before the rewrite runs.
