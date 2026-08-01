require "test_helper"

class ResumePreviewsTest < ActionDispatch::IntegrationTest
  test "blank job description text re-renders the resume's show page with an error" do
    resume = upload_resume

    post resume_preview_path(resume), params: { job_description_text: "" }

    assert_response :unprocessable_entity
    assert_includes response.body, "paste a job description"
    assert_not_includes response.body, "Optimized resume preview"
  end

  test "a non-blank job description text renders the optimized resume preview" do
    resume = upload_resume
    resume.experiences.create!(company: "Acme", title: "Engineer", bullets: [ "Built REST APIs" ], position: 1)

    log_output = with_captured_log do
      post resume_preview_path(resume), params: { job_description_text: "We need a Ruby engineer." }
    end

    assert_response :success
    assert_includes response.body, "Optimized resume preview"
    assert_includes response.body, "Built REST APIs"
    # LlmCallGuard's stub label text isn't traceable to the original bullet, so
    # BulletRewriter's own fidelity check rejects it and falls back to the
    # original wording -- that fallback (logged here) is what proves the real
    # Resume::Optimization -> BulletRewriter -> LlmCallGuard chain executed,
    # not a bypass. Same technique test/services/resume/optimization_test.rb uses.
    assert_includes log_output, "bullet 1"
  end

  test "a job description text over MAX_JOB_DESCRIPTION_LENGTH re-renders the resume's show page with an error" do
    resume = upload_resume
    oversized_text = "a" * (ApplicationController::MAX_JOB_DESCRIPTION_LENGTH + 1)

    post resume_preview_path(resume), params: { job_description_text: oversized_text }

    assert_response :unprocessable_entity
    assert_includes response.body, "too long"
    assert_not_includes response.body, "Optimized resume preview"
  end

  test "a preview can only be requested for a resume owned by the current session" do
    resume = upload_resume

    reset!

    post resume_preview_path(resume), params: { job_description_text: "We need a Ruby engineer." }

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
    path = Rails.root.join("tmp/resume_previews_test_#{SecureRandom.hex(4)}.json").to_s
    File.write(path, content)
    path
  end

  def with_captured_log
    original_logger = Rails.logger
    io = StringIO.new
    Rails.logger = Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original_logger
  end
end
