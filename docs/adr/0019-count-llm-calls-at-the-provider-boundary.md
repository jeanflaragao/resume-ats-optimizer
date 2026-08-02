# ADR-0019: Count LLM calls at the provider-call boundary, and fail closed when the count is unavailable

## Status
Accepted

## Context

`LlmCallGuard` is the process-wide stopgap that keeps accidental Anthropic spend bounded until
issue #22's per-user rate limiting lands. Before issue #75 it counted the wrong thing.

`LlmCallGuard.chat` both incremented the daily counter and returned a live `RubyLLM::Chat`. That
conflates two events that are not 1:1. `Resume::Optimization` resolves `chat:` once, as a default
argument (`resume/optimization.rb:11`), then threads that single object into one
`BulletRewriter.call` per experience — and `BulletRewriter` issues one request per invocation
(`bullet_rewriter.rb:46`). Measured at the provider boundary on a 5-experience resume:

| Flow | real provider requests | counter increments |
|---|---|---|
| `JobDescription::Extractor` | 1 | 1 |
| `Resume::Optimization` | 5 | 1 |
| Preview (JD extract + optimize) | 6 | 2 |
| Download job | 5 | 1 |

So `MAX_LLM_CALLS_PER_DAY` permitted roughly `10 × average_experience_count` requests per day, not
10. `Resume::Optimization` was the only fan-out site; the other two call sites happened to be 1:1
and so happened to count correctly.

The same shared object carried a second defect. `RubyLLM::Chat` is stateful: `#ask` appends the
user message and the assistant reply to `@messages` (`ruby_llm/chat.rb:40`, `:167`, `:229`) and
re-sends the whole array. Measured across four experiences, `messages` on request *k* was `2k−1`:

```
provider.complete call 1: messages=1  total_content_chars=1619
provider.complete call 2: messages=3  total_content_chars=3300
provider.complete call 3: messages=5  total_content_chars=4981
provider.complete call 4: messages=7  total_content_chars=6662
```

Input tokens grew roughly quadratically in experience count, on top of the full job description
each prompt already re-embeds independently (ADR-0017), on a path run twice per user flow.

A third problem was latent in the same method. `Rails.cache.increment` returns `nil` when the store
cannot answer, and `nil.to_i` is `0`, which always passes the cap comparison.

## Decision

**Count at the provider-call boundary.** `LlmCallGuard.chat` returns a stateless `MeteredChat`
handle rather than a live chat. Resolving a chat is free; each `#ask` records exactly one call and
issues it against a **freshly constructed** `RubyLLM::Chat`.

This keeps every existing `chat:` seam intact — `Resume::Optimization`, `BulletRewriter`,
`Resume::Import` and every `FakeChat` in the test suite are unchanged. The threading that was the
bug becomes correct rather than being removed.

`MeteredChat#with_schema` returns a **new** handle rather than mutating `self`, so a handle shared
across experiences or across Solid Queue threads cannot leak one call's schema into the next.

**Count before the request, not after.** This overcounts when a request fails in transit and
returns no billable completion. Counting only successes could not gate at all — by the time a
response arrives the spend has happened. Overcounting costs a user some headroom; undercounting
costs money.

One `ask` is one billable completion, not one HTTP attempt: RubyLLM wraps the call in Faraday retry
(`ruby_llm/connection.rb:106`, `max: 3`) for rate-limit, 5xx and timeout conditions, and those
attempts return no completion to bill.

**Check the whole flow before its first billable request.** The number of requests
`Resume::Optimization` will make is knowable in advance — experiences with non-empty bullets, since
`BulletRewriter` returns early on an empty list (`bullet_rewriter.rb:44`) before the `.ask` at
`:46`, and `experiences.bullets` is `default: [], null: false`. `LlmCallGuard.ensure_headroom!(n)`
is therefore called at the top of `#optimized_experiences`, and a resume that cannot fit in today's
remaining budget is refused before anything is spent.

The pre-flight check is **read-only and does not reserve**. Reserving would need a refund path on
every failure mode, and sizing a per-flow reservation is #22's job. The per-request check inside
`#ask` remains as the backstop that makes the cap hold when two concurrent flows both pass
pre-flight, or when a predicted count is wrong.

**Fail closed when the counter cannot be verified.** A working store always answers `increment`
with a number, so `nil` means the count could not be established. `record_call!` now raises
`LlmCallGuard::BudgetUnavailableError` — deliberately **not** a `DailyLimitExceededError` subclass,
because "the budget is spent" and "we cannot see the budget" need different advice to the user.

## Consequences

- **The cap is now a cap.** It is never exceeded, and in the common case a flow that cannot fit
  spends nothing rather than paying for every rewrite up to the one that trips it.
- **Per-request input tokens are flat.** Nothing the model sees was silently changed: no call site
  sets system instructions (`with_instructions` appears nowhere in `app/`), and the user prompt is
  byte-identical per request. Only the accumulated prior turns are gone.
- **A cache outage now blocks resume generation** rather than uncapping spend. This is the same
  answer that counting-before-the-request gives to the same question; a guard that failed open on a
  missing counter while failing safe on a failed request would not be a guard. The transient case
  is surfaced as "try again in a moment", distinct from the daily cap's "try again tomorrow", in
  both `ApplicationController` (ADR-0016's rescue list) and `Resume::OptimizedPdfJob`.
- **A daily-cap breach inside the PDF job is now named.** ADR-0016's `rescue_from` handlers live in
  `ApplicationController` and never reach a job, so a cap breach previously rendered the generic
  "Please try again" — advice that was wrong in both directions. The job gets its own clause.
- **The counter is only as good as its store.** Solid Cache's `increment` is atomic under
  concurrent Solid Queue workers (`SolidCache::Entry.lock_and_write` is a `SELECT … FOR UPDATE`
  inside a transaction), so per-request counting is safe across workers. It remains a single global
  counter with no per-user dimension — issue #45 and issue #77 still stand, and #22 still owns
  replacing it.
- **Tests depend on a cache swap that must not be removed.** Under test env's `:null_store` every
  cap test would now raise `BudgetUnavailableError` rather than silently pass, which is an
  improvement, but `LlmCallGuardTest` still swaps in a `MemoryStore` to exercise real counting. The
  swap is documented as load-bearing in the test file, on the same reasoning as ADR-0013's
  forgery-protection toggle.
