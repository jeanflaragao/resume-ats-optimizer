# ADR-0039: Give LlmCallGuard's daily cap a per-subject share, backed by Usage::Counter

## Status
Accepted

## Context

Issue #106: `LlmCallGuard`'s global daily cap (ADR-0019/ADR-0020) counts real Anthropic provider
requests in a single `Rails.cache` bucket keyed only by `Date.current` — no caller dimension at
all. Once it trips, every subsequent real LLM call from *any* user raises `DailyLimitExceededError`
for the rest of the day: one abuser, or even a handful of legitimate users on a busy day, denies
the service to everyone else. `Usage::Quota`'s per-subject/per-action quota (ADR-0023) doesn't fix
this — it stops one subject from hogging *their own* quota, but was deliberately kept separate from
the global cap, and before mandatory auth "per-subject" meant per-session, trivially bypassed with
a private window.

Two things changed since ADR-0023, which is why this is buildable now:

- **Real, unspoofable identity exists.** Issue #120/#121 (ADR-0033) made `Current.user.id` a
  durable per-person subject, not a per-session token. ADR-0033 flagged this explicitly: *"This is
  what makes #106 solvable, not what solves it... whether and how to attach a per-user dimension to
  LlmCallGuard's cap is its own decision, with its own tradeoffs... out of scope for this issue."*
  This ADR is that decision.
- **The fan-out this cap protects against now has a hard ceiling.** Issue #130 (ADR-0038) bounded
  `Resume::Optimization.rewrite_request_count` at `Resume::Import::MAX_EXPERIENCES = 20` per
  resume. ADR-0038 flagged this as *"relevant to sizing #106's per-subject share... since a 'fair
  share' of an unbounded number wasn't a bound at all."* Worst case for one full
  upload→extract→preview→download flow is `2 + E` requests (`E` = experiences with bullets, ≤ 20),
  or `2 + 2E` (≤ 42) if a download misses `Resume::CachedOptimization`'s cache.

**`Usage::Quota`'s four action-type counters do not map 1:1 to provider requests.** `bullet_rewriting`
is one app-level action (one preview click) that fans out to up to 20 real `BulletRewriter` calls;
`pdf_generation` may cost 0 or up to `2 + 2E` calls depending on the cache. Summing
`Usage::Counter` rows across `Usage::Quota`'s existing action types would misrepresent a subject's
actual provider-request consumption. A correct per-subject dimension for `LlmCallGuard` needs its
own counter, incremented at the same boundary as the existing global one — the provider-call
boundary itself (ADR-0019), not an app-level action.

## Decision

**Add a per-subject share of the daily cap, checked alongside the existing global check at both of
`LlmCallGuard`'s existing two layers, backed by `Usage::Counter`'s existing atomic-upsert
mechanism under a new `action_type`.**

1. **Storage: reuse `Usage::Counter`, not `Rails.cache`.** `LlmCallGuard`'s existing global counter
   is cache-based — a deliberate stopgap (ADR-0019/0020). `Usage::Quota` chose Postgres over
   `Rails.cache` specifically because *"a quota that can silently reset under cache pressure is not
   a quota"* (ADR-0023) — the same argument applies here: a per-subject DoS guard that silently
   resets under Solid Cache eviction defeats the point of this fix. `Usage::Counter.consume!`
   already provides the primitive needed: a single-statement atomic
   `INSERT ... ON CONFLICT DO UPDATE ... RETURNING count`, proven under concurrent Puma threads and
   Solid Queue workers. `LlmCallGuard::SUBJECT_ACTION_TYPE = "llm_provider_call"` is a new
   `action_type` value, deliberately **not** added to `Usage::Quota::ACTION_TYPES` —
   `LlmCallGuard` calls `Usage::Counter` directly, bypassing `Usage::Quota` entirely, so the two
   mechanisms remain structurally separate while sharing only the storage primitive. No migration:
   `action_type` is a plain string column with no CHECK constraint, and `Usage::Counter.consume!`
   doesn't validate against `Usage::Quota::ACTION_TYPES` — that validation lives one layer up.

2. **Two-layer shape preserved.** `ensure_headroom!` (pre-flight) and `record_call!` (backstop)
   both gain a required `subject:` keyword and a second, per-subject check stacked after the
   existing global one, in the same order (global first) — so a call later refused by the
   per-subject check still incremented the global bucket first, the same "overcounting is the safe
   direction" tradeoff ADR-0019 already accepts for network retries.

3. **Fail-closed semantics extend the existing asymmetry, not a new rule.** The pre-flight already
   treats an unreadable global counter as `0` used (`Rails.cache.read(...).to_i`). The new
   per-subject pre-flight read (`Usage::Counter.count_for`) does the same: any
   `ActiveRecord::ActiveRecordError` is rescued, logged, and treated as `0` — advisory, not fatal.
   The backstop already fails closed for the global counter (`BudgetUnavailableError` on a `nil`
   increment). The new per-subject write does too: a failed `Usage::Counter.consume!` raises the
   same `BudgetUnavailableError`, reused rather than duplicated — the user-facing fact ("we can't
   tell what today's budget is, try again shortly") is identical regardless of which counter
   failed.

4. **New error class, new message.** `LlmCallGuard::SubjectLimitExceededError` — a sibling of
   `DailyLimitExceededError`, not a subclass, matching the existing precedent that
   `BudgetUnavailableError` isn't one either: different facts need different remedies. Flash
   wording: *"We've hit today's processing limit for your account. Please try again tomorrow."* —
   distinguishable from the global cap's *"We've hit today's processing limit"* (no account
   framing) and from `Usage::Quota::ExceededError`'s *"You've reached your daily limit for
   {action}"* (per-action, not per-shared-budget).

