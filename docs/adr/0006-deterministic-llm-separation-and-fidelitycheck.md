# ADR-0006: Keep comparison/scoring logic strictly deterministic and verify all LLM output with FidelityCheck

## Status
Accepted

## Context
This product's core promise is that it never presents the user with a resume claiming
skills or experience they don't actually have — issue #11 ("Add safeguard tests against
hallucinated experience") exists specifically to protect that promise. Two categories of logic
touch resume data: matching/scoring (does the resume already contain a required skill?) and
generative rewriting (rephrase a bullet to use the job posting's terminology). These have very
different risk profiles — matching is a factual yes/no question with one correct answer,
rewriting is inherently generative and therefore capable of introducing content that was never
in the source.

## Decision
1. **Architectural rule**: `Comparison` and `MatchScore` (issues #8, #10) must remain
   completely LLM-free — plain, deterministic Ruby service objects. This was decided as part of
   issue #1's roadmap mapping ("comparison and scoring logic as plain Ruby service objects, not
   LLM output, so they stay deterministic and testable") and is now an explicit rule in this
   repo's Architecture Conventions.
2. **Verification safeguard for the two LLM call sites that remain** (bullet rewriting via
   `BulletRewriter`, extraction via `Resume::Extractors::Llm`): a deterministic (non-LLM)
   `FidelityCheck` service, added in issue #11 / PR #36. `FidelityCheck.call(candidate_text:,
   source_text:, min_token_coverage:)` fails immediately on any digit sequence in the candidate
   absent from the source (zero tolerance — a new number is the strongest hallucination signal,
   and legitimate paraphrase essentially never introduces one), and otherwise requires a
   caller-supplied ratio of significant (non-stopword) words to be traceable back to the source
   text. `BulletRewriter` checks each rewritten bullet against *only* its own original bullet —
   deliberately not the job description — since grounding against the JD would let a
   hallucinated achievement phrased in the JD's own vocabulary pass unverified.
   `Resume::Extractors::Llm` separately verifies every extracted field against the source file's
   own text via the shared `WordBoundaryMatchable` concern (exact, word-boundary matching — the
   right tool for short structural fields like company/title, where a token-coverage ratio would
   be order-blind and could false-pass a fabricated "Acme Corp").

## Alternatives considered
- **LLM-as-judge verification** (asking a second LLM call to check the first's output for
  hallucination): rejected — it's still LLM output judging LLM output, doesn't eliminate the
  hallucination risk it's meant to catch, and this repo's Architecture Conventions explicitly
  forbid LLM calls inside what are meant to be deterministic safety checks.
  `FidelityCheck`/`WordBoundaryMatchable` are deliberately non-LLM for this reason.
- **Exact-match verification everywhere** (no paraphrase tolerance at all): considered and
  rejected specifically for free-text fields (rewritten bullets, extracted bullets/summary) —
  legitimate rewording/condensing is expected there, so exact match would reject correct output
  constantly. Token-coverage ratio was chosen instead, reserving exact/word-boundary matching for
  short structural fields where paraphrase isn't expected.
- **Raising on any fidelity failure**: rejected for `BulletRewriter` specifically — a failing
  rewritten bullet falls back to its original wording and logs a warning, since a safe 1:1
  recovery always exists. (A *different* `BulletRewriter` failure mode — the response not coming
  back 1:1 with the input bullets — does raise, `MismatchedBulletCountError`, since there's no
  safe recovery there.) `Resume::Extractors::Llm` similarly drops/nulls unverified fields rather
  than failing the whole import, except that an unverified `company`/`title`/`school` drops the
  whole experience/education entry, since nulling those would still fail `Resume::Import`'s
  `create!` validations and roll back the entire resume anyway.

## Consequences
- Every LLM call site in the app (`Resume::Extractors::Llm`, `BulletRewriter`,
  `JobDescription::Extractor`, `Resume::Optimization`) is either output that flows through a
  `FidelityCheck`/`WordBoundaryMatchable` gate, or (for `JobDescription::Extractor`, which
  extracts requirements from a job posting, not from the user's own claimed experience) not
  subject to the same hallucination risk since there's no "invented experience" possible there.
- `email`/`phone` field verification (added in issue #41) logs drops without the raw value —
  field name/reason only — since those two fields are PII, unlike every other verified field.
- Known, accepted limitation: `FidelityCheck` is lexical, not semantic — it can't catch
  hallucination that introduces no new lexical tokens (e.g. reinterpreting an existing number's
  meaning without changing the digits). This trade-off was accepted deliberately in favor of
  staying deterministic and testable rather than reaching for an LLM judge.
- Issue #40 (open) tracks adding missing fidelity-check branch coverage in
  `Resume::Extractors::Llm` — the safeguard's own test suite is not yet considered fully
  complete.
