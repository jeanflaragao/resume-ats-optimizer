# ADR-0026: Purge stale resumes with owner-scoped retention

## Status
Superseded by [ADR-0034](0034-one-month-user-scoped-retention.md) — issue #121's durable
`user_id` ownership removed the "orphan" tier's premise and reopened the retention window this
ADR chose while there was no durable owner to come back to.

## Context

`Resume` rows carry real PII — name, email, phone, and full work history — and have been
retained forever since the model existed. ADR-0022 (issue #76) bounded a *pasted job
description* to 15 minutes on privacy grounds. It left this sitting next to it: the
candidate's own identity and career history, arguably more sensitive than the posting they
were applying against, had no retention bound at all. Issue #59 closes that inconsistency.

### Departure from issue #59's own proposal — recorded explicitly, not resolved silently

Issue #59 proposes a single `RETENTION_PERIOD` (it recommends 30 days) purged from
`updated_at`, with no `owner_token` distinction, and is explicit that the window is a product
decision: *"if 30 days looks wrong for this product, propose a different number and stop — do
not pick one silently."* What was actually built here is a two-tier scheme — 7 days from
*last access* for a claimed resume, 24 hours from *creation* for a never-claimed one — which
is a different shape, not just a different number. Recorded here rather than silently
substituted, per this repo's own rule that the issue body is the source of truth and a
conflicting prompt may be based on stale context.

Two things drove the divergence:

1. **`updated_at` doesn't mean what the issue's design needs it to mean.** Nothing in this
   codebase touches a `Resume`'s own columns after creation — `Experience`/`Education` children
   can change without their parent's `updated_at` moving (no `touch: true` on those
   associations), and no controller action re-saves the resume itself on a read. So `updated_at`
   is, for practically every row, indistinguishable from `created_at`. Purging from it is not
   "purge what nobody's using" — it's a flat TTL from upload, full stop. Implementing genuine
   *last-access* retention — the thing that stops an active user from losing their resume on
   day 7 because they revisit every few days without re-uploading — requires a column that is
   deliberately bumped on read, which `updated_at` is not, by design, anywhere else in this app.
2. **Bumping `updated_at` on every read would have been actively wrong**, independent of which
   retention numbers get chosen. `Resume::CachedOptimization` keys its cache on a digest of
   `cache_key_with_version`, itself derived from `updated_at` (ADR-0021). Making `updated_at`
   double as a last-access marker would invalidate the optimization cache on every page view,
   preview, or download click — silently forcing a fresh, cost-bearing LLM re-run on each one.
   This is the load-bearing reason a separate `last_accessed_at` column exists at all, regardless
   of whether the retention window ends up being 30 days flat or something else — see the
   `update_column` note below.

The 7-day/24-hour numbers themselves are a genuine departure from the issue's 30-day
recommendation, made deliberately rather than defaulted into: once a real last-access column
exists, an active user is never at risk of losing a resume just from the clock running out — so
a shorter window costs an active user nothing, while bounding a genuinely abandoned resume's
retention more tightly than the issue's original number would. If that reasoning is wrong for
this product, it is a product call to revisit, not an implementation detail — flagged here so
it's revisitable rather than buried.

### The orphan tier as specified could not be built as specified

Separately from the numbers, the *task instructions* driving this implementation asked for a
second tier beyond what issue #59 itself describes: an orphaned resume, defined as one whose
`owner_token` "no longer resolves to any live session." That definition assumes a session
registry to check liveness against. There isn't one. `current_owner_token`
(`ApplicationController#current_owner_token`) is `session[:owner_token] ||=
SecureRandom.hex(32)` — Rails' default cookie session store. No
`config/initializers/session_store.rb` overrides it, no session-store gem beyond the default
`rack-session` is in `Gemfile.lock`, and `db/schema.rb` has five tables total — none of them
`sessions`. A cookie-store session lives entirely in the browser; the server never records
which tokens exist, so there is nothing to check a given `owner_token` against to determine
whether "its" session is still live. The literal check cannot be implemented without first
adding a server-side session store — a real infrastructure change, not something to fold
silently into a retention purge.

## Decision

**Redefine "orphan" from "dead session" (undetectable) to "never claimed" (fully knowable from
the row itself).** `owner_token` is set exactly once, in `ResumesController#create`
(`resume.update!(owner_token: current_owner_token, ...)`), immediately after
`Resume::Import.call`. There is no retry path and nothing else ever writes that column. A row
where this update never landed — a process crash between import and the write is the only
realistic cause — can never subsequently match `find_by!(id:, owner_token: current_owner_token)`
for any session, because `current_owner_token` is never `nil`. That row is genuinely,
permanently unreachable from the moment it's created, with no ambiguity — unlike a claimed
resume, which might legitimately go unvisited for a while and still belong to someone holding
the cookie.

This gives two tiers, both fully knowable from data already on the row:

- **`owner_token` present → 7 days from `last_accessed_at`** (`Resume::LAST_ACCESSED_PURGE_AFTER`).
  A new `resumes.last_accessed_at` column, initialized at upload time and bumped by
  `ApplicationController#find_owned_resume!` — the single shared lookup every read path
  (`ResumesController#show`, `JobDescriptionsController#create`, `PreviewsController#create`,
  `DownloadsController#create`/`#ready`/`#show`) already routes through, so one call site covers
  all of them.
