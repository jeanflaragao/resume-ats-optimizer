# Deterministic (non-LLM) compatibility score derived from a Comparison::Result.
# Required skills count most toward the score, preferred skills less, and
# keywords least, reflecting how much each category actually matters to
# whether a resume is a good fit for the job.
class MatchScore
  WEIGHTS = { required_skills: 3, preferred_skills: 2, keywords: 1 }.freeze

  def self.call(comparison:)
    new(comparison: comparison).call
  end

  def initialize(comparison:)
    @comparison = comparison
  end

  # Returns an integer percentage (0-100), or nil if the job description had
  # no required/preferred skills or keywords at all to score against.
  def call
    return nil if total_weight.zero?

    ((matched_weight / total_weight.to_f) * 100).round
  end

  private

  attr_reader :comparison

  def matched_weight
    WEIGHTS.sum { |category, weight| matched_count(category) * weight }
  end

  def total_weight
    WEIGHTS.sum { |category, weight| total_count(category) * weight }
  end

  def matched_count(category)
    comparison.public_send(:"matched_#{category}").size
  end

  def total_count(category)
    matched_count(category) + comparison.public_send(:"missing_#{category}").size
  end
end
