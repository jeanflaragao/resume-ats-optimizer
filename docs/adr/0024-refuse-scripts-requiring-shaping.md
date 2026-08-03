# ADR-0024: Add a CJK fallback font, and refuse scripts requiring text shaping even when glyphs exist

## Status
Accepted — extends [ADR-0018](0018-embed-liberation-sans-with-dejavu-fallback.md)

## Context

Issue #81 filed CJK, Hebrew, Arabic, and Devanagari as one bug — `Resume::Pdf` refuses all four
— but they are three distinct problems that only look the same from the outside:

1. **CJK has no glyph in any embedded font.** A real coverage gap, fixable by adding a font.
2. **Arabic has full glyph coverage in DejaVu Sans and passes the guard today**, but Prawn's
   flow layout draws it in logical (typed) order, left to right, with no contextual letter
   joining. The guard's cmap check has no way to know this, so it lets Arabic through to render
   silently wrong instead of refusing it.
3. **Devanagari has neither.** No glyph, and even with one it would need vowel reordering and
   conjunct ligatures Prawn cannot produce.

Issue #81 itself independently flagged "Arabic and Hebrew additionally need RTL support... those
are plausibly a separate, much larger problem than CJK" as an open question, without resolving
it — this ADR resolves it.

### Hebrew was assumed fine and was not

Hebrew has full cmap coverage in DejaVu Sans and was not in issue #81's list of scripts that
still fail. Verified before writing this ADR, rather than trusting that: rendered `"שלום"`
through `Resume::Pdf`, rasterized the output, and inspected it. The glyphs draw in logical order
left to right — correct for Latin, backwards for Hebrew, which is read right to left. The word is
not merely ugly, it is a different word. cmap coverage said nothing about this, because coverage
answers "do we have a glyph for this character," not "do we draw it in the right place." Hebrew
joins Arabic and Devanagari as a refusal for exactly this reason.

### The CJK fix is not "add a font" — it needed reverse-engineering why the obvious fix fails

Issue #81 documented that embedding `NotoSansCJK-Regular.ttc` (Adobe's official distribution)
produced a structurally invalid PDF: `pdffonts` reported `Missing or empty DescendantFonts entry
in Type 0 font`, and the CJK face never appeared in the embedded font list at all, despite the
document inflating to 1.3 MB. Issue #81's own "INFERRED" section guessed the `.ttc` **collection**
container was the likely culprit and suggested trying a single-face `.otf`/`.ttf` build instead.

That guess was wrong, and this ADR corrects it. Downloading the single-region, standalone
`NotoSansCJKsc-Regular.otf` (not a collection — one face, one file, from the same official
`notofonts/noto-cjk` `Sans2.004` release) and embedding it reproduces the **identical** failure:
`Missing or empty DescendantFonts entry in Type 0 font`, and a near-identical 1.32 MB output.
Inspecting the file directly (`sfnt` tag `OTTO`, a `CFF ` table, no `glyf`/`loca`) shows why: Noto
Sans CJK's official distribution is **CFF-outline OpenType** (PostScript-style curves), not
TrueType. Prawn/TTFunk's Type0/CID embedding path — the one used once a resume needs more distinct
glyphs than fit in a simple font — does not correctly emit `DescendantFonts` for a CFF-flavored
source font, regardless of whether it arrives in a `.ttc` collection or standalone. The container
format was never the problem.

**Fix: convert the official font to TrueType (glyf) outlines before vendoring it.** Used
`fonttools`' `otf2ttf` (which wraps `cu2qu`'s cubic-to-quadratic curve conversion) against the
official `NotoSansCJKsc-Regular.otf`. Verified the result (`sfnt` tag `\x00\x01\x00\x00`, standard
TrueType) embeds correctly: rendering a resume with Han ideographs, Hiragana, Katakana, and Hangul
together produces a PDF with no `pdffonts` errors, the CJK face listed as `TrueType`/`emb: yes`/
`uni: yes`, correct text extraction, and — checked by rasterizing the page and inspecting it
directly, not just extracting text, per issue #81's own warning that extraction succeeding is not
proof of visible rendering — the glyphs are genuinely visible, not blank `.notdef`.

Conversion cost: 16,437,364 bytes (CFF, official) → 19,941,740 bytes (converted TrueType), a ~21%
size increase — glyf outlines are typically larger than the equivalent CFF outlines for the same
glyph set. Conversion took ~58s for the full ~65,000-glyph font (one-time, at vendoring time —
this repository ships the converted binary, not the conversion step).

## Decision

