# Shared word-boundary text matching for the deterministic (non-LLM) safety
# checks in this codebase (Comparison, FidelityCheck). Word-boundary rather
# than plain substring so a short term like "Go" doesn't false-positive
# against "Google" or "Django".
module WordBoundaryMatchable
  # NFC-normalized before comparison (issue #126): an accented character has
  # more than one valid Unicode encoding — precomposed ("ã", one codepoint,
  # NFC) or decomposed ("a" + a combining tilde, two codepoints, NFD) — that
  # render and mean the same thing but are different byte sequences. Claude's
  # API returns NFC; pdftotext (Resume::Extractors::Llm#source_text) emits
  # NFD. Without normalizing both to the same form first, a correctly
  # extracted, correctly spelled accented name never literally matches its
  # own source text. This is not diacritic-insensitive matching — "á" and "a"
  # remain distinct — it only unifies which encoding of the same character
  # is compared, so it permits no new fabrication: two canonically identical
  # strings are recognized as identical, nothing more.
  def word_boundary_match?(term, text)
    return false if term.blank?

    pattern = /(?<![[:alnum:]])#{Regexp.escape(normalize(term))}(?![[:alnum:]])/
    normalize(text).match?(pattern)
  end

  private

  # ascii_only? gates the (relatively expensive) unicode_normalize call
  # behind a fast, linear, non-regex check, skipping it entirely for text
  # with nothing to normalize. Not just an optimization: unicode_normalize's
  # own implementation is regex-based, and calling it unconditionally on a
  # multi-megabyte `text` — source_text from a large upload, checked
  # repeatedly, once per field — hit Ruby's default Regexp.timeout and raised
  # Regexp::TimeoutError, confirmed against MAX_UPLOAD_BYTES-sized ASCII
  # content. Every realistic *accented* document (a resume, tens of KB at
  # most) stays well under any timeout; the size that broke this was
  # deliberately non-representative filler padding, which is exactly what
  # this check is fast on.
  def normalize(value)
    value.ascii_only? ? value.downcase : value.unicode_normalize(:nfc).downcase
  end
end
