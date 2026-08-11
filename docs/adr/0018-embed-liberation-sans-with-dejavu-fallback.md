# ADR-0018: Embed Liberation Sans with a DejaVu Sans fallback, and refuse to render scripts no font covers

## Status
Accepted — refines [ADR-0004](0004-prawn-for-pdf-generation.md)'s "standard fonts" assumption;
the poll-vs-full-polling question that decision 4 deferred is now decided by
[ADR-0037](0037-actioncable-late-subscriber-poll-fallback.md)

## Context
`Resume::Pdf` built its document with a bare `Prawn::Document.new`, so Prawn used its built-in
base-14 AFM fonts. Those are **Windows-1252 only**. Any character outside that set raised
`Prawn::Errors::IncompatibleStringEncoding`, which `Resume::OptimizedPdfJob`'s blanket rescue turned
into *"Something went wrong generating your PDF. Please try again."* (issue #74).

The boundary was never "ASCII vs. not", which is why this survived to production-readiness: `•`,
`—`, `“ ”`, `–` and Latin-1 accents (`é ü ñ`) are all inside Windows-1252 and always worked. What
failed was Polish, Czech, Turkish, Hungarian, Romanian, Cyrillic, Greek, CJK — and `→`, `✓`, `‑`
(U+2011), which `BulletRewriter` can introduce into an otherwise all-ASCII resume, since
`FidelityCheck` gates on new digits and token coverage, not on charset.

The user experience made it worse than a plain bug: the HTML preview rendered the resume perfectly
(no charset limit), so a candidate had every reason to retry a download that could never succeed —
each attempt first spending one Claude call per experience.

## Decision

**1. Embed Liberation Sans as the body face, with DejaVu Sans as a glyph fallback.**

Measured, not assumed (Ruby 3.4.9, `prawn 2.5.0`):

| | Liberation Sans | DejaVu Sans | Noto Sans |
|---|---|---|---|
| Latin-ext, Cyrillic, Greek | yes | yes | yes |
| `‑` U+2011 | **no** | yes | yes |
| `→` | yes | yes | **no** |
| `✓` U+2713 | **no** | yes | **no** |
| body-line width vs AFM Helvetica | **−0.1%** | **+14.9%** | +6.5% |

No single font wins. DejaVu is the only one with complete non-CJK coverage but is **14.9% wider**,
which reflows every resume and can push a one-page document onto a second page — a layout change,
not a font change. Liberation Sans is metric-compatible with Helvetica in both regular and bold
(within 0.11%), so swapping it moves nothing, but it lacks exactly the two glyphs the LLM rewrite
is most likely to introduce. Prawn's `fallback_fonts` resolves this: DejaVu is consulted only for
glyphs Liberation lacks, so it has no effect on width for ordinary text. Verified with `pdffonts`
that both faces embed and that a `✓` inside **bold** text renders.

Liberation Sans is also the conventional resume face — it is metrically Arial, and Liberation 2.x
is the Croscore lineage, so "Liberation Sans" and "Arimo" are the same design, not two candidates.

**2. Raise `Resume::Pdf::UnrenderableCharacterError` for any character no embedded font covers.**

Prawn does **not** raise on a missing glyph. It draws `.notdef` — nothing visible — while the
ToUnicode CMap still extracts the original text. A CJK resume would therefore download
"successfully", show a blank name line, and parse cleanly in an ATS. That is silent corruption of
the one thing a resume must get right, so the renderer refuses the whole document instead.

**3. The error carries a Unicode block name and a count, never the characters or their codepoints.**

Per [ADR-0015](0015-uniform-log-redaction-for-resume-fields.md): for a CJK name the codepoints *are*
the name, so a log line reading `U+5F35 U+5049` leaks precisely what logging the raw string would.
`"2 characters in CJK Unified Ideographs"` is the most specific thing that is safe to emit, and is
what `Resume::OptimizedPdfJob` logs.

**4. A failed job records its reason in `Rails.cache`, not only in a broadcast.**

This ADR introduces a new *permanent* failure mode (decision 2) whose entire value is a clear
message. A broadcast can fire before the page's ActionCable subscription connects and be lost
(issue #72), and `DownloadsController#ready` — the existing fallback for that race — could
previously only observe successes, so a lost failure left the page on "Generating…" forever. The
job now writes `{ resume_id:, error: }` under the same cache key and `#ready` renders it. This is
the minimum that makes decision 2's message actually reach the user; it deliberately does not
change the one-shot-poll design that #72 exists to revisit.

## Alternatives considered
- **Transliterate to Windows-1252** — rejected. Silently printing "Balka" for "Bałka" on someone's
  resume is worse than failing, for a tool whose purpose is representing a person formally. The
  `.notdef` behaviour in decision 2 is the same failure by a different route, which is why it is
  guarded rather than tolerated.
- **DejaVu Sans alone** — rejected on the +14.9% width measurement above.
- **Noto Sans** — rejected: worst coverage of the three (misses both `→` and `✓`) with no
  compensating advantage.
- **Bundle a CJK font now** — rejected, and deferred to its own issue. `NotoSansCJK-Regular.ttc` as
  a Prawn fallback produced a **structurally invalid PDF** (`pdffonts`: *"Missing or empty
  DescendantFonts entry in Type 0 font"*; the CJK face did not appear in the embedded font list at
  all) and inflated the document to **1.3 MB**. That needs its own investigation, not a line in
  this change.
- **`apt-get install fonts-liberation` in the Dockerfile** instead of vendoring — rejected.
  Vendoring keeps rendering byte-identical across dev, CI and production and removes a dependency
  on font packages happening to exist in the CI runner image.

## Consequences
- ADR-0004's "standard fonts" rationale no longer holds literally, and its ATS claim needed
  re-testing rather than assuming. **Measured:** rendering identical ASCII content through AFM and
  all three TTFs and extracting with two independent extractors — `pdf-reader` and poppler's
  `pdftotext` — returns byte-identical text. `pdffonts` reports `uni: yes` (a ToUnicode CMap) on
  every embedded subset, which is the property extraction depends on. Embedding does not hurt ATS
  parsing and strictly helps: content that could not be rendered at all is now extractable.
  *Not* measured, and stated as inference: that commercial parsers (Workday, Taleo) behave like
  poppler. The mechanism is standard and two implementations agree, but this was not tested.
- `vendor/fonts/` adds ~1.6 MB to the repo and image (Liberation Regular + Bold, DejaVu Regular,
  plus both licence texts). Per-PDF cost is a subset of ~25–50 KB.
- Licences permit redistribution: Liberation Sans is **SIL OFL 1.1**, DejaVu is the **Bitstream Vera
  licence** (permissive, MIT-shaped). Both licence texts ship in `vendor/fonts/`. Neither font is
  modified.
- Prawn's fallback always resolves to the *normal* weight, so a `✓` inside a bold header renders
  unbolded. Accepted; DejaVu is registered normal-only because a bold face there would never be
  selected.
- CJK, Japanese, Korean, Hebrew, Arabic and Devanagari resumes now fail with a specific message
  instead of a generic one. They still fail. Real support is tracked separately.
