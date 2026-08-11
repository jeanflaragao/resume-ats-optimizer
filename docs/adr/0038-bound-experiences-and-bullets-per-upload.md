# ADR-0038: Bound experiences and bullets per upload, with disclosure instead of rejection

## Status
Accepted

## Context

Issue #130: `Resume::ExtractionSchema` places no upper bound on `experiences` or on `bullets`
within an experience, and no model validation on `Experience` does either (only `company`/`title`
presence). `MAX_UPLOAD_BYTES` (ADR-0017, 10 MB) is ~100x a real resume, so a padded upload with
dozens of fabricated experiences fits easily under that bound while still producing an unbounded
fan-out downstream: `Resume::Optimization.rewrite_request_count` — already the exact number
`LlmCallGuard.ensure_headroom!` pre-flights against (issue #75) — is one `BulletRewriter` request
per experience with bullets. `Credit.consume!` charges exactly one credit per
`Resume::CachedOptimization` cache miss regardless of that fan-out width, so a single upload, one
click, one credit, can consume a large, unbounded share of `LlmCallGuard`'s shared daily cap in one
request. This is worse than #106 (the cap's missing caller dimension, a separate, sequenced
follow-up — see that issue): #106 needs many distinct sessions or accounts; this needs one file.

The existing `ensure_headroom!` pre-flight already refuses a flow that cannot fit inside *today's
remaining* global budget — but that is a shared-resource check, not a per-upload ceiling. Nothing
bounds what a single upload can ask for in the first place.

## Decision

**Bound `experiences` and `bullets`-per-experience at persist time, in `Resume::Import`, keeping
the excess as a disclosed truncation rather than rejecting the upload.**

- `Resume::Import::MAX_EXPERIENCES` (20) and `Resume::Import::MAX_BULLETS_PER_EXPERIENCE` (20).
  Applied in `#persist`, keeping the first N in document order (earliest-listed, typically most
  recent/relevant) and recording a pending item for the rest — reusing ADR-0031's existing
  `pending_items` mechanism (`"kind" => "truncated_experiences"` / `"truncated_bullets"`,
  `"field" => "experiences"` / `"bullets"`), rendered as inform-only on `resumes/show.html.erb`
  exactly like ADR-0031's existing whole-entry-drop case — no new persistence mechanism, no new
  view section.
- **Not measured — stated as a judgment call, explicitly.** The only real corpus available is
  ADR-0031's single sample (3 experiences); there is no larger set of real uploads to derive a
  distribution from. Sized the same way ADR-0017 sized its own unmeasured bounds: firm but
  generous relative to a realistic LinkedIn export (a senior candidate with 15+ distinct roles is
  already an extreme outlier; 20 is comfortably above that while still refusing a 200-entry
  padding attempt). Revisit against real upload data once there is enough volume to look at.
- **Truncation with disclosure, not outright rejection** (unlike ADR-0017's shape for upload
  size/job description length). An oversized file or an overlong paste has no legitimate content
  worth keeping past the bound — the whole request is refused with a flash, before any service
  runs. A padded experience list is different: everything under the bound is still genuine,
  processable content: the product remains usable for the first N entries rather than refusing the
  whole upload over the (N+1)th. `Resume::Import` is also the first point either count is actually
  known — unlike ADR-0017's inputs, neither can be checked by a controller before the LLM/regex
  extraction that produces them has already run.
- **Placed on `Resume::Import`, not `Resume::ExtractionSchema` or `ResumesController`.** The
  schema only shapes what the LLM is asked to return; it doesn't gate what
  `Resume::Extractors::PdfRegex`/`JsonMapper` (the deterministic strategies, unverified against an
  LLM at all) can produce. `Resume::Import#persist` is the one place both strategies' output
  converges before hitting the database, so it's the only layer that bounds both.

## Alternatives considered

- **Reject the upload outright once either count is exceeded** (ADR-0017's shape) — rejected.
  Throws away genuine, usable content (the first 20 experiences) over the presence of a 21st,
  for no safety benefit truncation-with-disclosure doesn't already provide.
- **Bound at `ResumesController#create`, before calling `Resume::Import`** — rejected. The
  controller has no experience/bullet counts to check before extraction has already run; the
  earliest correct point is inside `Resume::Import` itself, after `data` exists.
- **Cap `Resume::Optimization.rewrite_request_count` at preview/download time instead of at
  import** — rejected. Would let more than `MAX_EXPERIENCES` persist, then behave inconsistently
  between preview and download (or need its own cache-key/consistency story on top of
  `Resume::CachedOptimization`'s existing one), for the same outcome bounding at import already
  gives every downstream reader for free — including PDF rendering and storage, not just the LLM
  fan-out.

## Consequences

- `Resume::Optimization.rewrite_request_count(resume)` now has a hard ceiling
  (`Resume::Import::MAX_EXPERIENCES`) for any resume created through `Resume::Import`, which
  bounds the worst case a single upload can present to `LlmCallGuard.ensure_headroom!` — relevant
  to sizing #106's per-subject share once that follow-up lands, since a "fair share" of an
  unbounded number wasn't a bound at all.
  `Resume::Import::MAX_BULLETS_PER_EXPERIENCE` bounds prompt size per `BulletRewriter` call the
  same way, independent of call count.
- A resume with more than 20 experiences, or an experience with more than 20 bullets, now silently
  drops the excess rather than failing the upload — visible to the owner via the existing pending
  items list, not silent to them, but a legitimate (if unusual) candidate with genuinely more than
  20 distinct roles would need to manually consolidate before uploading to have all of them
  processed. Accepted: no real sample seen so far comes close to this bound.
- 20/20 are unmeasured defaults, same caveat ADR-0017 carries for its own two constants — revisit
  either if real usage data suggests they're wrong in either direction.