5. **Subject sourcing.** Derived from data already in scope at every call site but one:
   `resume.user_id`/`user.id` where a resume or user is already a parameter (`Resume::Import`,
   `Resume::Optimization`, `Resume::CachedOptimization`), never from `Current` — which would not
   survive into `Resume::OptimizedPdfJob`'s Solid Queue worker. `JobDescription::Extractor` gains a
   new `user: nil` parameter (placed before `chat:` in the signature, so the `chat:` default
   expression can see it), populated by `JobDescriptionsController#create` passing `Current.user`.
   `Resume::OptimizedPdfJob` needs no change — it already loads `resume` before calling
   `Resume::CachedOptimization.call`, so the subject flows through the same default-expression path
   as everywhere else.

6. **Sizing (`MAX_LLM_CALLS_PER_DAY_PER_SUBJECT`) is not decided here.** The 42-request
   worst-case-per-flow figure from ADR-0038 is a hard floor — anything smaller makes even one
   legitimate worst-case flow impossible. How large a multiple of that one account should get per
   day, and how it trades off against `MAX_LLM_CALLS_PER_DAY`, is a deploy-time policy decision
   with no production traffic data yet to derive it from — the same posture ADR-0038 and ADR-0017
   took for their own unmeasured constants. No production default exists; boot-time validation
   (`validate_cap_per_subject!`) requires an explicit positive integer, and
   `validate_cap_relationship!` refuses to boot if it exceeds `MAX_LLM_CALLS_PER_DAY` — a "share"
   larger than the whole isn't a bound at all. Local/test default: `10`, matching
   `MAX_LLM_CALLS_PER_DAY`'s own local default and reasoning posture, not a production
   recommendation.

## Alternatives considered

- **A new `Rails.cache`-based per-subject key inside `LlmCallGuard` itself**, matching its existing
  single-mechanism style. Rejected: same eviction-under-pressure argument ADR-0023 already gave for
  choosing Postgres over `Rails.cache` for a structurally identical problem — a DoS guard that can
  silently reset defeats its own purpose.
- **Fold `LlmCallGuard` and `Usage::Quota` into one mechanism** (issue #106's option 3, formerly
  issue #45, closed as consolidated into #106). Rejected — ADR-0023 already rejected this on the
  merits, not just sequencing: *"the global cap answers 'is the bill safe today' and this answers
  'is one visitor crowding out the rest', and a single mechanism would have to fail closed on both
  questions with one message."* That reasoning still holds; this ADR does not revisit it. Sharing
  the `Usage::Counter` storage primitive is not the same as merging the mechanisms — the two keep
  independent error classes, messages, and action-type namespaces.
- **Degrade instead of refuse once the cap is hit** (issue #106's option 2 — queue/delay past the
  cap). Rejected as out of scope for this ADR: needs a Solid Queue backpressure story and changes
  the guarantee `LlmCallGuard` currently makes (hard stop), a larger decision than this one.
- **Narrow fail-closed** (a per-subject counter failure blocks only that subject, not the whole
  request). Rejected: "we cannot verify this subject's usage" is not a materially different fact
  from "we cannot verify the global counter," and the existing guard already treats an unreadable
  count as refuse-by-default rather than proceed-uncounted.
- **Reuse `DailyLimitExceededError` for the per-subject case** instead of a new class. Rejected,
  same reasoning ADR-0019 gave for keeping `BudgetUnavailableError` distinct — a different remedy
  needs a different class, and conflating "everyone is out of budget" with "you are" would misinform
  the one user who could actually do something about the second.

## Consequences

- `LlmCallGuard` now depends on `Usage::Counter` (`app/models/usage/counter.rb`), a dependency that
  didn't exist before — a deliberate, narrow reuse of one proven primitive, not a merge of the two
  guard mechanisms (see Alternatives above).
- Two Postgres-backed counters can now exist per subject per day for the same request path (one
  `Usage::Quota` row for the app-level action, one `Usage::Counter` row under
  `SUBJECT_ACTION_TYPE` for each real provider request within it) — not merged, duplication is the
  intended state, consistent with ADR-0023.
- `LlmCallGuard.chat`, `.ensure_headroom!`, and `.record_call!` all require `subject:`, and
  `BulletRewriter.call`/`Resume::Extractors::Llm.call`'s `chat:` keyword dropped its now-dead
  `LlmCallGuard.chat` default (every call site already passed `chat:` explicitly) in favor of a
  plain required keyword — a caller can no longer resolve a subject-less chat by omission.
- `MAX_LLM_CALLS_PER_DAY_PER_SUBJECT` is a new required production variable (no default), sized
  against the 42-request floor from ADR-0038 but with the actual production value left as an
  explicit, unresolved deploy-time decision — see `docs/railway-deploy-runbook.md`.
- The documented gap in `docs/railway-deploy-runbook.md` and issue #106 itself — "the global cap has
  no per-caller dimension" — is closed by this change, once a production value for the new variable
  is chosen and deployed.
