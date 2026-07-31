# Deterministic (non-LLM) check for whether free-text "candidate" content
# (a rewritten bullet, an extracted bullet/summary) is adequately grounded in
# "source" text, tolerating legitimate paraphrase while catching invented
# content. Two signals, combined:
#
# - Numbers are zero-tolerance: any digit sequence in candidate_text that
#   doesn't appear in source_text fails immediately. A genuinely new number
#   is the single highest-signal hallucination indicator — legitimate
#   paraphrase essentially never introduces one. Reformatting ("50 percent"
#   vs "50%", "$1,200" vs "1200") is tolerated since only the numeric value
#   is compared, not its surrounding notation.
# - Everything else is a coverage ratio: what fraction of candidate_text's
#   significant (non-stopword) words are traceable to source_text. This is
#   deliberately not 100% — some threshold below that is required to allow
#   legitimate rewording/condensing at all, while still catching added
#   content. See callers for their chosen thresholds and why.
#
# For short fields the schema promises are verbatim (company, title, school,
# skills), use WordBoundaryMatchable directly instead of this class — a
# coverage ratio is order-blind and the wrong tool for those.
class FidelityCheck
  DEFAULT_MIN_TOKEN_COVERAGE = 0.8
  MIN_SIGNIFICANT_TOKEN_LENGTH = 3
  STOPWORDS = %w[
    a an the and or but of to in on for with at by from as is are was were
    be been being this that these those it its into over under after
    before during between without within
  ].freeze

  Result = Data.define(:passed, :unverifiable_tokens)

  include WordBoundaryMatchable

  def self.call(candidate_text:, source_text:, min_token_coverage: DEFAULT_MIN_TOKEN_COVERAGE)
    new(candidate_text: candidate_text, source_text: source_text, min_token_coverage: min_token_coverage).call
  end

  def initialize(candidate_text:, source_text:, min_token_coverage:)
    @candidate_text = candidate_text.to_s
    @source_text = source_text.to_s
    @min_token_coverage = min_token_coverage
  end

  def call
    Result.new(
      passed: unverifiable_numbers.empty? && coverage_meets_threshold?,
      unverifiable_tokens: unverifiable_numbers + unverifiable_words
    )
  end

  private

  attr_reader :candidate_text, :source_text, :min_token_coverage

  def unverifiable_numbers
    candidate_numbers.reject { |number| source_numbers.include?(number) }
  end

  def candidate_numbers
    extract_numbers(candidate_text)
  end

  def source_numbers
    @source_numbers ||= extract_numbers(source_text)
  end

  def extract_numbers(text)
    text.gsub(/(?<=\d),(?=\d)/, "").scan(/\d+(?:\.\d+)?/)
  end

  def unverifiable_words
    significant_words.reject { |word| word_boundary_match?(word, source_text) }
  end

  def coverage_meets_threshold?
    return true if significant_words.empty?

    covered = significant_words.count { |word| word_boundary_match?(word, source_text) }
    (covered / significant_words.size.to_f) >= min_token_coverage
  end

  def significant_words
    @significant_words ||= candidate_text.downcase.gsub(/[^a-z0-9\s]/, " ").split
      .reject { |word| word.match?(/\d/) }
      .reject { |word| STOPWORDS.include?(word) }
      .reject { |word| word.length < MIN_SIGNIFICANT_TOKEN_LENGTH }
  end
end