**1. Vendor `NotoSansCJKsc-Regular.ttf`** (the TrueType-converted Simplified Chinese Noto Sans CJK
face) as a third `fallback_fonts` entry, after `DejaVuSans`, in `app/services/resume/pdf.rb`.
Simplified Chinese was chosen among the single-region variants (SC/TC/JP/KR/HK — the only shape
this font is distributed in without the broken collection format) for having the largest
CJK-reading population, with no product telemetry to base the choice on otherwise. This trades
off correctness for other regions: a Japanese or Korean name renders with SC's default Han glyph
forms, which can be the visually "wrong" regional variant of a shared Unihan codepoint — the same
category of imperfection as picking any one region, not specific to SC. Registered normal-only,
same rationale as `DejaVuSans` in ADR-0018: Prawn's fallback always resolves to normal weight.

**2. `SHAPING_REQUIRED_BLOCKS = %w[Hebrew Arabic Devanagari]`, checked before the missing-glyph
check.** A character in one of these blocks is refused regardless of cmap coverage — this is what
makes Arabic (full coverage) and Devanagari (no coverage, but would still need refusing even with
some) both land in the same bucket, and why Hebrew joins them despite having always had coverage.
`Resume::Pdf::UnrenderableCharacterError` now distinguishes the two reasons
(`missing_glyph_blocks` vs. `shaping_required_blocks`) and its messages read differently — "cannot
be rendered" vs. "require text shaping we do not support" — because they are different facts: one
is "we don't have this yet," the other is "we have this and are choosing not to draw it wrong."

**3. This generalizes ADR-0018's "do not transliterate" into "do not deform."** ADR-0018 refused
to draw `.notdef` blanks because that silently prints a different name than the one typed.
Drawing Hebrew/Arabic/Devanagari without shaping is the same failure by a different route: real
glyphs, wrong result, still a different name. A future reader who checks cmap coverage for Hebrew
or Arabic will find it present and may reasonably wonder why the guard still refuses — this ADR,
and the empirical renders in it, are the answer: coverage was never the blocker for those three.

**4. Real support is tracked separately, not attempted here.** Correct rendering needs a bidi
algorithm (Unicode UAX #9) for run ordering and, for Arabic, contextual glyph substitution — both
outside what Prawn's flow-layout renderer does. See
[issue #103](https://github.com/jeanflaragao/resume-ats-optimizer/issues/103).

## Alternatives considered
- **Leave Hebrew alone since issue #81 didn't list it as broken** — rejected once rendering it
  and looking at the output showed it was, in fact, broken. Shipping a known-wrong-order name
  after finding this would be worse than not having looked.
- **Debug Prawn/TTFunk's Type0 embedding to support CFF-outline fonts directly**, avoiding the
  conversion step and its size cost — rejected as materially larger scope than this issue: it
  means patching a third-party gem's font-embedding internals, not vendoring a different file.
  Left as a possible angle for a future CJK-font issue if the ~21% size cost of conversion turns
  out to matter in practice.
- **A different, already-TrueType CJK font (not Noto)** — not pursued. Noto is the same font
  family ADR-0018 already vendors two members of (Liberation and DejaVu are unrelated designs,
  but Noto was issue #81's own starting point and is the most widely-verified permissively-licensed
  CJK option); introducing a second CJK font family's provenance and license into `vendor/fonts/`
  for this issue was not judged worth it next to a one-time, verifiable conversion of the font
  already being evaluated.

## Consequences
- `vendor/fonts/` grows by ~19 MB (the converted TrueType file) plus its OFL 1.1 license text
  (`LICENSE-NotoSansCJK.txt`, copied from the official release — the license terms are unchanged
  by the format conversion, which OFL 1.1 explicitly permits).
- Per-PDF cost stays small: Prawn subsets embedded fonts, and a real CJK resume (name, a
  multi-sentence summary, and several two-to-four-character skill labels, spanning Han, Hiragana,
  Katakana, and Hangul) measured at ~43 KB — in the same range as ADR-0018's ~25–50 KB figure for
  Latin/Cyrillic, not the 1.3 MB the broken CFF embedding produced.
- Hebrew, Arabic, and Devanagari resumes still fail — deliberately, and now for a documented
  reason distinguishable from a plain missing-glyph gap. Real support is
  [issue #103](https://github.com/jeanflaragao/resume-ats-optimizer/issues/103), not this ADR.
- Issue #81's own "likely culprit" guess (the `.ttc` container) is superseded by this ADR's
  finding (the CFF outline format). Recorded here rather than edited into #81, per this
  repository's ADR convention of not rewriting history — see the closing comment on #81 for the
  pointer.
