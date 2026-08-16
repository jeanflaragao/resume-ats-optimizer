# ADR-0040: Give stub-mode extraction/rewrite drops a distinct reason from real fidelity rejections

## Status
Accepted

## Context

Issue #125: with `ENABLE_REAL_LLM_CALLS` unset — the documented local default (ADR-0020's stopgap,
not this ADR's concern) — `LlmCallGuard::StubChat`'s canned values ("Stub Candidate",
"stub@example.com", "Example Corp"/"Stub Engineer", and the summary's `STUB_LABEL`) never appear
verbatim in a real uploaded resume. `Resume::Extractors::Llm`'s verbatim/fidelity checks — which
exist specifically to catch real LLM hallucination — drop them the same way they'd drop a genuine
fabrication, and `resumes/show.html.erb` renders the generic reason ("didn't appear in your
original document") with nothing distinguishing "this was never real" from "the real extraction
hallucinated." `BulletRewriter`'s stub echo (`"#{STUB_LABEL} #{bullet}"`) fails its own fidelity
check against the original bullet the same way, falling back with a "kept original wording"
caption in the preview — again indistinguishable from a real fallback.

Confirmed before writing this ADR: `STUB_LABEL` never survives to any log line (ADR-0015 forbids
logging raw field values — `warn_drop` logs field name and reason only) or rendered page on a
non-colluding upload. It is swallowed by the same fidelity mechanism meant to catch
hallucinations, which is the actual root cause, not merely "the demo-mode banner is off in dev."
`LlmCallGuard.stub_mode_banner?` staying silent in development (`llm_call_guard.rb:99-101`) is a
separate, working-as-intended decision this ADR does not revisit — the issue author's own text
prefers a precise per-drop explanation over a global banner, and that is what this ADR builds.

Cost: a full diagnostic session — two real CVs analyzed, byte-level codepoint dumps, two live API
runs — before the cause turned out to be an unset env var.

## Decision

**Replace the reason string on a stub-caused drop/fallback with one canonical message, checked at
two different granularities depending on the call site — not the same signal at both.**

1. **`Resume::Extractors::Llm`: check the chat instance actually received (`chat.is_a?(LlmCallGuard::
   StubChat)`), not the global `LlmCallGuard.stub_mode?`.** `test/services/resume/extractors/
   llm_test.rb` injects a hand-rolled `FakeChat` (not `StubChat`) to simulate real hallucinated LLM
   output, and asserts the field-specific/count-based reason wording on those simulated drops.
   `ENABLE_REAL_LLM_CALLS` is unset in the test environment regardless of which fake is injected, so
   checking the global flag there would mislabel every one of those unit tests' simulated-real
   fabrications as "stub mode." The per-instance check is also simply the more correct question: it
   answers "did a real extraction actually run for *this* call," which is what the reason text
   claims. Every reason string this class can produce now routes through a `verification_reason
   (default)` helper that substitutes `STUB_MODE_REASON = "no real extraction ran (stub mode)"` when
   `stub_extraction?` is true.

2. **`app/views/previews/show.html.erb`: check the global `LlmCallGuard.stub_mode?`.** The view is
   only ever reached through the real `LlmCallGuard.chat(subject:)` factory — no integration test
   injects a fake chat at the controller layer — so the global flag and the actual chat class are
   always in lockstep there. This avoids adding a field to `BulletRewriter::Rewrite` (a
   `Data.define`), which would force every exact-equality `assert_equal BulletRewriter::Rewrite.new
   (...)` assertion across `bullet_rewriter_test.rb` and `optimization_test.rb` to be rewritten for
   no benefit — those tests never render the view.

3. **Only the `reason` string changes; `kind`/`field` do not.** `PendingItemsController` matches a
   fillable pending item by `(scope, field, position)` only (`pending_items_controller.rb:28-29`),
   never by `reason` — so this is a display-only change. A stub-mode-dropped name is exactly as
   fillable as a real-fidelity-dropped name; the user still needs to type it in either way.

Both checks resolve to the same fact in production and development: whenever `LlmCallGuard.
enabled?` is false, `.chat` *always* returns `StubChat`. They only diverge in tests that
deliberately bypass the `LlmCallGuard.chat` factory to simulate a real response — which is exactly
why the extractor, the one class with such tests, needs the more precise per-instance form.

## Alternatives considered

- **Use `LlmCallGuard.stub_mode?` uniformly at every call site.** Rejected for
  `Resume::Extractors::Llm` specifically: it breaks `llm_test.rb`'s `FakeChat`-based fidelity-drop
  tests, which rely on the test environment's `ENABLE_REAL_LLM_CALLS` being unset while still
  simulating a *non-stub* hallucinated response. Kept for the preview view, where no such test
  exists and the simpler, already-established predicate (`_stub_mode_banner.html.erb` already calls
  it directly) is sufficient and correct.
- **Thread a `stub:` flag through `BulletRewriter::Rewrite` and `Resume::Optimization::Experience`
  so the view has a precise per-bullet signal instead of the global flag.** Rejected: `Rewrite` is a
  `Data.define`, and adding a field breaks every existing exact-equality assertion against it across
  two test files for a distinction the view never actually needs (see point 2 above — the global
  flag is already exact there).
- **Surface the `stub_mode_banner?` in development instead of (or in addition to) reworking
  wording.** Rejected — this is the issue's own explicit preference: a per-drop, precise
  explanation beats a page-wide banner, and reopening ADR-0020's dev-silence decision was not judged
  necessary once the wording itself is fixed at the source.

## Consequences

- A stub-mode dropped field now reads "no real extraction ran (stub mode)" instead of a
  fidelity-specific reason; a stub-mode bullet fallback now reads "no real rewrite ran (stub mode)"
  instead of "kept original wording" — both readable at a glance without knowing to grep source for
  `StubChat`.
- `test/integration/pending_item_fills_test.rb` and `test/integration/resume_previews_test.rb`
  update their asserted wording (and, for the former, its documenting comment, which previously
  claimed the stub-triggered drop reads "the same way a real fabrication would" — that claim is now
  false by design).
- `test/services/resume/extractors/llm_test.rb`'s `FakeChat`-driven fidelity tests are unaffected
  by construction, and a new test injecting `LlmCallGuard::StubChat` directly proves the new wording
  fires for an actual stub.
