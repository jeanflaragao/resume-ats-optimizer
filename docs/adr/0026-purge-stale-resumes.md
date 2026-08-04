# ADR-0026: Purge stale resumes with owner-scoped retention

## Status
Accepted

## Context

`Resume` rows carry real PII — name, email, phone, and full work history — and have been
retained forever since the model existed. ADR-0022 (issue #76) bounded a *pasted job
description* to 15 minutes on privacy grounds. It left this sitting next to it: the
candidate's own identity and career history, arguably more sensitive than the posting they
were applying against, had no retention bound at all. Issue #59 closes that inconsistency.

### The retention rule as specified could not be built as specified

The issue asked for two tiers: a claimed resume (`owner_token` present) purged 7 days after
its *last access*, and an orphaned resume (`owner_token` that "no longer resolves to any live
session") purged after 24 hours.

The second tier assumes a session registry to check liveness against. There isn't one.
`current_owner_token` (`ApplicationController#current_owner_token`) is
`session[:owner_token] ||= SecureRandom.hex(32)` — Rails' default cookie session store. No
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
