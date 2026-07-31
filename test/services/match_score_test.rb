require "test_helper"

class MatchScoreTest < ActiveSupport::TestCase
  test "scores 100 when everything matched" do
    comparison = build_comparison(
      matched_required_skills: [ "Ruby" ], missing_required_skills: [],
      matched_preferred_skills: [ "Go" ], missing_preferred_skills: [],
      matched_keywords: [ "scalability" ], missing_keywords: []
    )

    assert_equal 100, MatchScore.call(comparison: comparison)
  end

  test "scores 0 when nothing matched" do
    comparison = build_comparison(
      matched_required_skills: [], missing_required_skills: [ "Ruby" ],
      matched_preferred_skills: [], missing_preferred_skills: [ "Go" ],
      matched_keywords: [], missing_keywords: [ "scalability" ]
    )

    assert_equal 0, MatchScore.call(comparison: comparison)
  end

  test "weights required skills more heavily than preferred skills and keywords" do
    # 1 of 1 required matched (weight 3), nothing else present at all.
    required_only = build_comparison(
      matched_required_skills: [ "Ruby" ], missing_required_skills: [],
      matched_preferred_skills: [], missing_preferred_skills: [],
      matched_keywords: [], missing_keywords: []
    )

    # 1 of 1 keyword matched (weight 1), nothing else present at all.
    keyword_only = build_comparison(
      matched_required_skills: [], missing_required_skills: [],
      matched_preferred_skills: [], missing_preferred_skills: [],
      matched_keywords: [ "scalability" ], missing_keywords: []
    )

    assert_equal 100, MatchScore.call(comparison: required_only)
    assert_equal 100, MatchScore.call(comparison: keyword_only)

    # Now mix: 1 of 1 required matched, but 1 of 1 keyword missing. Required's
    # higher weight should keep the score above the halfway point.
    mixed = build_comparison(
      matched_required_skills: [ "Ruby" ], missing_required_skills: [],
      matched_preferred_skills: [], missing_preferred_skills: [],
      matched_keywords: [], missing_keywords: [ "scalability" ]
    )

    assert_equal 75, MatchScore.call(comparison: mixed)
  end

  test "returns nil when the job description had no requirements to score against" do
    comparison = build_comparison(
      matched_required_skills: [], missing_required_skills: [],
      matched_preferred_skills: [], missing_preferred_skills: [],
      matched_keywords: [], missing_keywords: []
    )

    assert_nil MatchScore.call(comparison: comparison)
  end

  private

  def build_comparison(**attributes)
    Comparison::Result.new(**attributes)
  end
end