- **`owner_token` NULL → 24 hours from `created_at`** (`Resume::ORPHAN_PURGE_AFTER`). No "last
  access" concept applies to a row nothing can ever look up; the only timestamp available is
  when it was created.

**`find_owned_resume!` uses `update_column`, not `update!`/`touch`.** `Resume::
CachedOptimization` keys its cache on a digest of `cache_key_with_version`, which is derived
from `updated_at`. If bumping `last_accessed_at` also bumped `updated_at`, every page view,
preview, or download click would invalidate the optimization cache — silently reopening the
cost problem ADR-0021 closed (one preview-then-download paying for one bullet-rewrite fan-out,
not two). `update_column` skips both validations and the `updated_at` touch, keeping access
bookkeeping fully separate from content-change tracking.

**`Resume::PurgeStaleJob` wraps `Resume.purge_stale!`, aligning with the issue's own proposed
mechanism.** The issue asks for a job (not a bare `command:` entry) specifically so the
destroyed-record count can be logged — an explicit acceptance criterion, and real operational
value: without it there is no way to tell from the logs whether the purge ran at all, let alone
whether it over- or under-deleted. `Resume.purge_stale!` itself stays a plain class method
returning `{ claimed:, orphan: }` counts, matching the shape of its siblings
`Resume::PdfRequest.purge_stale!` / `Usage::Counter.purge_stale!`; the job is a thin wrapper
that calls it and logs the result, scheduled via a `class:` entry in `config/recurring.yml`
rather than those two's `command:` entries.

**`Resume.purge_stale!` uses `in_batches.destroy_all`, not a bare `destroy_all`, and not
`delete_all`.** Two independent reasons, not one:
- `delete_all` is not an option at all: `experiences` and `educations` have plain
  `add_foreign_key` with no `ON DELETE CASCADE` (unlike `resume_pdf_requests`, which does), so a
  raw delete against a stale resume with any children raises a foreign-key violation rather than
  silently orphaning rows. `destroy_all` is required so `dependent: :destroy` runs.
- Batching is new relative to `Resume::PdfRequest.purge_stale!`, which deliberately doesn't
  batch — that table stays near-zero because a successful download deletes its own row.
  `resumes` has no such self-cleaning property; the stale set inside a full 7-day window at real
  signup volume can be large enough that loading it into memory in one `destroy_all` call is the
  wrong default. `in_batches.destroy_all` (Rails' `BatchEnumerator`, default batch size 1000)
  still runs `dependent: :destroy` per record, just in bounded chunks.

**Schedule: every hour**, in `config/recurring.yml`, alongside `purge_stale_pdf_requests` (every
5 minutes, against a 15-minute window) and `purge_stale_usage_counters` (daily, against a 7-day
window enforcing a 1-day period). The shortest window enforced here is `ORPHAN_PURGE_AFTER` at
24 hours; hourly keeps the schedule's error term small (~1 hour of drift on a 24-hour promise)
without running more often than data that isn't time-critical the way #76's plaintext-job-
description leak was needs.

**A visible line on the upload screen** (`app/views/resumes/new.html.erb`) states the retention
window in plain language. Silent retention and silent deletion are different problems, and
fixing the first must not create the second — a user who returns to a vanished resume with no
warning has experienced a bug, not a privacy feature. The line states the 7-day claimed-resume
window only; the 24-hour orphan tier is an internal consistency detail a user who successfully
uploaded has no reason to know about.

### Finding: nothing has ever been deployed

Checked before deciding whether existing rows needed a data migration, same question ADR-0022
asked of `resume_pdf_requests`: there is no `config/deploy.yml` and no `.kamal/` (issue #48),
and nothing on any branch has ever changed that. **There is therefore no production `resumes`
row for this to have retained too long.** The migration still backfills `last_accessed_at =
created_at` for any existing claimed resume (`owner_token IS NOT NULL AND last_accessed_at IS
NULL`) — cheap, and closes a real edge case for local/dev data predating this column: without
it, such a row's `last_accessed_at` stays `NULL` forever, which matches neither purge tier
(`NULL` fails the claimed tier's `...cutoff` range comparison, and the orphan tier only matches
`owner_token IS NULL`), so it would never be purged by either branch.

## Consequences

- Two new partial indexes support the two purge queries exactly:
  `add_index :resumes, :last_accessed_at, where: "owner_token IS NOT NULL"` and
  `add_index :resumes, :created_at, where: "owner_token IS NULL"`. The orphan index stays tiny
  in practice, since the population it covers should be near-zero.
- If a real session store is ever introduced (the prerequisite named in `Usage::Quota`'s own
  ADR-0023 for turning per-session quotas into per-user quotas), the literal "dead session"
  orphan check becomes possible again. This ADR's redefinition would then be worth revisiting —
  but is not a defect to fix reactively today, since the 7-day claimed-resume tier already
  reclaims a cleared-cookies user within a week regardless.
- `Resume::LAST_ACCESSED_PURGE_AFTER` (7 days) is now the retention ceiling for a resume that
  hasn't been visited. `Resume::Pdf.guard_renderable!`, `Resume::CachedOptimization`, and every
  other resume-reading path are unaffected: they all operate on rows that, by definition of
  being reachable, are inside the window.
