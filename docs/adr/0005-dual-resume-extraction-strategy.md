# ADR-0005: Support two selectable resume-extraction strategies (LLM + deterministic)

## Status
Accepted

## Context
Issue #4 required parsing a LinkedIn data export (PDF or JSON) into the structured resume
schema defined in issue #5. LinkedIn's PDF export has a fairly consistent layout, which makes
pattern-based parsing viable, but "fairly consistent" is not "guaranteed" — a purely
regex/heuristic parser risks silent misextraction on layout variants it wasn't tuned against. At
the same time, this project's core anti-hallucination stance (see ADR-0006) makes an LLM-only
extraction pipeline something the team wanted a free, deterministic, fully-unit-testable
fallback for.

## Decision
Implement `Resume::Import` with two selectable extraction strategies behind one entry point
(`Resume::Import.call(file:, strategy: "llm" | "regex")`):
- **LLM extractor** (`Resume::Extractors::Llm`): sends the file directly to Claude via RubyLLM's
  structured output (`with_schema`), robust to arbitrary resume layouts. Works unmodified for
  both PDF and JSON.
- **Deterministic extractor** (`Resume::Extractors::PdfRegex` for PDF, `Resume::Extractors::JsonMapper`
  for JSON): `pdf-reader` text extraction plus a small state machine over section headers/date
  ranges/bullet-prefixed lines for PDF; direct JSON mapping for JSON. Free, fully unit-testable,
  but only reliable on LinkedIn's fairly consistent export layout.

Both extractors return the same normalized hash shape (`Resume::ExtractionSchema`), so
`Resume::Import` and everything downstream is indifferent to which one ran; `resumes.source`
records which extractor produced a given resume.

## Alternatives considered
- **LLM-only extraction**: simpler (one code path), and was the original scope framing in issue
  #1's roadmap mapping. Rejected in favor of also having a deterministic path: cost-free,
  network-independent, and fully testable without any LLM dependency, which matters given this
  project's broader stance that LLM output must be treated as untrusted (ADR-0006) — issue #11
  later added `pdf-reader`-based verification to the LLM extractor precisely because LLM-only
  extraction alone wasn't trusted.
- **Deterministic-only extraction**: would be free and fast, but PDF layout parsing is
  fundamentally best-effort against LinkedIn's specific export format and would fail badly on
  any other resume source or layout drift. Rejected as the sole strategy; kept as a fallback
  strategy instead.

## Consequences
- Two extractor implementations must be kept in sync with `Resume::ExtractionSchema`'s shape,
  and the regex extractor is documented as best-effort (its known reliability ceiling is
  accepted, not treated as a bug to eventually fix to LLM parity).
- The regex extractor cannot extract `name`/`email`/`phone` (added later in issue #41) — those
  fields stay `nil` for the `"regex"` strategy, consistent with its lesser-fidelity character
  elsewhere, rather than adding new heuristics to match the LLM path's coverage.
- `ResumesController#create` (issue #15) hardcodes `strategy: "llm"` and does not expose it as a
  user-facing form field, since there's no basis for an end user to meaningfully choose between
  the two — the deterministic path exists for cost/testability, not as a user-facing option.
