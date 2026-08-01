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
end
