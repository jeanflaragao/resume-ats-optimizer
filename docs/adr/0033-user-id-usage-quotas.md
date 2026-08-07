# ADR-0033: Key `Usage::Quota`'s subject on the signed-in user, not the session

## Status
Accepted. Supersedes [ADR-0023](0023-per-session-usage-quotas-in-postgres.md).

## Context

ADR-0023 keyed `Usage::Quota`'s subject on `ApplicationController#current_owner_token` — an
opaque per-browser-session token (ADR-0007) — because no `User` model existed yet. It said so
explicitly:

> "When real auth lands, `subject` becomes a user id and nothing else here changes —
> `Usage::Counter#subject_token` is an opaque string by design."

Issue #120 landed mandatory, Google-verified accounts. Issue #121 is that migration: replace
`current_owner_token` with `Current.user.id.to_s` everywhere it's read, including here.

### Verifying ADR-0023's claim before relying on it

Confirmed against `db/schema.rb` before writing any code: `usage_counters.subject_token` is a
plain `string` column, not a `resumes` (or now, `users`) foreign key. Swapping the value it
holds — a session token in, a user id out — is schema-compatible; no column-type migration is
forced by the data itself. The claim holds.

## Decision

**`subject` is `Current.user.id.to_s`**, set by `ApplicationController#enforce_quota!`
(`app/controllers/application_controller.rb`). One call site changes; `Usage::Counter` itself
is untouched.

**`usage_counters.subject_token` stays a plain string column** rather than gaining a dedicated
`user_id` FK column. Issue #121 asked this to be a recorded decision, not a default. Reasoning:

- Nothing in `Usage::Counter` joins against `subject_token` or needs referential integrity from
  it — it is a lookup key for a single-statement UPSERT (`Usage::Counter.consume!`), not a
  relation.
- `Usage::Counter.purge_stale!` already deletes on its own schedule
  (`config/recurring.yml`, `RETAIN_FOR`), independent of any other table's lifecycle. A real FK
  would add nothing there — if anything, it would force deciding an `on_delete` behavior for a
  table that's supposed to outlive individual counters anyway.
- It's the literal "one-line change at each call site" ADR-0023 anticipated. Adding a column
  would be a heavier change for no behavioral gain at this app's scale.

## Consequences

**Closes the specific bypass ADR-0023 documented, though not perfectly.** ADR-0023 said "per-
user" actually meant "per browser session" — a visitor opening an incognito window got a fresh
quota, one keystroke away. With mandatory, Google-verified accounts, a quota now follows a real
person across sessions and devices. It is not unbypassable — nothing stops someone from creating
a second Google account — but it is no longer free in the way clearing cookies was.

**This is what makes #106 solvable, not what solves it.** [#106](https://github.com/jeanflaragao/resume-ats-optimizer/issues/106)
observed that `LlmCallGuard`'s global cap has no caller dimension at all — once it's exhausted,
every subsequent request from every user is refused for the rest of the day, and the per-session
quota (ADR-0023) made this *worse* by forcing an abuser to spread requests across sessions the
global cap can't distinguish. #106's own first listed option, "give the global cap's key a
caller dimension," was previously unbuildable — there was no durable caller dimension to give it.
There now is: `Current.user.id`. **Cross-referenced here explicitly; #106 stays open.** Whether
and how to attach a per-user dimension to `LlmCallGuard`'s cap is its own decision, with its own
tradeoffs (a cap that used to be "one number, one comparison" would need real design), and is out
of scope for this issue.

**Two independent spend guards remain**, unchanged from ADR-0023 — `LlmCallGuard`'s global cap
and `Usage::Quota`'s per-subject quota, still not merged (issue #45).

**No `usage_counters` migration.** Existing rows (all local test data — see #121's own no-deploy
verification) hold session-token strings under the old scheme; nothing reads them across the
change since `Usage::Counter.purge_stale!`'s `RETAIN_FOR` window (7 days) means any row surviving
past deploy is stale on its own terms regardless of what `subject_token` used to mean.
