# ADR-0023: Per-session usage quotas in Postgres, alongside (not instead of) the global LLM cap

## Status
Superseded by [ADR-0033](0033-user-id-usage-quotas.md) — issue #121 replaced the per-session
`subject` this ADR establishes with the signed-in user's id, once #120 made real accounts
mandatory.

## Context

`LlmCallGuard`'s cap ([ADR-0019](0019-count-llm-calls-at-the-provider-boundary.md),
[ADR-0020](0020-fail-closed-llm-guard-configuration-in-production.md)) is a single counter keyed
only by the date. It bounds the Anthropic bill, and nothing else. It has no per-subject
dimension, so the 11th real provider request of the day — whoever makes it — makes every
subsequent visitor see *"We've hit today's processing limit."*

One full flow costs `2 + E` provider requests (`E` = experiences with bullets), or `2 + 2E` when
the download misses the optimization cache ([ADR-0021](0021-cache-the-optimization-result-between-preview-and-download.md)).
That is 7–20 requests from one person. Issue #22 was opened for the concrete version of this:
someone repeatedly submitting large job descriptions, and taking the day down with them.

Issue #45's owner comment is explicit that the global cap must **not** be removed or replaced
here. It stays as the emergency ceiling; #22 adds a second, narrower layer. Merging the two is
#45's own future work.

The mandatory first question was what a "user" is in this codebase today. The answer:

- **There is no `User` model and no authentication.** `app/models/` holds `Resume`,
  `Experience`, `Education` and `Resume::PdfRequest`. `config/routes.rb` has no session or
  registration routes. There is not even an open issue for auth.
- Ownership is [ADR-0007](0007-rails8-auth-and-owner-token-placeholder.md)'s deliberately
  temporary placeholder: `ApplicationController#current_owner_token`, an opaque
  `session[:owner_token] ||= SecureRandom.hex(32)`, persisted to `resumes.owner_token` and
  enforced only at the controller layer.
- CLAUDE.md's "Auth: Rails 8's built-in authentication generator" records a *decision*, not
  shipped code.

So "per-user rate limiting" can only mean per browser session, and a fresh incognito window is a
fresh quota.

## Decision

Add a per-subject, per-action, per-day quota, enforced at the controller, stored in Postgres.

1. **Subject = `current_owner_token`.** `usage_counters.subject_token` is a plain opaque string,
   not a `resumes` reference — the first quotaed action is an upload, which happens before any
   `Resume` exists — so when real auth lands it takes a user id with no migration and a one-line
   change at each call site.

2. **Four action types, not the issue's three.** `resume_extraction`,
   `requirement_extraction`, `bullet_rewriting`, `pdf_generation`. Issue #22's body omits the
   upload, but `Resume::Extractors::Llm` is a real provider request — one of the two in #45's
   `2 + 2E` — and it is the first thing an anonymous visitor can trigger. Counting the three
   downstream actions while leaving the entrance open would not bound anything. Separate
   counters rather than one aggregate, because the four have unequal cost and one number would
   let cheap actions consume the budget for expensive ones.

3. **Daily only, with the period in the key.** `usage_counters` is unique on
   `(subject_token, action_type, period, period_start)` and every row written today has
   `period = "day"`. Issue #22 says "daily/monthly"; shipping both would mean eight ENV values
   that must all be set before production boots, and half of them would be filled in to satisfy
   the boot check rather than reasoned about. Carrying `period` in the key from the start makes
   monthly a constant plus config later, not a migration against a populated table.

4. **A single-statement atomic UPSERT.** `Usage::Counter.consume!` issues one
   `INSERT ... ON CONFLICT (subject_token, action_type, period, period_start) DO UPDATE SET
   count = usage_counters.count + 1 ... RETURNING count`. Read-then-write loses updates exactly
   when it matters — two overlapping requests for the same subject — and that is the case a rate
   limit exists to catch.

5. **Increment first, compare second**, the same direction as `LlmCallGuard.record_call!`.
   Checking before incrementing leaves a window where two concurrent requests both read a count
   under the limit. The cost is that a refused attempt still occupies a slot, which is moot: the
   subject is over the limit for the rest of the period either way. Nothing is refunded when the
   work that follows fails.

