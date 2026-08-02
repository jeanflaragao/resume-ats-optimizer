# ADR-0016: Named rescue list for domain errors — rescue_from for LLM errors, controller-level rescue for file-parsing errors

## Status
Accepted

## Context

The app's LLM pipeline can fail in several distinct ways, none of which were caught before this
change:

- **File-parsing failures**: `PDF::Reader::MalformedPDFError`, `PDF::Reader::UnsupportedFeatureError`
  (corrupt or encrypted PDF), `Resume::Extractors::JsonMapper::InvalidJsonError` (malformed JSON
  via the regex strategy). These reach the user as 500s from `ResumesController#create`.
- **Daily LLM cap**: `LlmCallGuard::DailyLimitExceededError` — reachable from
  `ResumesController`, `JobDescriptionsController`, and `PreviewsController`.
- **LLM bullet-count mismatch**: `BulletRewriter::MismatchedBulletCountError` — reachable from
  `PreviewsController#create`.
- **LLM API errors**: `RubyLLM::Error` and its subclasses (`UnauthorizedError`, `RateLimitError`,
  `ServerError`, `ServiceUnavailableError`, `OverloadedError`, `ContextLengthExceededError`,
  `BadRequestError`) — reachable wherever an LLM call is made.
- **Network errors**: `Faraday::Error` subclasses (`ConnectionFailed`, `TimeoutError`, etc.) —
  reachable when the Anthropic API host is unreachable; not wrapped by RubyLLM's
  `ErrorMiddleware` (which only runs `on_complete`, not on connection failure).

The job path (`Resume::OptimizedPdfJob`) already had a `rescue StandardError` that broadcasts
`_failed` and re-raises — that shape is preserved. The issue was that its log line included
`e.message`, which may contain API response bodies (see PII concern below).

`DownloadsController#create` does NOT call any LLM in the request cycle — it only enqueues
the job via `perform_later`. It therefore does not need rescue_from entries for LLM errors.
This contradicts the issue's claim that "all four controllers" need rescue handling.

## Decision

Two complementary mechanisms, not one:

### 1. `rescue_from` in `ApplicationController` for cross-cutting LLM errors

`LlmCallGuard::DailyLimitExceededError`, `BulletRewriter::MismatchedBulletCountError`,
`RubyLLM::Error`, and `Faraday::Error` are handled with `rescue_from` because they surface
across three controllers and would require identical rescue clauses copied to each one. Each
handler logs the exception class, sets `flash[:alert]` with a distinct actionable message, and
calls `redirect_back_or_to root_path`. A redirect is used rather than re-rendering because the
handler doesn't have access to the per-controller instance variables (e.g. `@resume`) needed
to safely re-render any specific template.

Three distinct user messages:
- `DailyLimitExceededError` → "We've hit today's processing limit. Please try again tomorrow."
  (distinct: user action is to wait until tomorrow, not retry now)
- `MismatchedBulletCountError` → "We had trouble rewriting your resume bullets. Please try again."
  (distinct: transient LLM behavioral error, retry is immediately reasonable)
- `RubyLLM::Error` / `Faraday::Error` → "The AI service is temporarily unavailable. Please try
  again in a moment." (service-level unavailability, retry after a short wait)

`ActiveRecord::RecordNotFound` is intentionally absent from this list — it must fall through to
Rails' 404 so owner-scoping tests remain correct (see issue #56, ADR-0007).

A broad `rescue_from StandardError` is explicitly rejected: it would swallow
`ActiveRecord::RecordNotFound` and break owner-scoping behavior everywhere.

### 2. Extended rescue clause in `ResumesController#create` for file-parsing errors

`PDF::Reader::MalformedPDFError`, `PDF::Reader::UnsupportedFeatureError`, and
`Resume::Extractors::JsonMapper::InvalidJsonError` are added to the existing rescue clause in
`ResumesController#create` (alongside `ActiveRecord::RecordInvalid` and `UnsupportedFormatError`)
rather than to `rescue_from`. Reason: these exceptions are specific to the file-upload action,
the action already has the correct re-render target (`:new`), and handling them in
`ApplicationController` would couple that class to controller-specific template logic.

Note: `InvalidJsonError` is only raised by the `"regex"` strategy (`JsonMapper`), not by the
default `"llm"` strategy (`Extractors::Llm` reads JSON as raw text). The rescue is defensive
— if the strategy becomes user-configurable in the future, it is already covered.

### 3. `Resume::OptimizedPdfJob` log line fix (PII)

The existing `rescue StandardError` shape is preserved per the issue requirement. The log line
is changed from `"#{e.class}: #{e.message}"` to `"#{e.class}"` only. The job catches any
`StandardError`, so we cannot know at that level whether `e.message` is safe — see PII concern
below.

## PII concern: exception messages

ADR-0015 established that no raw resume field value reaches logs. This PR extends that rule to
exception messages in rescue clauses:

- `PDF::Reader::MalformedPDFError`: messages describe structural parse errors ("PDF malformed,
  expected 'x' but found 'y'"). Binary PDF bytes MAY appear as the 'found' value. Logged: class
  only.
- `PDF::Reader::UnsupportedFeatureError`: messages describe unsupported features ("Encrypted
  PDF"). Safe, but logged as class only for consistency.
- `InvalidJsonError`: message contains the temp file path and parse position. No resume content,
  but path is logged as class only for consistency.
- `LlmCallGuard::DailyLimitExceededError`: "Daily LLM call cap (N) exceeded". Safe — logged as
  class only (the number is not user-supplied content).
- `BulletRewriter::MismatchedBulletCountError`: "Expected N bullets, got M". Safe — logged as
  class only.
- `RubyLLM::Error` and subclasses: `message` is set by `ErrorMiddleware.parse_error` to things
  like "Rate limit exceeded — please wait a moment". The fallback when no parsed message is
  available is `response&.body` — the raw Anthropic API JSON response body. While Anthropic
  error responses typically don't contain user content, `ContextLengthExceededError` responses
  in edge cases may echo token counts or request metadata. **Logged: class + HTTP status when
  present, never message.** HTTP status codes (429, 401, 529) are metadata, not user content —
  they identify three distinct operational problems (rate-limited, bad key, overloaded) that
  would otherwise collapse into one indistinguishable log line.
- `Faraday::Error`: `response_status` returns the HTTP status if a response was received, or
  nil for connection-level failures (`ConnectionFailed`, `TimeoutError`) that never received an
  HTTP response. **Logged: class + status when present, no suffix when nil** (rather than
  emitting a misleading "(HTTP )").
- `Resume::OptimizedPdfJob` (any `StandardError`): class only — the job cannot narrow the type
  at the rescue site, so it cannot know whether `e.message` is safe.

## Consequences

- Each distinct failure class produces a distinct, actionable user-facing message.
- No stack trace or exception class name appears in any user-facing response body.
- Exception classes are logged at warn (recoverable, expected operational events:
  `DailyLimitExceededError`, `MismatchedBulletCountError`, `MalformedPDFError`) or error
  (service-level failures: `RubyLLM::Error`, `Faraday::Error`, job failures).
- `ActiveRecord::RecordNotFound` continues to fall through to Rails' 404.
- The rescue list is explicit and named. Adding a new domain exception requires an explicit
  entry — it cannot be swallowed silently.
- `InvalidJsonError` is defensively covered even though it is currently unreachable via the
  default LLM strategy. This is intentional: the class exists, the issue calls it out, and
  covering it now costs nothing.
