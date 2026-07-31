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
end
