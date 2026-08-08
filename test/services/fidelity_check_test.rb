require "test_helper"

class FidelityCheckTest < ActiveSupport::TestCase
  test "passes when candidate is identical to source" do
    text = "Improved system reliability significantly"

    result = FidelityCheck.call(candidate_text: text, source_text: text)

    assert result.passed
    assert_empty result.unverifiable_tokens
  end

  test "passes for a legitimate synonym rewording that adds no new facts" do
    result = FidelityCheck.call(
      candidate_text: "Delivered a platform rewrite for backend services",
      source_text: "Shipped a platform rewrite for backend services"
    )

    assert result.passed
  end

  test "fails when candidate introduces a number absent from source" do
    result = FidelityCheck.call(candidate_text: "led a team of 12", source_text: "led a team")

    assert_not result.passed
    assert_includes result.unverifiable_tokens, "12"
  end

  test "passes when a number is only reformatted, not new" do
    percent_result = FidelityCheck.call(
      candidate_text: "achieved a 40% improvement",
      source_text: "achieved a 40 percent improvement"
    )
    thousands_result = FidelityCheck.call(
      candidate_text: "$1,200 raised",
      source_text: "1200 raised"
    )

    assert percent_result.passed
    assert thousands_result.passed
  end

  test "fails when candidate introduces a new non-numeric clause" do
    result = FidelityCheck.call(
      candidate_text: "wrote documentation for the api and led the security audit",
      source_text: "wrote documentation for the api"
    )

    assert_not result.passed
  end

  test "passes trivially for an empty candidate" do
    result = FidelityCheck.call(candidate_text: "", source_text: "totally unrelated text")

    assert result.passed
    assert_empty result.unverifiable_tokens
  end

  test "coverage threshold boundary is inclusive" do
    candidate = "led backend infra rollout"
    source = "led backend infra project"

    at_threshold = FidelityCheck.call(candidate_text: candidate, source_text: source, min_token_coverage: 0.75)
    above_threshold = FidelityCheck.call(candidate_text: candidate, source_text: source, min_token_coverage: 0.76)

    assert at_threshold.passed
    assert_not above_threshold.passed
  end

  test "passes despite case, punctuation, and whitespace differences" do
    result = FidelityCheck.call(
      candidate_text: "  SHIPPED   the Platform-Rewrite!!  ",
      source_text: "shipped the platform rewrite"
    )

    assert result.passed
  end

  test "passes for legitimate condensing that drops only connective filler" do
    result = FidelityCheck.call(
      candidate_text: "Backend engineer building scalable APIs and leading engineering teams",
      source_text: "Backend engineer with experience building scalable APIs and leading engineering teams across multiple projects",
      min_token_coverage: 0.9
    )

    assert result.passed
  end

  # Issue #128: significant_words tokenized with an ASCII-only [^a-z0-9\s]
  # class, so any accented letter (ã, ç, é, ê, õ, í, ú) split one real word
  # into unmatchable garbage fragments -- "experiência" became "experi" and
  # "ncia", neither of which word-boundary-matches the source they came from.
  # Confirmed failing pre-fix: FidelityCheck.call with this exact text as both
  # candidate and source returned passed: false, unverifiable_tokens:
  # ["satisfa", "experi", "ncia", "usu", "rio", "atrav", "otimiza", "cont",
  # "nuas"].
  test "passes for byte-identical Portuguese text containing accented words" do
    text = "Aumentou a satisfação e a experiência do usuário através de otimizações contínuas."

    result = FidelityCheck.call(candidate_text: text, source_text: text)

    assert result.passed
    assert_empty result.unverifiable_tokens
  end

  test "passes for a legitimate Portuguese paraphrase that adds no new facts" do
    result = FidelityCheck.call(
      candidate_text: "Aumentou a satisfação do cliente reduzindo o tempo de resposta",
      source_text: "Aumentou a satisfação do cliente ao reduzir significativamente o tempo de resposta da equipe"
    )

    assert result.passed
  end

  # Unicode-aware tokenization is not diacritic-stripping: it changes what
  # counts as a word character while splitting text into tokens, not what two
  # characters are considered equal. A candidate word with the wrong (or
  # missing) accent relative to the source must still be flagged as
  # unverifiable -- checked directly against unverifiable_tokens rather than
  # the overall passed boolean, since a single mismatched word doesn't
  # necessarily drag the coverage ratio below threshold on its own.
  test "does not treat a differently-accented word as a match" do
    result = FidelityCheck.call(
      candidate_text: "Aumentou a satisfacao do cliente em vinte por cento",
      source_text: "Aumentou a satisfação do cliente em vinte por cento"
    )

    assert_includes result.unverifiable_tokens, "satisfacao"
  end

  test "still fails a genuinely fabricated Portuguese clause" do
    result = FidelityCheck.call(
      candidate_text: "Aumentou a satisfação do cliente e liderou a migração completa para a nuvem",
      source_text: "Aumentou a satisfação do cliente"
    )

    assert_not result.passed
  end

  # Tokenization must NFC-normalize independently of word_boundary_match?'s
  # own per-call normalization (issue #126/#127): a combining mark (NFD's
  # separate codepoint for an accent) is Unicode category Mn, not \p{L}, so
  # without normalizing before splitting, an NFD-encoded string would still
  # get re-fragmented even with a Unicode-aware split regex. Both directions
  # are exercised since either side could be the one that arrived
  # decomposed -- same pattern as word_boundary_matchable_test.rb's NFC/NFD
  # pair, codepoint assertions included so the two literals are provably
  # byte-different, not just editor-equivalent.
  test "passes when candidate is NFD and source is NFC for the same accented text" do
    base = "Aumentou a satisfação e a experiência do usuário através de otimizações contínuas"
    nfd_candidate = base.unicode_normalize(:nfd)
    nfc_source = base.unicode_normalize(:nfc)

    assert_includes nfd_candidate.codepoints, 0x0303, "expected a decomposed combining tilde"
    assert_not_includes nfc_source.codepoints, 0x0303, "expected no combining tilde once NFC"

    result = FidelityCheck.call(candidate_text: nfd_candidate, source_text: nfc_source)

    assert result.passed
    assert_empty result.unverifiable_tokens
  end

  test "passes when candidate is NFC and source is NFD for the same accented text" do
    base = "Aumentou a satisfação e a experiência do usuário através de otimizações contínuas"
    nfc_candidate = base.unicode_normalize(:nfc)
    nfd_source = base.unicode_normalize(:nfd)

    assert_not_includes nfc_candidate.codepoints, 0x0303, "expected no combining tilde once NFC"
    assert_includes nfd_source.codepoints, 0x0303, "expected a decomposed combining tilde"

    result = FidelityCheck.call(candidate_text: nfc_candidate, source_text: nfd_source)

    assert result.passed
    assert_empty result.unverifiable_tokens
  end
end
