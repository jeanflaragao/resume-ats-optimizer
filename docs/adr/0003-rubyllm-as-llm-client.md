# ADR-0003: Use RubyLLM instead of a thin API wrapper (ruby-anthropic) for LLM calls

## Status
Accepted

## Context
Two pipeline stages call the Claude API generatively: job-description requirement extraction
(issue #7) and bullet-point rewriting (issue #9). The product's core promise is that the tool
never invents experience the user doesn't have — issue #11 requires automated tests that assert
"given this input, the output never contains hallucinated content." Proving that requires being
able to inspect exactly what prompt was sent to the model and what it returned, not just the
final parsed result. Issue #1's architecture proposal evaluated the LLM client choice with this
requirement specifically in mind.

## Decision
Use the `RubyLLM` gem rather than `ruby-anthropic` or a hand-rolled HTTP wrapper. RubyLLM
provides a higher-level, Rails-friendly interface — including the ability to persist
prompt/response pairs against ActiveRecord — plus a provider-agnostic interface (Claude used by
default) and structured-output support (`with_schema`) used throughout `Resume::Extractors::Llm`
and `JobDescription::Extractor`.

## Alternatives considered
- **`ruby-anthropic`**: a thin wrapper matching the Anthropic API directly. Fine if the app only
  ever calls Claude and wants minimal abstraction, but it doesn't provide ActiveRecord-backed
  persistence of prompt/response pairs — issue #1's proposal identified this as directly useful
  for issue #11's fidelity tests, which need to inspect what the model was given and returned.
  Rejected on that basis, not on API coverage or ergonomics.
- **Hand-rolled HTTP client against the Anthropic API**: not seriously considered — strictly more
  work than `ruby-anthropic` for less benefit than `RubyLLM`.

## Consequences
- Provider lock-in is reduced (RubyLLM's interface isn't Anthropic-specific), which was
  accepted as a low-cost side benefit rather than a primary driver — the primary driver was the
  prompt/response persistence.
- `config/initializers/ruby_llm.rb` must explicitly `require "ruby_llm/schema"` — the schema DSL
  used by `Resume::ExtractionSchema` and `JobDescription::ExtractionSchema` is not auto-required
  by the base gem.
- Every LLM call site (`Resume::Extractors::Llm`, `BulletRewriter`, `JobDescription::Extractor`,
  `Resume::Optimization`) shares this one client abstraction, which is also what let
  `LlmCallGuard` (a stub/rate-cap safety net, added as a prerequisite to issue #15) wrap a single
  `chat:` default across all of them.
