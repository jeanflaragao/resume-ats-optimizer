require "test_helper"

class WordBoundaryMatchableTest < ActiveSupport::TestCase
  Matcher = Class.new { include WordBoundaryMatchable }.new

  # Realistic enough to contain the adjacent-punctuation runs ("\n\n", ", ")
  # that make an unguarded blank term's regex match real documents almost
  # everywhere - a text with no such runs (e.g. plain "anything") wouldn't
  # actually exercise the bug either way.
  REALISTIC_TEXT = "Jane Doe\n\nExperience: Senior Engineer, Acme Corp.".freeze

  test "a blank empty-string term never matches, even against text that would trip an unguarded regex" do
    assert_not Matcher.word_boundary_match?("", REALISTIC_TEXT)
  end

  test "a nil term (as a string) never matches" do
    assert_not Matcher.word_boundary_match?(nil.to_s, REALISTIC_TEXT)
  end

  test "a whitespace-only term never matches, even against text containing that exact run of spaces" do
    assert_not Matcher.word_boundary_match?("   ", "before.   .after")
  end

  test "a real term still matches when present in the text" do
    assert Matcher.word_boundary_match?("ruby", "I use Ruby daily")
  end

  test "a real term still fails to match when absent from the text" do
    assert_not Matcher.word_boundary_match?("python", "I use Ruby daily")
  end

  # Issue #126: pdftotext (Resume::Extractors::Llm#source_text) emits NFD
  # (decomposed) Unicode for accented characters; Claude's API returns NFC
  # (precomposed). Same rendered character, different codepoint sequence --
  # an accented letter is one codepoint under NFC, or a base letter plus a
  # combining mark (two codepoints) under NFD. A literal match must not
  # depend on which form either side happens to use. Both forms are produced
  # here with an explicit unicode_normalize call rather than trusted from the
  # literal's on-disk encoding, and the codepoint-count assertions pin that
  # the two forms really are different byte sequences, so the test provably
  # exercises what it claims regardless of editor/tooling.
  test "an NFC term matches NFD text containing the same accented character" do
    name_with_tilde = [ 0x4a, 0x6f, 0x61, 0x6f ].pack("U*") + [ 0xe3 ].pack("U") # "Joa" + precomposed a-with-tilde
    nfc_term = name_with_tilde.unicode_normalize(:nfc)
    nfd_text = ("Contact: " + name_with_tilde + " Silva").unicode_normalize(:nfd)

    assert_equal 5, nfc_term.length, "expected the accented letter as one precomposed codepoint"
    assert_includes nfd_text.codepoints, 0x0303, "expected a decomposed combining tilde in the text"
    assert Matcher.word_boundary_match?(nfc_term, nfd_text)
  end

  test "an NFD term matches NFC text containing the same accented character" do
    name_with_tilde = [ 0x4a, 0x6f, 0x61, 0x6f ].pack("U*") + [ 0xe3 ].pack("U")
    nfd_term = name_with_tilde.unicode_normalize(:nfd)
    nfc_text = ("Contact: " + name_with_tilde + " Silva").unicode_normalize(:nfc)

    assert_includes nfd_term.codepoints, 0x0303, "expected a decomposed combining tilde in the term"
    assert_not_includes nfc_text.codepoints, 0x0303, "expected no combining tilde once the text is NFC"
    assert Matcher.word_boundary_match?(nfd_term, nfc_text)
  end

  # The normalization must not paper over an actually-missing base character
  # -- that was the other half of issue #126's original corruption (a base
  # letter dropped outright, not just re-encoded), and no Unicode
  # normalization can recover a character that was never there.
  test "normalization does not make a genuinely different word match" do
    assert_not Matcher.word_boundary_match?("Vasconcelos", "Vasconelos")
  end
end
