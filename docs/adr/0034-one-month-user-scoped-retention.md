# ADR-0034: One month from last access, single-tier, credits never purged

## Status
Accepted. Supersedes [ADR-0026](0026-purge-stale-resumes.md).

## Context

ADR-0026's two-tier retention scheme — 7 days from `last_accessed_at` for a "claimed" resume,
24 hours from `created_at` for a "never-claimed" one — existed because `owner_token` was written
in a *second* `update!` call after `Resume::Import` returned a fully-persisted row. A crash
between the two left a resume with real PII and no owner, reachable by no session, ever. ADR-0026
called this the "orphan" tier and gave it its own 24-hour window, separate from the 7-day window
for a resume someone could plausibly still come back to.

Issue #121 replaces `owner_token` with a durable `user_id`, and reopens the retention question
ADR-0026 itself flagged as provisional — the 7-day window was chosen specifically because there
was no durable owner to come back to. With real accounts, "my resumes persist" is now a
reasonable expectation, and the product's own resume-history page (issue #121's `resumes#index`)
assumes it.

This ADR was written from a decision already made on the issue, not derived here — recorded
below with its reasoning, not re-litigated.

## Decision

**One month from `last_accessed_at`, single tier, no "orphan" concept.** `resumes.user_id` is now
`NOT NULL`, and `Resume::Import` sets `user:` in the *same* `Resume.create!` call that persists
everything else (`app/services/resume/import.rb`) — not a second `update!`. A resume with no
owner is no longer a rare race outcome; it is a state the schema cannot produce. The orphan tier
is removed, not renamed or kept dormant: `Resume.purge_stale!` is now

```ruby
def self.purge_stale!
  stale = where(last_accessed_at: ...LAST_ACCESSED_PURGE_AFTER.ago)
  count = stale.count
  stale.in_batches.destroy_all
  count
end
```

**The window is measured from last access, not from credit exhaustion.** Issue #122's credit
balance never expires — a user who buys credits, uses a few, and disappears would otherwise have
their PII (name, email, phone, full work history) retained forever if retention were tied to
"still has unused credits." `last_accessed_at` (issue #59) is the signal that actually reflects
use, the same reasoning ADR-0026 already established for its own claimed-resume tier.

**Credits are never deleted with resumes; the balance is a permanent liability.** Someone who
returns after a year finds their remaining credits and starts fresh. `Resume.purge_stale!`'s
`where` clause only ever selects from `resumes` — it structurally cannot reach `users` or
`usage_counters` — and this is asserted directly rather than left implicit:
`ResumeTest#"purge_stale! does not delete the resume's owner or touch their usage counters"`
creates a stale resume, consumes a `Usage::Counter` for its owner, runs the purge, and asserts
both the `User` row and the counter survive unchanged. Issue #122's actual `Credit` model doesn't
exist yet, so `Usage::Counter` — the closest existing analog to a balance that persists
independent of any single resume — stands in for it now; this test should be revisited once #122
lands to assert against the real thing too.

**The deletion warning is in-app only, no email.** Surfaced on `resumes#index`
(`app/views/resumes/index.html.erb`): each resume shows when it will be "removed automatically"
(`last_accessed_at + LAST_ACCESSED_PURGE_AFTER`). No mailer exists anywhere in this app, and
building email delivery solely for a retention notice is disproportionate to the problem. Revisit
if a mailer becomes necessary for something else first.

## Alternatives considered

- **Keep the two-tier shape, just widen the claimed-resume window to a month**: rejected. The
  orphan tier's entire justification — a row that can exist with no owner — no longer holds. A
  dormant branch that can never match anything is not a simplification deferred, it's dead code
  kept alive for a population that is now provably empty.
- **30 days flat from `created_at` or `updated_at`**, matching issue #59's original proposal:
  rejected for the same reason ADR-0026 rejected it — `updated_at` doesn't move on a read in this
  app, and bumping it would invalidate `Resume::CachedOptimization`'s cache key on every page
  view (ADR-0021). `last_accessed_at` remains the correct clock; only the window and the tier
  count change here.

## Consequences

- `Resume::LAST_ACCESSED_PURGE_AFTER` is now `1.month`, was `7.days`. `Resume::ORPHAN_PURGE_AFTER`
  is removed; `test/config/recurring_test.rb`'s window-vs-schedule check now runs against
  `LAST_ACCESSED_PURGE_AFTER` alone.
- The migration dropping `owner_token` (issue #121) removes the partial index on `created_at`
  (`where: "owner_token IS NULL"`) with no replacement — nothing queries that shape anymore. The
  partial index on `last_accessed_at` becomes a plain index, since `last_accessed_at` is populated
  for every row now (set at creation by `Resume::Import`, not left `nil` until a first later
  visit).
- No data migration for existing rows. Confirmed (re-verifying ADR-0022's and ADR-0026's own
  finding, given #111 added Railway config since either was written) that nothing has ever been
  deployed — every `resumes` row anywhere is local test data, so there is nothing aged under the
  old 7-day/24-hour rule to reconcile against the new one.