6. **Enforced at the controller, before any work.** Issue #22 says "before enqueuing the job into
   Solid Queue", but only `DownloadsController#create` enqueues; upload, analyze and preview are
   synchronous. The intent — spend no worker and no provider request on a refused request —
   generalises: `enforce_quota!` is called at the top of all four actions, *after* the existing
   blank/length guards (rejecting an over-long job description must not cost a slot) and before
   `Resume::Import`, `JobDescription::Extractor`, `Resume::CachedOptimization`, and — in the
   download's case — before both the `Resume::PdfRequest` write and the `perform_later`.

7. **Limits are ENV-configured with no production default**, validated at boot by
   `Usage::Quota.validate_configuration!` from `config/initializers/usage_quota.rb` — the same
   rule, shape and `SECRET_KEY_BASE_DUMMY` exemption as ADR-0020.

8. **A distinct error and a distinct message.** `Usage::Quota::ExceededError` is not a subclass
   of `LlmCallGuard::DailyLimitExceededError`, and its flash says *"You've reached your daily
   limit for … "* against the global cap's *"We've hit today's processing limit"*. Two different
   facts about who is out of budget, and the user can act on one of them.

## Alternatives considered

- **Rails 8's built-in `ActionController::RateLimiting` (`rate_limit to:, within:`)**: less code
  and no migration, but it is backed by `Rails.cache`, which in production is Solid Cache — size-
  capped and evicting. A quota that can silently reset under cache pressure is not a quota, and
  issue #22 explicitly asks for a Postgres counter. The rows are also the only history available
  for sizing the production limits, which a cache would not retain.
- **Folding this into `LlmCallGuard`, one mechanism with a subject dimension**: rejected as out
  of scope by issue #45's owner comment, which is right on the merits too — the global cap
  answers "is the bill safe today" and this answers "is one visitor crowding out the rest", and
  a single mechanism would have to fail closed on both questions with one message.
- **Adding a salted-hash IP dimension**: would close most of the incognito bypass, since a new
  private window changes the cookie but not the address. Rejected here: it false-positives on
  shared NAT, corporate and mobile-carrier addresses, and it introduces a pseudonymous network
  identifier the app does not currently store at all, which is an ADR-0015 conversation of its
  own. Worth a follow-up issue, not a rider on this one.
- **Blocking issue #22 until real auth exists**: the honest objection, since a session-keyed
  quota is one keystroke from being bypassed. Rejected because auth is not merely unfinished but
  unscheduled — no open issue — so this would mean shipping nothing indefinitely, while a
  session quota does stop the case the issue was actually opened for.
- **Counting only `Resume::CachedOptimization` misses**, so a re-preview of an unchanged job
  description stays free: would require enforcing inside that class, after the lock and possibly
  after a full pipeline, which is the opposite of failing fast. Absorbed by sizing instead.

## Consequences

- **This does not make public signup safe, and issue #45's "trigger condition" comment is wrong
  where it assumes otherwise.** That comment treats #22 as the hard prerequisite for opening
  signup; an anonymous visitor with N private windows still has N quotas, so the global cap is
  still the only thing between a determined abuser and the bill. The prerequisite for public
  signup is real auth, with this mechanism attached to it. Recorded on #45.
- Two independent spend guards now exist, with two different error classes, two different flash
  messages and two sets of ENV variables. That duplication is the intended state until #45, not
  drift.
- #48's deploy config gains four more must-be-set values, on top of ADR-0020's three. A
  production boot now fails on any of seven missing variables.
- A user is charged for a preview that `Resume::CachedOptimization` would have served free
  (consequence of decision 6, above). Visible as a preview quota that is consumed slightly faster
  than the provider requests behind it.
- `usage_counters` grows with traffic — one row per subject per action per day — and is trimmed
  by `Usage::Counter.purge_stale!` (`RETAIN_FOR`, 7 days) from `config/recurring.yml`. As with
  every other recurring task, nothing runs it until issue #48 exists.
- `subject_token` duplicates a value already stored in `resumes.owner_token`, so this adds no new
  category of data — but it is the credential `find_owned_resume!` authorizes against, so it must
  never be logged. The `rescue_from` handler logs the exception class and the action type only.
