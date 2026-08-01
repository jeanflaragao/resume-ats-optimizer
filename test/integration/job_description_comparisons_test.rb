require "test_helper"

class JobDescriptionComparisonsTest < ActionDispatch::IntegrationTest
  test "blank job description text re-renders the resume's show page with an error" do
    resume = upload_resume

    post resume_job_description_path(resume), params: { job_description_text: "" }

    assert_response :unprocessable_entity
    assert_includes response.body, "paste a job description"
    assert_not_includes response.body, "Match results"
  end

  test "a non-blank job description text renders the match results section" do
    resume = upload_resume

    post resume_job_description_path(resume), params: { job_description_text: "We need a Ruby engineer." }

    assert_response :success
    assert_includes response.body, "Match results"
    # LlmCallGuard's stub returns no required/preferred skills or keywords for
    # JobDescription::ExtractionSchema, so Comparison/MatchScore have nothing to
    # match against and MatchScore.call returns nil (not a misleading 0%).
    assert_includes response.body, "Not enough required/preferred skills or keywords"
  end

  test "a job description text over MAX_JOB_DESCRIPTION_LENGTH re-renders the resume's show page with an error" do
    resume = upload_resume
    oversized_text = "a" * (ApplicationController::MAX_JOB_DESCRIPTION_LENGTH + 1)

    post resume_job_description_path(resume), params: { job_description_text: oversized_text }

    assert_response :unprocessable_entity
    assert_includes response.body, "too long"
    assert_not_includes response.body, "Match results"
  end

  test "a job description can only be submitted against a resume owned by the current session" do
    resume = upload_resume

    reset!

    post resume_job_description_path(resume), params: { job_description_text: "We need a Ruby engineer." }

    assert_response :not_found
  end

  private

  def upload_resume
    path = write_fixture({ note: "Stub Candidate, stub@example.com" }.to_json)
    post resumes_path, params: { file: Rack::Test::UploadedFile.new(path, "application/json") }
    Resume.last
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def write_fixture(content)
    path = Rails.root.join("tmp/job_description_comparisons_test_#{SecureRandom.hex(4)}.json").to_s
    File.write(path, content)
    path
  end
end
