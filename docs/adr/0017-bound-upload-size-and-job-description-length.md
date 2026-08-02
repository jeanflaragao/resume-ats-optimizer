# ADR-0017: Bound upload size and job description length

## Status
Accepted

## Context

Two request inputs were unbounded before issue #69: `params[:file]` on `ResumesController#create`
(inspected only for its extension, never its byte size) and `job_description_text`, accepted by
`JobDescriptionsController`, `PreviewsController`, and `DownloadsController` with no length check.

Both are cost and reliability risks specific to an LLM-backed pipeline, not just generic input
hygiene: `job_description_text` is embedded directly into a `BulletRewriter` prompt **once per
experience** (`Resume::Optimization#optimized_experiences`), so a single large paste against a
resume with several roles multiplies into several large, paid LLM calls. An oversized upload has
the same shape via `Resume::Extractors::Llm`, which sends the file straight to Claude. Beyond
token cost, both risk approaching `claude-sonnet-4-5`'s 200,000-token context ceiling, which fails
the request outright rather than degrading gracefully.

## Decision

Add two named constants (per this repo's "no magic numbers" convention) and check them in the
controller, before any service call, re-rendering with `status: :unprocessable_entity` and a
flash — the same pattern the existing blank-input guards already use:

- `ResumesController::MAX_UPLOAD_BYTES` (10 MB). Real LinkedIn PDF exports and JSON exports are
  well under this; extracted text beyond ~2–3 MB of PDF content already approaches the token
  ceiling, so 10 MB is a firm but generous bound that keeps memory pressure and LLM token usage
  bounded without rejecting any realistic upload. A file-size hint is added to
  `resumes/new.html.erb` so users see the limit before attempting an upload.
- `ApplicationController::MAX_JOB_DESCRIPTION_LENGTH` (20,000 characters), placed on
  `ApplicationController` rather than duplicated across the three controllers that receive
  `job_description_text` — real job postings run 500–2,000 words (~3,000–12,000 chars), so
  20,000 is ~2–3× the largest realistic posting.

No middleware-level (Rack) or model-level bound is used. Rack-level limits produce ungraceful,
hard-to-customize errors; `job_description_text` and the uploaded file are both transient request
params, never persisted model attributes, so a model validation has nothing to attach to.
Controllers are the layer that already owns equivalent blank-input guards, so they're the right
layer for this too.

## Consequences

- Every controller that can trigger a per-experience LLM call now has an upper bound on the
  prompt size that call embeds, independent of `LlmCallGuard`'s daily-call-count cap (which
  bounds *how often* calls happen, not *how large* any single call's input is — the two guards
  are complementary, not redundant).
- The 10 MB / 20,000-char figures are judgment calls sized against `claude-sonnet-4-5`'s context
  window and today's realistic input distribution, not hard technical ceilings — revisit if the
  model changes or real user uploads start approaching either bound.
- Issue #56 also covered rescue handling for LLM/file-parsing failures; that half is documented
  separately in ADR-0016. This ADR covers only the size/length bounds half, implemented first
  (commit `c122c40`, issue #69) and merged ahead of the rescue-handling half (commit `d9ed201`).
