# Project review — 2026-08-01

Read-only review of `resume-ats-optimizer` at commit `c93dbba`, covering roadmap accuracy, gaps
blocking a first Kamal deploy (#48), risk in the current code (LLM cost, PII, untested failure
modes), and issue hygiene. No file under `app/`, `lib/`, `config/`, `db/`, or `test/` was modified.

**Headline:** the board is in better shape than #54 implied — one open issue was fully done and one
was ~80% done — but four untracked defects exist, and the most severe silently breaks the core
deliverable for a large class of real users **today**, independent of deployment.

Findings are ordered by how much you should trust them. Anything that ran long became its own
issue with a pointer here.

---

## Verified findings

Confirmed by reading code, running a reproduction, or querying `gh`.

### 1. The PDF download is broken for any non-Windows-1252 character → #74

`app/services/resume/pdf.rb:22` builds `Prawn::Document.new` with no font registered, so Prawn
2.5.0 uses the built-in AFM fonts, which are Windows-1252 only. Reproduced against this project's
Ruby 3.4.9 and pinned `prawn (2.5.0)` — full script and output in #74:

```
PASS  •  —  “ ”  –  José Müller — Café Niño     (all inside Windows-1252)
FAIL  Bałka · Jiří · Gülşah · Gergő · Iași      Prawn::Errors::IncompatibleStringEncoding
FAIL  Cyrillic · Greek · CJK · → · ✓ · 🚀 · U+2011
```

The boundary is not "ASCII vs. not" — it is exactly Windows-1252, which is why this went
unnoticed: em dashes, curly quotes and French/Spanish/German accents all pass.

**It is not only an international-names bug.** `BulletRewriter` stores whatever Claude returns, and
`FidelityCheck` gates on new digits and token coverage (`app/services/fidelity_check.rb`), not on
charset — a `→` is neither. So an all-ASCII resume can be turned into a crashing one by the rewrite
step alone. I did not measure how often Claude actually does this; the path is open, the frequency
is unknown.

**User-visible symptom** — the part that sets severity. This is a background job, so none of #56's
request-cycle rescues apply:

- The job runs `Resume::Optimization` **first** (`optimized_pdf_job.rb:15`), so N Claude calls
  succeed and are billed, *then* `Resume::Pdf` raises.
- **No retry loop.** `ApplicationJob` declares no `retry_on` (both lines commented), and Solid Queue
  1.5.1 does not retry on its own — `Job::Retryable#failed_with`
  (`solid_queue-1.5.1/app/models/solid_queue/job/retryable.rb:18-29`) creates a `FailedExecution`
  row; `#retry` is manual.
- **Normal case: a misleading error.** `downloads/_failed.html.erb` says *"Something went wrong
  generating your PDF. Please try again."* Every retry fails identically and spends N more LLM
  calls first — and the user has every reason to retry, because **the preview page rendered their
  resume perfectly** (it is HTML, no charset limit). Preview works, download never does.
