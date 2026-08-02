# ADR-0021: Cache the optimization result between preview and download, keyed by a job-description digest

## Status
Accepted

## Context

`PreviewsController#create` and `Resume::OptimizedPdfJob#perform` each called `Resume::Optimization`
independently, with nothing shared between them (issue #83). That was a deliberate choice at the
time, recorded in both files' comments and in CLAUDE.md: re-running guaranteed the PDF matched the
job description text as submitted, and cost was #22's problem.

Two things made it worth revisiting.

**The cost became visible.** Before ADR-0019 the daily counter moved once per flow regardless of how
many requests were issued, so the doubling was invisible. With counting fixed at the provider
boundary, a preview-then-download journey on a 3-experience resume measures as six provider
requests where three would do:

```
Failure: test_a_preview_followed_by_a_download_issues_one_rewrite_request_per_experience_in_total
Expected: 3
  Actual: 6
```

**The doubling was also a correctness defect, not only a cost one.** The two runs are independent
LLM calls over the same input, and the LLM does not return the same rewrite twice. So the PDF a user
downloaded was never the resume they approved on screen — a fact no test could see until the fake
chat was made to vary its output:

```
--- expected (rendered in the preview)
+++ actual (rendered into the downloaded PDF)
-["the migration of billing services onto Kubernetes clusters Led", ...]
+["billing services onto Kubernetes clusters Led the migration of", ...]
```

## Decision

**Cache `Resume::Optimization::Result`, not rendered HTML or PDF bytes.** Preview and download must
render the same data through different renderers, so the cached value is the data. A new
`Resume::CachedOptimization` wraps `Resume::Optimization`, which stays a pure, cache-unaware fan-out.

**In `Rails.cache` (Solid Cache), not a table.** Issue #76 is removing unbounded retention of
job-description derivatives; a cache entry expires by construction, a row has to be remembered
about. The entry holds resume PII, which is the same class of data Solid Cache already holds as
rendered PDF bytes (ADR-0012) under the same window.

**`CACHE_TTL` is 15 minutes.** The window only has to span one sitting — preview, read it, click
download — and this project already fixed a number to that sitting in
`Resume::OptimizedPdfJob::CACHE_EXPIRY`. Two windows for one journey would be two numbers to keep in
sync. It sits far below issue #59's proposed 30-day window for the *source* records, so this cache
can never be the longest-lived copy of anything, whichever way #59 goes.

**The key carries a digest of the job description, never the text**
(`resume_optimization/v1/p<prompt fingerprint>/<resume state digest>/<jd digest>`):

- `KEY_VERSION` — the shape of the cached value, so a deploy cannot read yesterday's shape back.
- **Prompt fingerprint** — `BulletRewriter::PROMPT_VERSION` *and* a digest of `INSTRUCTIONS`. Each
  covers the other's blind spot: the hand-bumped version catches changes a text digest cannot see
  (`FIDELITY_MIN_TOKEN_COVERAGE`, prompt assembly order), and the digest catches a forgotten bump.
- **Resume state digest** — `cache_key_with_version` of the resume *and* of both child relations.
  The resume's own timestamp is not enough: neither `Experience` nor `Education` declares
  `belongs_to :resume, touch: true`, so an edited bullet never moves it. The relation cache keys
  fold in count and newest `updated_at`, which catches edits, additions and deletions.
- **Job description digest** — SHA-256 of the text with line endings normalised and outer whitespace
  stripped, and nothing else. No downcasing, no collapsing of internal whitespace: those would let a
  rewrite produced from one text be served for a different one.

Nothing user-authored is stored in the key — ids, timestamps and digests only (ADR-0015). A cached
entry is reachable only by a request that has already passed `find_owned_resume!` for that
`resume.id`, so keying on the resume rather than on the owner token cannot leak across users.

**A double-submit lock, because `Rails.cache.fetch` is not atomic across processes.**
`write(unless_exist: true)` is a real cross-process lock under Solid Cache: it goes through
`Entry.lock_and_write`, the same `SELECT … FOR UPDATE`-inside-a-transaction primitive ADR-0019
relies on for the call counter. A caller that loses the lock polls for the winner's result and gives
up for either of two reasons — the wait expired, or the lock vanished with no result (which is what
keeps a store that *cannot* lock from parking every caller for the full wait). Giving up means
running the pipeline, never failing the request.

**Lock timings are measured, and they scale with N.** Against **claude-sonnet-4-5** on a 795-word
posting:

```
N=3  total=13.85s  per-request=[4.93, 4.92, 3.77]
N=5  total=22.25s  per-request=[3.99, 3.54, 3.41, 8.17, 3.08]
```

The per-request latencies sum to within 0.23s of each total, so the fan-out is sequential and
duration is affine in N. `PIPELINE_PER_EXPERIENCE` is therefore the pooled mean of all eight samples
(4.48s → 4.5s) rather than the two-point slope `(T₅−T₃)/2`, which differences two noisy totals and
discards six of the eight samples. Because duration grows with N, so does the wait: a fixed timeout
calibrated at N=5 would send every loser on a larger resume into the fallthrough branch — the most
expensive outcome, in the most expensive case.

`LOCK_WAIT_SAFETY_FACTOR` is 2.0 and `LOCK_TTL_SAFETY_FACTOR` is 3.0, so the lock always outlives
the longest possible wait by one whole expected pipeline (22.75s at N=5). A waiter therefore always
gives up strictly *before* the lock can expire, rather than both timing out together while the
winner finishes an instant later.

**Misses are counted, per context.** `resume_optimization/<context>_<outcome>_on/<date>`, using
ADR-0019's idiom — a dated `Rails.cache` counter plus a PII-free log line, not a new instrumentation
stack. "Miss" means the pipeline ran. The context dimension is what makes the number mean anything:
a preview miss is the expected cold path, while a **download** miss is the #83 regression signal.
Unlike `LlmCallGuard.record_call!`, an unreadable counter is ignored rather than fatal — this is
bookkeeping, and a cache blip must not fail a download.

## Consequences

- **The preview is binding only within the window.** On a miss — an expired entry, an edited job
  description, or the lock's fallthrough path — the pipeline re-runs and the user downloads bullets
  that differ from the ones they read on screen. This is accepted deliberately: failing the download
  is worse than delivering a different valid rewrite, and the alternative (making the preview
  binding in general) means persisting the result, which is what #76 is moving away from. What this
  ADR buys is that divergence is eliminated *inside* the TTL, not that it cannot happen.
- **The safety factors rest on eight samples, one posting, one session, one model.** 1.82× is the
  worst of eight requests, not a characterised tail; there is no p99 here and these numbers should
  not be read as one. The signal to re-measure is empirical: a rising rate of `download_miss`
  counts, or observed fallthrough. Changing `config.default_model` invalidates the measurement
  outright — the constants carry the model identifier in their comment for exactly that reason, and
  `script/measure_optimization_latency.rb` reproduces them.
- **A cache hit bypasses the daily-cap pre-flight**, because it issues no provider request. A user
  who has exhausted `MAX_LLM_CALLS_PER_DAY` can still download a resume they already previewed.
- **A forgotten `PROMPT_VERSION` bump is bounded**, both by the `INSTRUCTIONS` digest, which catches
  the common case, and by the 15-minute TTL, which caps the damage of the uncommon one.
- **`Resume::Optimization::Result` no longer carries an ActiveRecord relation.** `educations` is
  copied into a value object, as `experiences` already was, because the Result is now serialised
  between processes and a relation would carry a database-connected object into a Solid Queue
  worker.
- **A reused download is indistinguishable from a fresh one to the user**, which is the point, but
  it also means the reuse can only be verified by the counters — a fallthrough that silently ran a
  second pipeline would still deliver a correct PDF. The counters are asserted in the test suite for
  that reason, not only the request totals.
- **Nothing about #76 is fixed here.** The download path still passes the raw job description text
  through Solid Queue's `arguments` column. This change stores a digest, never the text, so it does
  not widen that exposure, but the comments this PR rewrites deliberately stop repeating the "never
  persisted" claim rather than restating it.
