require "test_helper"

# End-to-end enforcement of issue #22's per-subject quota across the four
# controllers that can spend an Anthropic request or a worker thread.
#
# Every test here asserts the *absence of work*, not just the flash. A refusal
# that still ran the pipeline, wrote a job-description row or enqueued a job
# would show the user the same message while costing exactly what the quota
# exists to prevent -- so the message alone is not evidence of anything.
class UsageQuotaTest < ActionDispatch::IntegrationTest
  setup do
    @original_env = Usage::Quota::ACTION_TYPES.to_h { |a| [ Usage::Quota.env_var_for(a), ENV[Usage::Quota.env_var_for(a)] ] }
  end

  teardown do
    @original_env.each { |var, value| value.nil? ? ENV.delete(var) : ENV[var] = value }
    @fixture_paths&.each { |path| File.delete(path) if File.exist?(path) }
  end

  test "an upload past the quota is refused before any resume is imported" do
    ENV["RATE_LIMIT_RESUME_EXTRACTION_PER_DAY"] = "1"
    upload_resume

    assert_no_difference -> { Resume.count } do
      upload_resume
    end

    assert_redirected_to root_path
    follow_redirect!
    assert_includes response.body, "daily limit for resume uploads"
  end

  test "an analyze past the quota is refused without running the extractor" do
    ENV["RATE_LIMIT_REQUIREMENT_EXTRACTION_PER_DAY"] = "1"
    resume = upload_resume
    post resume_job_description_path(resume), params: { job_description_text: "We need a Ruby engineer." }
    assert_response :success

    log_output = with_captured_log do
      post resume_job_description_path(resume), params: { job_description_text: "We need a Ruby engineer." }
    end

    assert_redirected_to root_path
    follow_redirect!
    assert_includes response.body, "daily limit for job description analyses"
    # The handler logs the class and the action type -- never the session token
    # it authorizes with, and never user content (ADR-0015).
    assert_includes log_output, "Usage::Quota::ExceededError (requirement_extraction)"
    assert_not_includes log_output, session[:owner_token].to_s
  end

  test "a preview past the quota is refused without rendering an optimized resume" do
    ENV["RATE_LIMIT_BULLET_REWRITING_PER_DAY"] = "1"
    resume = upload_resume
    resume.experiences.create!(company: "Acme", title: "Engineer", bullets: [ "Built REST APIs" ], position: 1)
    post resume_preview_path(resume), params: { job_description_text: "We need a Ruby engineer." }
    assert_response :success

    post resume_preview_path(resume), params: { job_description_text: "A different posting entirely." }

    assert_redirected_to root_path
    follow_redirect!
    assert_includes response.body, "daily limit for resume previews"
    assert_not_includes response.body, "Optimized resume preview"
  end

  # The download is the path issue #22's body actually describes -- "before
  # enqueuing the job into Solid Queue". Both halves matter: no job, and no
  # encrypted job-description row left behind for Resume::PdfRequest.purge_stale!
  # to collect (issue #76, ADR-0022).
  test "a download past the quota enqueues no job and writes no job-description row" do
    ENV["RATE_LIMIT_PDF_GENERATION_PER_DAY"] = "1"
    resume = upload_resume
    post resume_downloads_path(resume), params: { job_description_text: "We need a Ruby engineer." }
    assert_response :redirect

    assert_no_enqueued_jobs only: Resume::OptimizedPdfJob do
      assert_no_difference -> { Resume::PdfRequest.count } do
        post resume_downloads_path(resume), params: { job_description_text: "We need a Ruby engineer." }
      end
    end

    assert_redirected_to root_path
    follow_redirect!
    assert_includes response.body, "daily limit for PDF downloads"
  end

  # ADR-0025: Resume::Pdf.guard_renderable! runs before enforce_quota! in
  # DownloadsController#create, so a resume the PDF renderer will refuse
  # never spends the requester's pdf_generation quota on that refusal --
  # distinct from every other job failure, which does spend it
  # (Usage::Quota.consume!'s "nothing is refunded" comment), because this
  # refusal is knowable before any work starts, not discovered partway
  # through it.
  #
  # Non-vacuity: run against the pre-ADR-0025 controller (guard check absent,
  # enforce_quota! running unconditionally) and confirmed this request DID
  # consume a pdf_generation slot -- see the PR body for the captured output.
  test "a resume with an unrenderable name is refused without enqueuing a job or spending pdf_generation quota" do
    resume = upload_resume
    resume.update!(name: "שלום")

    assert_no_enqueued_jobs only: Resume::OptimizedPdfJob do
      assert_no_difference -> { Resume::PdfRequest.count } do
        post resume_downloads_path(resume), params: { job_description_text: "We need a Ruby engineer." }
      end
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "right-to-left"
    assert_nil Usage::Counter.find_by(subject_token: session[:owner_token], action_type: "pdf_generation")
  end

  # The cheap rejections come first, so a request that never had a chance to
  # cost anything must not cost a slot either. Without this ordering a user
  # could be locked out for the day by pasting an over-long posting repeatedly
  # -- work the app declines to do in the first place.
  test "a request rejected for length does not consume any quota" do
    ENV["RATE_LIMIT_REQUIREMENT_EXTRACTION_PER_DAY"] = "1"
    resume = upload_resume
    oversized = "a" * (ApplicationController::MAX_JOB_DESCRIPTION_LENGTH + 1)

    3.times { post resume_job_description_path(resume), params: { job_description_text: oversized } }
    assert_response :unprocessable_entity

    post resume_job_description_path(resume), params: { job_description_text: "We need a Ruby engineer." }
    assert_response :success
  end

  test "a blank upload does not consume any quota" do
    ENV["RATE_LIMIT_RESUME_EXTRACTION_PER_DAY"] = "1"

    3.times { post resumes_path, params: {} }
    assert_response :unprocessable_entity

    assert_difference -> { Resume.count }, 1 do
      upload_resume
    end
  end

  # The quota is per subject, and the subject is the session. This is the
  # mechanism's whole reason for existing next to LlmCallGuard's global cap: one
  # visitor exhausting their own allowance must leave everyone else working.
  #
  # It is also, read the other way, this design's known limit -- a second
  # session is a second quota, and opening a private window is exactly that.
  # ADR-0023 records why that is accepted and why it means #22 does not unblock
  # public signup.
  test "one session exhausting its quota leaves another session unaffected" do
    ENV["RATE_LIMIT_RESUME_EXTRACTION_PER_DAY"] = "1"

    exhausted = open_session
    exhausted.post resumes_path, params: { file: upload_fixture }
    assert_no_difference -> { Resume.count } do
      exhausted.post resumes_path, params: { file: upload_fixture }
    end
    assert_includes exhausted.flash[:alert], "daily limit"

    fresh = open_session
    assert_difference -> { Resume.count }, 1 do
      fresh.post resumes_path, params: { file: upload_fixture }
    end
    assert_nil fresh.flash[:alert]
  end

  # Two sessions are two subjects, so an exhausted quota in one must not be
  # readable as "the service is down" in the other -- that is the global cap's
  # message, and it belongs to a different mechanism.
  test "the per-subject message is worded distinctly from the global cap's" do
    ENV["RATE_LIMIT_RESUME_EXTRACTION_PER_DAY"] = "1"
    upload_resume
    upload_resume
    follow_redirect!

    assert_includes response.body, "You&#39;ve reached your daily limit"
    assert_not_includes response.body, "We&#39;ve hit today&#39;s processing limit"
  end

  private

  def upload_resume
    post resumes_path, params: { file: upload_fixture }
    Resume.last
  end

  def upload_fixture
    path = Rails.root.join("tmp/usage_quota_test_#{SecureRandom.hex(4)}.json").to_s
    File.write(path, { note: "Stub Candidate, stub@example.com" }.to_json)
    (@fixture_paths ||= []) << path
    Rack::Test::UploadedFile.new(path, "application/json")
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