- **Race case: a permanent hang.** If the `turbo_stream_from` subscription hasn't connected when the
  failed broadcast fires (#72's race), it is lost — and unlike the success path there is **no
  fallback**. `DownloadsController#ready` (`:12-18`) only reads `Rails.cache`, and a failed job
  caches nothing, so it returns `head :no_content` forever. The page stays on "Generating..."
  indefinitely.

So: error normally, hang in the race, never an infinite retry. `test/services/resume/pdf_test.rb`
has six tests and not one non-ASCII character.

### 2. The LLM daily cap undercounts by experience count, and one Chat is reused → #75

Two defects, one root cause. `app/services/resume/optimization.rb:11` resolves
`chat: LlmCallGuard.chat` **once** as a default argument and threads that object into every
`BulletRewriter.call` (`:48`), while `record_call!` increments only inside `.chat`
(`llm_call_guard.rb:16-21`) and `bullet_rewriter.rb:46` makes one real API call per invocation.

- **A 10-experience resume = 10 billable calls, counter +1.** `MAX_LLM_CALLS_PER_DAY` permits
  roughly `10 × average_experience_count`, not 10. `Resume::Optimization` is the only fan-out site;
  the other two call sites count correctly.
- **The shared `RubyLLM::Chat` accumulates history.** Verified in the installed gem:
  `ruby_llm-1.16.0/lib/ruby_llm/chat.rb:40` (`ask` → `add_message`), `:167` (`messages <<`), `:229`
  (the reply is appended too). Every `ask` re-sends the whole array, so rewrite *k* carries all
  *k−1* prior prompts and replies — on top of the 20,000-char job description already re-embedded
  per prompt (`bullet_rewriter.rb:82`). Input tokens grow ~O(N²), on a path run **twice** per user
  flow (preview and download each call `Resume::Optimization` independently).

Cross-contamination is a secondary concern only: `FidelityCheck` checks each bullet against its own
original and falls back on failure, so it contains the output risk. It does not contain the cost.

### 3. `job_description_text` is persisted in production, contradicting the code's own comment → #76

`downloads_controller.rb:2-3` (and CLAUDE.md) state it is never persisted. But `:33-37` passes it to
`perform_later`, `production.rb:50` sets `queue_adapter = :solid_queue`, and `db/queue_schema.rb:32`
is `t.text "arguments"` — up to 20,000 characters of pasted job posting, plaintext, in Postgres.

Invisible locally because dev/test use the in-memory `:async` adapter, so the claim is true in every
environment anyone has run. `config/recurring.yml:12-15` clears only **finished** jobs; failed rows
are retained indefinitely — which compounds with #74, since that makes failures routine.

This is a **gap, not an ADR contradiction**: ADR-0015/0016 are about log output, and both hold.
Resume PII is *not* affected — the job takes `resume_id`, not attributes.

### 4. `LlmCallGuard`'s defaults are wrong for production and set nowhere → #77

`ENABLE_REAL_LLM_CALLS` defaults `false`, `MAX_LLM_CALLS_PER_DAY` defaults `10`
(`llm_call_guard.rb:24,28`). Correct for their stated local-testing purpose; nothing outside
`docker-compose.yml` (local-only) sets them, and there is no deploy config to set them in.

- **Unset:** every call site returns `StubChat`, writing
  `"[LlmCallGuard stub response — ENABLE_REAL_LLM_CALLS is not set]"` into the summary, the job
  title, and every bullet (`:64,74,77`) — and rendering it into a real downloadable PDF. Loud rather
  than plausible, so a smoke test catches it; the risk is deploying without one.
- **Enabled at default:** a single global counter keyed only by date (`:31-37`), no per-user
  dimension. The 11th call of the day from *any* visitor makes every subsequent user see *"We've hit
  today's processing limit."*

### 5. #46 was complete but still open → closed

All four checklist items verified via `gh` and the working tree; full evidence in the closing
comment on #46. Landed in PR #51, which said "Part of #46" and so never auto-closed it.

### 6. Things that are already correct

Stated so they are not re-reviewed:

- **Ownership is enforced and tested on all six paths** — `resumes#show`,
  `job_descriptions#create`, `previews#create`, `downloads#create`, `downloads#ready`,
  `downloads#show` (`test/integration/*:220, :70, :91, :52, :102, :125`).
- **ADR-0015 holds.** `job_description_text` is in `filter_parameters`
  (`config/initializers/filter_parameter_logging.rb:8`), and all eight `Rails.logger` call sites in
  `app/` log exception class or field name only — no raw values.
- **Controller error paths are well covered** — daily limit, LLM service error, Faraday connection
  error, mismatched bullet count, both size bounds, malformed PDF, unreadable JSON.
- **`bin/docker-entrypoint`'s `db:prepare` guard is not a bug.** `:10-12` matches on the last two
  argv entries being `./bin/rails server`, which the Dockerfile `CMD`
  (`["./bin/thrust", "./bin/rails", "server"]`) satisfies.
- **A very long unbroken token does not break Prawn** — it wraps mid-word. Ruled out, not assumed.
- **#23 is correctly open** — `README.md` is still the 24-line Rails stub.

---

## Inferred findings

Believed true, not confirmed. Each says what would settle it.

1. **ActiveJob's enqueue log line may also leak `job_description_text`.** Rails logs
   `Enqueued ... with arguments:` at `info`, which is production's level (`production.rb:38`). I
   could not confirm whether `filter_parameters` applies to job arguments in Rails 8.1. If it does
   not, this is a direct ADR-0015 violation on top of #76 and raises that issue's severity.
   *Settle it:* enqueue in a production-like console at `RAILS_LOG_LEVEL=info` and read stdout.

2. **Solid Cache may drop or early-evict a large PDF.** `config/cache.yml` sets only
   `max_size: 256.megabytes` (whole-store), no `max_entry_size`, and expiry is lazy trimming rather
   than a hard 15-minute TTL. Symptom would be a spurious *"That download link has expired."*
   *Settle it:* read the solid_cache gem's defaults, or write a >10 MB entry and read it back.

3. **The `cache`/`queue`/`cable` databases may not provision cleanly.** All three `*_schema.rb`
   files are committed, but the `db/*_migrate` directories named at `config/database.yml:67,71,75`
   do not exist. This is the stock Rails 8 layout and `db:prepare` should load from the schema
   files — I could not execute it. Worth making the first explicit check of the #48 deploy.
   *Settle it:* `RAILS_ENV=production bin/rails db:prepare` against a throwaway Postgres.

4. **Claude's real-world rate of emitting out-of-charset characters** (drives how bad #74 is beyond
   international names). *Settle it:* run `BulletRewriter` with `ENABLE_REAL_LLM_CALLS=true` over
   real bullets and grep for characters outside Windows-1252.

