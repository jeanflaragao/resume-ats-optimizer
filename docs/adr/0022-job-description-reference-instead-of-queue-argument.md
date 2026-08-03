# ADR-0022: Pass the download job a job-description reference, not the text

## Status
Accepted

## Context

`DownloadsController#create` enqueued `Resume::OptimizedPdfJob.perform_later(resume_id:,
job_description_text:, download_id:)`. In production the queue adapter is Solid Queue, which
serializes Active Job arguments into `solid_queue_jobs.arguments` — a plain `text` column. So every
download wrote up to `MAX_JOB_DESCRIPTION_LENGTH` (20,000) characters of pasted job posting to
Postgres in plaintext, and `config/recurring.yml` cleared only *finished* jobs. A job that raises is
not finished — Solid Queue records a `FailedExecution` and stops — so a failed download's arguments
were retained indefinitely.

Three inline comments and CLAUDE.md asserted the opposite ("job_description_text is never
persisted"). The claim was true for `JobDescriptionsController` and `PreviewsController`, which are
synchronous; phrasing it as an app-wide property is what hid the one path where it was false.

Whether a pasted job posting is personal data is arguable — it is third-party-authored text. That
*this* user pasted *this* posting is not arguable: it discloses where someone is applying. Treated
as sensitive here.

### Finding: `config.filter_parameters` never applied to job arguments

The issue left this open. It is settled, and it makes the log side a real ADR-0015 violation rather
than a stale comment:

**`config.filter_parameters` is not applied to Active Job arguments — in any Rails version.** The
pull request that would have added it, [rails/rails#38963](https://github.com/rails/rails/pull/38963),
was rejected. `ActiveJob::LogSubscriber` offers only `config.active_job.log_arguments`, which is
all-or-nothing per application or per job class.

`:job_description_text` has been in `config/initializers/filter_parameter_logging.rb` since ADR-0015,
which is exactly why nobody looked again. It protected the *request* log line and never touched
`Enqueued Resume::OptimizedPdfJob ... with arguments:`, emitted at `info` — production's log level.
The job posting was being written to the production log on every download.

### Finding: nothing has ever been deployed

Checked before planning any cleanup of existing rows: there is no `config/deploy.yml` and no
`.kamal/` (issue #48), neither has ever existed on any branch (`git log --all` returns nothing for
both paths), and the repository reports zero GitHub deployments, environments and releases. The
production `queue` database in `config/database.yml` has never been created. **There are therefore
no existing `solid_queue_jobs` rows carrying a job description**, and no data-cleanup migration is
needed. Recorded here because "you fixed the leak but left the old rows" is the obvious question to
ask of this change, and the answer stops being self-evident once a deploy exists.

## Decision

**Stop passing the text; pass a reference** — option 2 of issue #76. `DownloadsController#create`
writes the posting to a new `Resume::PdfRequest` and enqueues its id. Options 1 (only shorten the
retention window) and 3 (encrypt `solid_queue_jobs.arguments`) both leave the text in the queue's
own table, where its lifetime is governed by Solid Queue's bookkeeping rather than by us.

**A row, despite ADR-0021 having just argued for a cache entry over a table** for the optimization
result, on the grounds that "a cache entry expires by construction, a row has to be remembered
about." That reasoning stands and is the cost of this decision, not a counterargument to it: the job
must be able to read its input after an arbitrary queue delay, which a `Rails.cache` entry with an
independent expiry cannot promise. Paid for with `purge_stale!` plus
`test/config/recurring_test.rb`, so the remembering is enforced by a test rather than by discipline.

**Encrypted with Active Record Encryption, non-deterministically.** Deterministic mode buys
queryability we have no use for — the text is only ever read by id — and costs the property that
matters most here: identical postings would produce identical ciphertext, so a reader of the table
could tell that two users are applying to the same job without decrypting anything. That inference
is close to the thing this ADR is protecting. `support_unencrypted_data` stays off: the table is
new, so there is no plaintext to read back, and leaving it on would silently accept plaintext
forever.

**`PURGE_AFTER` is 15 minutes, derived — not inherited from ADR-0012.** It coincides with
`Resume::CachedOptimization::CACHE_TTL` and `Resume::OptimizedPdfJob::CACHE_EXPIRY`, and that
coincidence is not the reason. Those measure how long a *finished artifact* stays downloadable. This
measures how long we retain the *input* to a job that failed or has not started — a different
quantity that happens to land nearby. The two sides that actually bound it:

- **Privacy (shorter is better).** The floor is worst-case enqueue-to-finish. `Resume::
  CachedOptimization` measured the pipeline at `0.25s + 4.5s` per experience, so a nine-experience
  resume takes ~40.75s, or ~81.5s if it also waits out that class's lock. Anything under ~2 minutes
  would start deleting live work.
- **Operations (longer is better).** With three worker threads (`config/queue.yml`) a request only
  sits unstarted for 15 minutes under a genuine backlog — roughly 190 queued downloads at the
  measured median, or far fewer while the Anthropic API is degraded. Fifteen minutes is ~11x the
  worst single-job duration above, which absorbs that without keeping anything overnight.

**Deliberately not sized for manual retry of a failed job.** The issue reasoned that #74 made
deterministic failures common enough to keep the input around for an operator to retry. #74 is now
closed (ADR-0018 embedded Liberation Sans), but the premise survives it: `Resume::Pdf::
UnrenderableCharacterError` still ends every download for a CJK, Hebrew, Arabic or Devanagari name.
It does not change the window, because a deterministic failure is noticed hours or days later, never
inside any window worth retaining plaintext for. No retention we would tolerate makes operator
retry viable, so the supported recovery is the user requesting a new download — which writes a new
request — and this constant is not inflated for a workflow nobody can use.

**`config.active_job.log_arguments = false` globally in production, plus `self.log_arguments =
false` on the job.** This is a deliberate, permanent tradeoff and not merely the hotfix that
preceded the rest of this change:

- After this ADR the job's arguments are three ids, so the global switch protects nothing that is
  currently at risk. It is defence in depth against the *next* job, given that the framework offers
  no per-argument filter and `filter_parameters` — the mechanism a reader would assume is
  covering them — provably does not apply.
- The cost is real and falls on whoever debugs a silent job later: production logs will show which
  job ran and never with what. That is the price, accepted knowingly.
- The job-level line is not redundant. The global setting is production-only; the class-level one
  also covers `log/development.log`, where the same line is written during manual testing.

**Test-environment encryption keys are literals in `config/environments/test.rb`.** CI has no
`config/master.key` — it is gitignored and `.github/workflows/ci.yml` sets no `RAILS_MASTER_KEY` —
so credentials resolve empty there and `encrypts` raises
`ActiveRecord::Encryption::Errors::Configuration`. Environment config overrides the credentials
lookup by design (`activerecord`'s `active_record_encryption.configuration` initializer splats
`**app.config.active_record.encryption` last), so throwaway literals are sufficient. Preferred over
adding `RAILS_MASTER_KEY` as an Actions secret: this repository is public (ADR-0008), and test data
is scratch space that has no business being encrypted with the production key.

## Consequences

- `solid_queue_jobs.arguments` now holds three ids for this job. Rows for failed jobs still
  accumulate — unchanged by this ADR, and no longer interesting, since they carry no content.
  Clearing failed executions remains ordinary housekeeping, not a privacy item.
- Issue #76's acceptance criterion 2 asked for "a bound on how long a job description can sit in
  `solid_queue_jobs`". It is met by the stronger fact that no job description ever enters that table
  again. The bound that does exist — `PURGE_AFTER` — applies to `resume_pdf_requests` instead.
- A request purged before a backed-up queue reaches it makes its download unrecoverable. The job
  treats that as a first-class outcome, broadcasting `EXPIRED_REQUEST_MESSAGE` and writing it to the
  cache, rather than dying silently and leaving the status page on "Generating…" — the failure mode
  ADR-0018 closed and that a `pdf_request_id`-only job signature would have reopened. That is why
  `resume_id` and `download_id` remain job arguments: `record_failure` needs both, and neither is
  reachable once the record is gone.
- The first encrypted column in the project. Rotating `active_record_encryption.primary_key` now has
  a consequence — though a small one while the only encrypted data has a fifteen-minute lifetime.
- `Resume::CachedOptimization` is untouched: it still receives the text and still keys on a digest
  of it, so ADR-0021's preview→download reuse behaves identically.
