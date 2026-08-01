# ADR-0015: Treat every extracted resume field as personal data; redact all values from log output

## Status
Accepted — supersedes the PII-logging consequence in [ADR-0006](0006-deterministic-llm-separation-and-fidelitycheck.md)

## Context
`Resume::Extractors::Llm#warn_drop` was introduced in issue #11 with `log_value: true` as its
default, meaning every dropped field's raw value was logged via `Rails.logger.warn`. Issue #41
added `email` and `phone` as the only exceptions (`log_value: false`), and ADR-0006 recorded
this as:

> `email`/`phone` field verification logs drops without the raw value — field name/reason only —
> since those two fields are PII, unlike every other verified field.

That rationale does not survive contact with what the other fields actually contain. A
candidate's full name, employer location, professional summary, achievement bullets, company
names, job titles, school names, and skill labels are all personal data by any reasonable
reading. The `log_value: true` default meant any future call site written carelessly would leak
PII. On a public repository (ADR-0008) with Kamal/Docker log retention in production, these
`Rails.logger.warn` lines are STDOUT entries that may be retained indefinitely.

`BulletRewriter`'s own fallback warn line (added in issue #11) logged
`result.unverifiable_tokens.join(', ')` — unsorted and uncapped. In the worst case (a
fully-hallucinated bullet where every token is unverifiable), an order-preserving join of all
tokens is approximately the original prose. This applied equally to `Resume::Extractors::Llm`'s
fidelity-check paths for bullets and summary.

## Decision
1. **`warn_drop` logs field name and reason only.** The `value` positional argument and
   `log_value:` keyword argument are removed entirely. No call site passes a raw value; there is
   no opt-in escape hatch — a new call site written carelessly is safe by default.
2. **Fidelity-check drops (bullets, summary) log a bounded, non-reconstructing token hint**
   via the new `RedactedTokenHint` concern (`app/services/concerns/redacted_token_hint.rb`):
   unverifiable tokens are sorted (removing positional information) and capped at 5 with a
   `(+N more)` overflow marker. This preserves diagnostic utility — you can see which tokens
   failed and approximately how many — without the log being able to reconstruct the original
   text.
3. **`BulletRewriter` follows the same rule.** Its fallback warn line uses `RedactedTokenHint`
   rather than a bare `join`.
4. **`job_description_text` added to `filter_parameters`** in
   `config/initializers/filter_parameter_logging.rb`, so pasted job description text is
   redacted from Rails request logs.

## Alternatives considered
- **Silence the log lines entirely**: rejected — every drop must remain observable for debugging.
  The fix is redaction, not silence.
- **Gate the raw value on `Rails.env.local?`**: rejected — this still requires an explicit
  `log_value: true` opt-in at every call site. A future call site written without that keyword
  would log nothing in production but could still be added carelessly. Removing the parameter
  entirely is strictly safer.
- **Structured logging / log filtering middleware**: out of scope — a separate, wider concern.
  `filter_parameters` already handles the request-parameter layer; `warn_drop` is a service-layer
  log, not a request log.

## Consequences
- All field-drop log lines are `dropped <field> (<reason>)` in production, with an optional
  `[<sorted-capped token list>]` suffix for fidelity-check failures. No raw resume content
  appears in any log environment.
- `RedactedTokenHint` is a shared concern used by both `Resume::Extractors::Llm` and
  `BulletRewriter` — the sort+cap logic lives in one place; a future change to the cap or sort
  order applies to both files automatically.
- The existing `assert_includes log_output, "kubernetes"` test in `BulletRewriterTest` and the
  preview/optimization integration tests that assert on `BulletRewriter`'s fallback log line
  continue to pass — the token list still contains individual tokens (including "kubernetes");
  only ordering and the count cap changed.
- Issue #40 (open, tracking fidelity-check branch coverage in `Resume::Extractors::Llm`) is
  unaffected — the safeguard logic itself did not change, only what the log lines emit.
