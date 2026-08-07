# ADR-0035: Credit balance and 30-day unlimited window

## Status
Accepted. Partially supersedes [ADR-0021](0021-cache-the-optimization-result-between-preview-and-download.md)
(the `CACHE_TTL`/`CACHE_EXPIRY` value only — its cache-key structure and double-submit lock design
are unchanged and remain that ADR's).

## Context

Every optimization run (`Resume::CachedOptimization`, wrapping `Resume::Optimization`) and every
upload (`Resume::Import`, via `Resume::Extractors::Llm`) is a real, cost-bearing Anthropic request.
`Usage::Quota` (ADR-0023, ADR-0033) already caps abuse per subject, per action, per day, but nothing
caps or monetizes total usage — a signed-in user with mandatory Google OAuth (ADR-0032) can generate
resumes indefinitely for free. Issue #122 introduces that layer: a non-expiring credit balance plus
a separate 30-day unlimited window, both attached to `User`. This is the third of four issues; #123
(payment) builds a purchase flow on top of the schema this ADR creates. Building that flow is
explicitly out of scope here.

This ADR was written from a decision already substantially made on the issue — the gate check order
(unlimited window, then balance), the two-free-credits-on-signup default, and `Usage::Quota` staying
a separate, unmerged mechanism were all specified there, not derived here. Two things surfaced during
implementation planning that the issue's own text did not anticipate and are recorded below with
their resolution, not silently folded in: precisely when a credit is debited, and whether uploading
itself should be gated.

## Decision

### The model

`users.credits` (integer, `NOT NULL DEFAULT 2`) and `users.unlimited_until` (datetime, nullable).
The DB default grants two free credits on signup with no application code — the same pattern
`resumes.user_id` already uses (ADR-0034): a row can never transiently exist without the invariant
holding.

**Gate** (`Credit.available?(user)`), permission to start, never itself a charge:
`Time.current < user.unlimited_until || user.credits.positive?`. Runs at three points —
`ResumesController#create`, `PreviewsController#create`, `DownloadsController#create` — each after
their existing cheap validations and before `enforce_quota!`, the same relative position
`Resume::Pdf.guard_renderable!` already has (ADR-0025), now extended to a second gate. At
Preview/Download specifically, the gate is `Credit.available?(user) ||
Resume::CachedOptimization.cached?(resume:, job_description_text:)` — a 0-credit user may still
re-preview or download something already cached, because that specific request is a free hit, not a
new spend. Refusing it anyway would contradict the issue's own "full read access to... previously
generated PDFs" principle, extended sensibly to a not-yet-downloaded cached preview.

**Debit** (`Credit.consume!(user)`), the actual atomic decrement: lives in exactly one place —
inside `Resume::CachedOptimization#call`, in the branch where *this process* won the cache-miss lock
and successfully computed and cached a fresh `Result`. Both Preview (synchronous,
`context: :preview`) and Download (`Resume::OptimizedPdfJob` calling the same class,
`context: :download`) get it for free, with no per-flow duplication. A caller that loses the lock
race and waits for the winner's write (`await_winner`) is a hit, never a miss — never charged. A
caller that falls through after the winner never delivered (ADR-0021's documented lock-abandonment
path) still runs the pipeline itself and is still exactly one genuine miss, charged once.

This resolves the debit-timing question explicitly: **a bare Preview can spend a credit.** Issue
#122's own text already specified this — "the first `Resume::CachedOptimization` run for a given
(resume, job description) pair" — but an earlier draft of this work read "generation" as meaning PDF
generation specifically, i.e. Download-only. That reading is wrong and was corrected before any code
shipped: Preview runs the full optimization pipeline (the real LLM cost), and Download of an
already-cached pair only serves bytes. Charging Download-only would let a user run preview after
preview against different job descriptions — full optimizations each time — and never pay.

Implementation of `Credit.consume!`: an **unconditional** atomic `UPDATE users SET credits =
credits - 1 WHERE id = ?` (`User.where(id:).update_all`), not `User#decrement!` (read-modify-write in
Ruby — the same lost-update failure mode `Usage::Counter.consume!`'s `upsert_all` exists to avoid,
proven non-vacuous the same way: `test/services/credit_concurrency_test.rb` first ran against a
naive `user.update!(credits: user.credits - 1)` and lost updates under concurrent decrement — see
Consequences). No `WHERE credits > 0` guard: by the time this code runs, the LLM work already
happened — that's what makes it a miss — so there is nothing left to reserve or release. Withholding
an already-computed, already-paid-for-in-real-money result over a balance race would be strictly
worse than the alternative. A balance can therefore dip to -1 in a genuine concurrent-different-pair
race (two distinct job descriptions, both pass the gate on a 1-credit balance, both become genuine
misses) — the same direction as ADR-0019's "overcounts rather than undercounts," now applied to
money: prefer occasionally generous over occasionally refusing paid-for work. This is accepted as a
rare, self-correcting edge case, not a bug to chase.

This also answers the "before planning" question of reserve-then-confirm vs. an alternative, and
what happens to a reservation whose job never completes: **there is no reservation.** A job that
crashes, retries indefinitely, or is never picked up simply never reaches `optimize_and_store`'s
success path and never charges — no stuck reservation to release, because nothing was ever reserved.

### Cache expiry is a real charging boundary

The credit charge is keyed to the same cache entry as the LLM cost it represents. There is no
separate, durable "have we ever charged this (resume, job description) pair" ledger. Once the cache
window elapses, a repeat Preview/Download of the same pair is a genuine new miss, incurs genuine new
LLM cost, and **is charged again.** This is deliberate, not an oversight — it's the same shape
ADR-0021 already accepts for pure LLM cost (a stale cache means real re-computation), now with a
credit attached.

### Retention: correcting a misattribution, and extending the window

The 15-minute figure that both `Resume::CachedOptimization::CACHE_TTL` and
`Resume::OptimizedPdfJob::CACHE_EXPIRY` shared was originally attributed, in an early draft of this
work, to ADR-0012. That is wrong: **ADR-0012 is Solid Cache wiring** (the production cache store,
`config/cache.yml`) and says nothing about any TTL value. The actual decision lives in ADR-0021,
whose own text explicitly ties the two constants together ("two different windows for one user
journey would be two numbers to keep in sync"). This ADR corrects that record here rather than
editing ADR-0021's body, per this repository's convention of not rewriting history — only its
`## Status` line is amended to note the partial supersession.

Both constants move from `15.minutes` to `1.week`. With accounts and a permanent resume history
(`resumes#index`, ADR-0034), "read it later" is a real usage pattern a single sitting no longer
covers. Checked against everything ADR-0021's own reasoning depended on: `LOCK_WAIT_SAFETY_FACTOR`
and `LOCK_TTL_SAFETY_FACTOR` are derived from measured per-experience *pipeline* latency, independent
of the cache TTL — unaffected. One week stays comfortably under `Resume::LAST_ACCESSED_PURGE_AFTER`
(1 month, ADR-0034) — the cache is still never the longest-lived copy of anything.
`Resume::PdfRequest::PURGE_AFTER` (15 minutes) is a different, unrelated mechanism — the transient
encrypted job-description holding row during async processing, not the generated-PDF cache — and is
untouched; its own comment is corrected to point at ADR-0021 rather than ADR-0012 for the same
reason.

Flagged as a watch item, not a blocker: PDF byte blobs now sit in Solid Cache for up to a week
instead of 15 minutes, growing average resident cache size. `config/cache.yml`'s `max_size:
256.megabytes` (ADR-0012) already handles eviction; no config change is required.

### The three no-charge cases

All three sit before `enforce_quota!`/the credit gate, matching ADR-0025's ordering: a refusal
knowable this early must not cost anything downstream.

**1. Unreadable PDF.** Issue #37 measured a real `resume.pdf` with 0 extractable characters — a
scanned image with no text layer. `pdftotext` succeeds (it's a well-formed PDF); there is simply
nothing in it an LLM could ever have extracted. `Resume::Extractors::Llm#source_text` used to compute
this lazily, *after* the LLM call, purely to verify the LLM's own output (issue #126/#127). That
ordering is wrong for a pre-flight check, so the extraction moved to a shared `Resume::PdfText`
(used by both the new guard and the extractor's own verification) and a new
`Resume::PdfReadabilityGuard.call!(file_path:)` runs it in `ResumesController#create`, before the
credit gate and `enforce_quota!(:resume_extraction)`, refusing below `MIN_EXTRACTABLE_CHARACTERS =
200` (comfortably below any real CV, comfortably above 0) with a dedicated message rather than the
generic "couldn't read that file." `pdftotext` runs twice per PDF upload as a result (guard, then
verification) — accepted deliberately: a fast local subprocess, not an LLM call, and not worth
threading a precomputed value through `Resume::Import`'s signature for.

**2. Critical pending items.** Defined explicitly, each independently sufficient:
`resume.name.blank? || resume.experiences.empty?`. A missing name alone disqualifies (the PDF header
would be blank) even with real experience history; zero experiences alone disqualifies (nothing to
compare or rewrite against a job description) even with a name present. A missing summary, missing
skills, or any other single dropped field is acceptable degradation, not this — issue #118's existing
pending-items UI already surfaces those without blocking anything.

Not detectable before the LLM call — the extraction result is what determines it — so, unlike case 1,
this cannot be pre-flighted at upload. It doesn't need to be: upload never debits a credit in this
design (only the later cache-miss does), so a critical-but-persisted resume hasn't cost anything by
the time this matters. What does need a guard is downstream: nothing would otherwise stop a critical
resume from reaching a genuinely chargeable `Resume::CachedOptimization` miss — an empty
`BulletRewriter` fan-out over zero experiences would still cache a (useless) result and still charge
for it. `Resume::CachedOptimization.guard_usable!(resume:)`, raising `UnusableResumeError`, runs in
both `PreviewsController#create` and `DownloadsController#create` before their credit gate and
`enforce_quota!` — the same position `guard_renderable!` already occupies in Downloads. A live
predicate, not a persisted flag: filling in a missing name via the existing pending-items flow
(`PendingItemsController`, issue #118) un-blocks Preview/Download automatically on the next request.

**3. Unrenderable PDF** (shaping-required scripts, ADR-0024). Already guarded —
`Resume::Pdf.guard_renderable!` already runs in `DownloadsController#create` before
`enforce_quota!`. No new controller-level code was needed; the new credit gate sits after it, the
same relative position `enforce_quota!` already has. One deliberate asymmetry, mirroring the existing
`pdf_generation`-quota precedent (ADR-0025): the job's own *backstop* `guard_renderable!` call (a
bullet rewrite introduces a new unrenderable character, caught only after
`Resume::CachedOptimization` already ran and already charged) does **not** refund the credit — the
LLM work is sunk by the time that backstop fires, exactly the reasoning ADR-0025 already gives for
why the quota slot isn't refunded there either.

### Upload gating

Issue #122's own Scope section lists only `PreviewsController#create`/`DownloadsController#create`
as gate-check sites, and its acceptance criteria say a 0-credit user is "blocked only from generating
new ones" — implying upload stays open. This ADR departs from that, deliberately: **uploading a new
resume also requires `Credit.available?`**, a binary "can you start" check with no separate tally —
the actual decrement still happens later, at the cache-miss point above, not at upload.

Reasoning: extraction is a real, measured Anthropic request (see Measured cost below) with no revenue
path for a 0-credit user — without a gate, uploading is free to repeat indefinitely, each repeat
costing money with no possible return. The three no-charge cases above still apply unchanged: the
gate is permission to start, not a charge, so an unreadable PDF or a critical-pending-items result
still costs nothing regardless of how the gate resolved. Flagged on issue #122 directly (comment plus
an edit to its acceptance criteria) rather than left as an undocumented divergence between the issue
and the shipped behavior.

### `Usage::Quota` relationship

Issue #122 already resolves this explicitly: `Usage::Quota` stays, unmerged, as the per-day abuse
guard; credits are the separate monetary layer on top — "the same relationship `LlmCallGuard`'s
global cap already has to `Usage::Quota`" (ADR-0023). Endorsed here: they answer different questions
with different remedies ("come back tomorrow" vs. "buy more credits"), and a day can plausibly have
one exhausted while the other isn't — collapsing them would produce wrong messaging on that day, not
just redundant code.

### UI: cost visible before the click

A 0-credit user must know before a click costs them, not after. The account bar shows the balance
(`credit_balance_label`) or the active unlimited-window date on every authenticated page. The
Preview and Download buttons are dynamically labeled — "uses 1 credit" / "free, already generated" /
a disabled "out of credits" — computed server-side via `Resume::CachedOptimization.cached?` (a cheap
`Rails.cache.exist?`, no lock, no computation) combined with `Credit.available?`. This is only
computable once `job_description_text` is known server-side (after "Check match" has run, or on a
re-render following a failed Preview/Download submission) — the button shows its plain, unlabeled
text before that, since there is nothing to price against blank text.

### Purge safety

`credits`/`unlimited_until` live on `users`, not `resumes`. `Resume.purge_stale!`'s query already
only ever selects from `resumes` (ADR-0034's existing structural guarantee), and there is no cascade
from a `resumes` row delete to its owning `users` row — the foreign key points the other direction.
The acceptance criterion ("purge cannot touch a credit-holding account's balance") is therefore true
by construction once these columns exist, the same way `usage_counters` already was. No new purge
logic was needed — `test/models/resume_test.rb`'s existing test (already flagged by ADR-0034 for this
exact revisit: *"this test should be revisited once #122 lands to assert against the real thing
too"*) was extended to also assert `user.reload.credits`/`user.reload.unlimited_until` survive a
purge, rather than adding a new one.

### Measured cost, for the record

A heavy CV (7 experiences, 49 bullets) costs **R$0.29** to extract and **R$0.29** to compare —
**R$0.58** for a full cycle against **R$2.98** per credit (5-credit pack pricing, #123). Worst
realistic case with a cache miss on both preview and download (the `2 + 2E` shape ADR-0021 already
measured) is **R$0.88**. Recorded here, not just the pricing conclusion, so a future reader deciding
whether the margin still holds has the underlying numbers, not just today's answer.

## Alternatives considered

- **Reserve a credit at Preview/Download request time, confirm on success**: rejected. The debit only
  ever needs to represent work that genuinely happened, and by the time `optimize_and_store` runs,
  that work is already sunk. A reservation would need a release path for jobs that never complete —
  timeout, crash, indefinite retry — and that path has no correct answer that isn't "eventually
  become the same unconditional charge-on-success this ADR already does." Reserve-then-confirm adds a
  state machine to solve a problem the chosen design doesn't have.
- **A durable per-(resume, job description) "already charged" ledger, decoupled from the cache**:
  rejected. It would prevent re-charging after the cache expires, but at the cost of a new permanent
  table to reason about for ADR-0034's purge-safety guarantee, and it contradicts the premise that a
  credit represents real, recurring LLM cost — a pair that falls out of cache and is genuinely
  re-optimized has genuinely cost money again.
- **Merge `Usage::Quota` and credits into one mechanism**: rejected, per the `Usage::Quota
  relationship` section above and ADR-0023's original reasoning — issue #45 remains the place that
  case is argued, not resolved here.

## Consequences

- `Resume::CachedOptimization::CACHE_TTL` and `Resume::OptimizedPdfJob::CACHE_EXPIRY` are now
  `1.week`, were `15.minutes`. `Resume::PdfRequest::PURGE_AFTER` (15 minutes) is unchanged and its
  comment now correctly cites ADR-0021 instead of ADR-0012.
- `LlmCallGuard::StubChat`'s canned `Resume::ExtractionSchema` response now includes one placeholder
  experience (`"Example Corp"` / `"Stub Engineer"`), not an empty array. An all-empty stub silently
  made every stub-mode upload permanently unusable once `guard_usable!` existed — this affected local
  development/demo mode as much as it affected roughly a dozen existing tests, which is why the fix
  is in the shared stub rather than patched into each test individually. Test fixtures that need a
  *usable* stub resume now include the matching phrase verbatim (`Resume::Extractors::Llm`'s own
  fidelity check requires it), alongside the pre-existing `"Stub Candidate, stub@example.com"`
  convention.
- `Credit.consume!`'s atomicity claim is non-vacuous: `test/services/credit_concurrency_test.rb`
  first ran against `user.update!(credits: user.credits - 1)` and lost updates under four concurrent
  writers × 25 decrements each (final balance higher than the expected zero) before the atomic
  `update_all` version was written. Reproducing this required each concurrent call to reload its own
  `User` instance rather than share one Ruby object — a shared in-memory object masks the exact race
  under test, since `assign_attributes` mutates it synchronously before the network round-trip that
  the race depends on.
- The purge-safety non-vacuity proof (`Resume.purge_stale!` still cannot touch a credit balance) was
  run by temporarily splicing a credit-wiping line into a local copy of `purge_stale!`, confirming
  `ResumeTest` goes red, then reverting — recorded in the PR body, since the guarantee is structural
  and there is no "unfixed" shipped version of this specific code to run the test against.
- No `Credit::` purchase logic, no payment integration, no admin credit-grant tooling beyond the
  signup default — all explicitly #123's scope, not built here.