5. **#40's "now covered" claims** are based on test names and bodies matching the branches, not on a
   regenerated coverage report. *Settle it:* re-run SimpleCov.

---

## Actions taken

### Created

| # | Title | Why |
|---|---|---|
| [#74](../../issues/74) | `fix(pdf)`: Prawn's built-in fonts crash the download job on any non-Windows-1252 character | Verified finding 1. Includes the reproduction script and its exact pass/fail table as a ready-made red test. |
| [#75](../../issues/75) | `fix(llm-guard)`: the daily cap undercounts by experience count, and one `RubyLLM::Chat` is reused across every rewrite | Verified finding 2. |
| [#76](../../issues/76) | `fix(privacy)`: Solid Queue persists `job_description_text` in plaintext, contradicting the "never persisted" claim | Verified finding 3. |
| [#77](../../issues/77) | `fix(llm-guard)`: `LlmCallGuard`'s defaults make a first production deploy either stubbed or capped at 10 calls/day | Verified finding 4. |
| [#78](../../issues/78) | `test(downloads)`: no end-to-end coverage that a failed PDF job surfaces to the browser | The test that would have caught #74's symptom; the failure path has no fallback where the success path does. |

### Edited

| # | Change |
|---|---|
| [#48](../../issues/48) | Appended a verified deploy-readiness checklist: every env var with file:line and unset-behaviour, the worker/`db:prepare` split, the three secondary databases, `config.hosts`, and links to #74/#76/#77 as things that break a first deploy in ways a smoke test would miss. Original body untouched. |
| [#40](../../issues/40) | Status refresh: two of its three named branches are now covered incidentally by PR #68's tests. Narrowed to the two that genuinely remain (education not-found-in-source, `parse_date`'s rescue), with the citations. |
| [#45](../../issues/45) | Correction: it describes the cap as blunt-but-working; per #75 it does not count what it claims. Flags that any per-user quota #22 derives from current numbers starts from bad data. |

All five created and all three edited issues carry `needs-triage`. The label did not exist and was
created.

### Closed

| # | Justification |
|---|---|
| [#46](../../issues/46) | **The only close.** All four checklist items verified — `.github/workflows/ci.yml` (4 jobs, PR + push triggers); `gh api .../branches/master/protection` returning `strict:true`, `enforce_admins:true`, `allow_force_pushes:false`, 4 required contexts; `secret_scanning` and `secret_scanning_push_protection` both `enabled`; `GET /vulnerability-alerts` → `204`. Landed in PR #51, which said "Part of #46" and so never auto-closed it. Full per-item evidence is in the closing comment, including one divergence flagged rather than silently ticked (the issue said *not* automatic version-update PRs; `.github/dependabot.yml` configures them, superseded by ADR-0009) and one adjacent setting noted but excluded (`dependabot_security_updates` is `disabled` — a different thing from the alerts the checklist asked for). |

Nothing else was closed. #65/#66/#72 are accurate as written. #19/#20/#22/#23/#37/#59/#60 are open
work I could not show to be done.

---

## Open questions for you

Decisions I deliberately did not make.

1. **#74's fix direction — embed a Unicode TTF, or transliterate to Windows-1252?** A TTF renders
   every alphabet correctly but adds image size, changes how every PDF looks, needs a licence
   glance, and the ATS-friendliness of an embedded font vs. base-14 Helvetica should be
   sanity-checked, since that is the entire point of the template (ADR-0004). Transliteration is
   small and dependency-free but silently mangles a user's own name — for a resume tool, arguably
   worse than failing. This is a product call about who your users are.

2. **#75's counter — fix it, or let #22 absorb it?** The history-accumulation half should be fixed
   regardless. If #22 is imminent, fixing only that and letting #22 own counting is defensible; if
   #22 is far off, the counter is your only spend guard and is currently wrong.

3. **#76 — scope the retention window, stop passing the text, or encrypt the argument?** The middle
   option changes the "never persisted" story rather than fixing it, which is arguably more honest
   and would give #66 (stranded in-flight downloads) real server-side state to reconstruct from.
   That makes it a design decision, not a privacy patch.

4. **#59's retention window.** Its own "do not improvise" section says the number is yours. Still
   unanswered, and #76 adds a second window to pick (how long a failed job's arguments may sit).

5. **Is #20 (read-only code-review subagent) still wanted?** Filed 2026-07-30, before
   `/code-review` shipped as a built-in. `.claude/agents/` does not exist. May be obsolete rather
   than pending — your call, since I don't know what you want beyond the built-in.

6. **`config.hosts` is unset** (`production.rb:80-83`). Folded into #48 rather than filed, since
   whether it matters depends on what fronts the app. Worth deciding deliberately rather than by
   omission.

---

## What I could not review

Blind spots, stated plainly.

- **Anything requiring execution.** Docker was not exercised: I did not run `bin/rails test`,
  `bin/rubocop`, `bin/brakeman`, or `bin/importmap audit`. So I cannot confirm the suite passes at
  `c93dbba`, and the SimpleCov number (`minimum_coverage 90`, baseline 95.42%) is quoted from
  `test/test_helper.rb`, not measured. The one thing I did execute was standalone Prawn, outside
  Rails, to reproduce #74.
- **Runtime behaviour of Solid Queue, Solid Cache, and Solid Cable.** All conclusions come from
  reading gem source and schema files. Inferred findings 1–3 are all of this shape.
- **A real deploy.** No `config/deploy.yml` exists, so #48's gaps are derived from configuration,
  not from a failed deploy. Whatever actually breaks first may not be on my list.
- **LLM output quality.** I never called the Anthropic API. Extraction accuracy, rewrite quality,
  `FidelityCheck`'s real-world false-positive rate on PDFs (which `Resume::Extractors::Llm`'s own
  header comment warns about), and inferred finding 4 are all unexamined.
- **Browser and JavaScript behaviour.** I read `download_status_controller.js` and
  `sync_controller.js` and nothing else. No page was loaded. The Turbo Stream claims in #65/#66 are
  taken at face value from those issues, not re-verified.
- **The PDF template's actual ATS-friendliness.** #14 covered this; I did not revisit it, and #74's
  fix may disturb it.
- **Authentication.** ADR-0007 records `owner_token` as a placeholder for real auth. There is no
  `User` model and no open issue for building auth. I did not file one, because I cannot tell
  whether that is an oversight or a deliberate deferral until the product is further along — but it
  is the largest single thing on the roadmap with no issue behind it, and #59's PII retention
  problem gets materially worse the moment records become long-lived.
- **`Comparison`, `MatchScore`, `FidelityCheck`, and the extractors** were read for LLM/PII call
  sites only, not reviewed for correctness. `MatchScore::WEIGHTS` is documented as an untuned
  heuristic (commit `6c2ee62`) and I did not evaluate it.
- **Style and refactoring** — excluded by scope, deliberately.
