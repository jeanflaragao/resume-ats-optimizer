require "application_system_test_case"

# Issue #22's refusal, in a real Turbo-driven browser.
#
# The integration tests next door already prove the quota is enforced and that a
# refusal spends nothing. What they cannot see is whether the user is ever told:
# Usage::Quota::ExceededError is handled by a rescue_from that responds with
# redirect_back_or_to to a form submitted as a turbo_stream (issue #47,
# ADR-0014), and a redirect out of a POST is exactly the shape that went wrong
# twice already in this app (ADR-0010, then ADR-0014). An integration test
# asserts the 302 and follows it by hand; only a browser shows whether Turbo
# renders the result.
class UsageQuotaSystemTest < ApplicationSystemTestCase
  setup do
    @original_limit = ENV["RATE_LIMIT_REQUIREMENT_EXTRACTION_PER_DAY"]
    ENV["RATE_LIMIT_REQUIREMENT_EXTRACTION_PER_DAY"] = "1"
  end

  teardown do
    if @original_limit.nil?
      ENV.delete("RATE_LIMIT_REQUIREMENT_EXTRACTION_PER_DAY")
    else
      ENV["RATE_LIMIT_REQUIREMENT_EXTRACTION_PER_DAY"] = @original_limit
    end
  end

  test "exceeding a per-session quota shows the user why, in the browser" do
    path = write_fixture({ note: "Stub Candidate, stub@example.com" }.to_json)

    visit new_resume_path
    attach_file "file", path
    click_on "Upload"

    fill_in "job_description_text", with: "We need a Ruby engineer."
    click_on "Check match"
    assert_text "Match results"

    fill_in "job_description_text", with: "We need a different Ruby engineer."
    click_on "Check match"

    # "You've", not "We've": the global cap's message would be the wrong advice
    # here, since waiting for someone else to stop is not what this user needs
    # to do (ADR-0023).
    assert_text "You've reached your daily limit for job description analyses (1 per day)"
    assert_no_text "We've hit today's processing limit"
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  private

  def write_fixture(content)
    path = Rails.root.join("tmp/usage_quota_system_test_#{SecureRandom.hex(4)}.json").to_s
    File.write(path, content)
    path
  end
end
