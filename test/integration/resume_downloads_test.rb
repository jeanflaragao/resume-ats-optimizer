require "test_helper"

class ResumeDownloadsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    # Test env's cache_store is :null_store (see config/environments/test.rb),
    # which no-ops read/write -- swap in a real store, same fix
    # test/services/llm_call_guard_test.rb already uses for this exact problem.
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "blank job description text re-renders the resume's show page with an error, no job enqueued" do
    resume = upload_resume

    assert_no_enqueued_jobs do
      post resume_downloads_path(resume), params: { job_description_text: "" }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "paste a job description"
  end

  test "a non-blank job description text enqueues the PDF job and renders the status page" do
    resume = upload_resume

    assert_enqueued_with(job: Resume::OptimizedPdfJob) do
      post resume_downloads_path(resume), params: { job_description_text: "We need a Ruby engineer." }
    end

    assert_response :success
    assert_includes response.body, "Generating your optimized resume PDF"
  end

  # Issue #76. In production the queue adapter is Solid Queue, which serialises
  # these arguments into solid_queue_jobs.arguments -- a plain text column that
  # nothing cleans up for a job that failed. Asserting on the serialised
  # arguments rather than on the argument names, because that payload is what
  # actually reaches Postgres and the log.
  test "the enqueued job carries a reference to the job description, never the text" do
    resume = upload_resume
    job_description_text = "We need a senior Ruby engineer for the Contoso platform team."

    post resume_downloads_path(resume), params: { job_description_text: job_description_text }

    serialized = enqueued_jobs.last["arguments"].to_json
    assert_not_includes serialized, job_description_text
    assert_not_includes serialized, "Contoso"
    assert_not_includes serialized, "job_description_text"

    # The text did not simply vanish: it is in the encrypted record the queue
    # now points at, so the job still has something to render from.
    pdf_request = Resume::PdfRequest.sole
    assert_equal job_description_text, pdf_request.text
    assert_equal resume.id, pdf_request.resume_id
    assert_includes serialized, pdf_request.id.to_s
  end

  test "no pdf request is created when the job description is rejected" do
    resume = upload_resume

    assert_no_difference("Resume::PdfRequest.count") do
      post resume_downloads_path(resume), params: { job_description_text: "" }
      post resume_downloads_path(resume), params: { job_description_text: "a" * (ApplicationController::MAX_JOB_DESCRIPTION_LENGTH + 1) }
    end
  end

  test "a job description text over MAX_JOB_DESCRIPTION_LENGTH re-renders the resume's show page with an error, no job enqueued" do
    resume = upload_resume
    oversized_text = "a" * (ApplicationController::MAX_JOB_DESCRIPTION_LENGTH + 1)

    assert_no_enqueued_jobs do
      post resume_downloads_path(resume), params: { job_description_text: oversized_text }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "too long"
  end

  test "downloads can only be enqueued for a resume owned by the current session" do
    resume = upload_resume

    reset!

    assert_no_enqueued_jobs do
      post resume_downloads_path(resume), params: { job_description_text: "We need a Ruby engineer." }
    end

    assert_response :not_found
  end

  test "serves the cached PDF bytes for a finished download" do
    resume = upload_resume
    download_id = SecureRandom.uuid
    Rails.cache.write(
      Resume::OptimizedPdfJob.cache_key(download_id),
      { resume_id: resume.id, bytes: "%PDF-1.4 fake bytes" }
    )

    get download_path(download_id)

    assert_response :success
    assert_equal "application/pdf", response.media_type
    assert_match(/attachment/, response.headers["Content-Disposition"])
    assert_match(/\A%PDF/, response.body)
  end

  test "#ready returns no content while the job hasn't finished yet" do
    get ready_download_path(SecureRandom.uuid)

    assert_response :no_content
    assert_empty response.body
  end

  test "#ready renders the ready partial once the job has finished" do
    resume = upload_resume
    download_id = SecureRandom.uuid
    Rails.cache.write(
      Resume::OptimizedPdfJob.cache_key(download_id),
      { resume_id: resume.id, bytes: "%PDF-1.4 fake bytes" }
    )

    get ready_download_path(download_id)

    assert_response :success
    assert_includes response.body, "Download PDF"
    assert_includes response.body, download_path(download_id)
  end

  # The success path already had this fallback; the failure path did not, so a
  # broadcast lost to #72's race left the page on "Generating..." forever.
  test "#ready renders the failure reason once a job has failed, not no_content" do
    resume = upload_resume
    download_id = SecureRandom.uuid
    Rails.cache.write(
      Resume::OptimizedPdfJob.cache_key(download_id),
      { resume_id: resume.id, error: "Chinese, Japanese, or Korean characters aren't supported yet." }
    )

    get ready_download_path(download_id)

    assert_response :success
    assert_includes response.body, "Chinese, Japanese, or Korean characters"
    assert_not_includes response.body, "Download PDF"
  end

  test "a failed download's show action explains the failure instead of claiming the link expired" do
    resume = upload_resume
    download_id = SecureRandom.uuid
    Rails.cache.write(
      Resume::OptimizedPdfJob.cache_key(download_id),
      { resume_id: resume.id, error: "Chinese, Japanese, or Korean characters aren't supported yet." }
    )

    get download_path(download_id)

    assert_redirected_to root_path
    follow_redirect!
    assert_includes response.body, "Chinese, Japanese, or Korean characters"
  end

  test "#ready 404s a finished download that belongs to a different session" do
    resume = upload_resume
    download_id = SecureRandom.uuid
    Rails.cache.write(
      Resume::OptimizedPdfJob.cache_key(download_id),
      { resume_id: resume.id, bytes: "%PDF-1.4 fake bytes" }
    )

    reset!

    get ready_download_path(download_id)

    assert_response :not_found
  end

  test "an expired or missing download_id redirects with an alert instead of erroring" do
    get download_path(SecureRandom.uuid)

    assert_redirected_to root_path
    follow_redirect!
    assert_includes response.body, "expired"
  end

  test "a finished download cannot be served to a different session even with a valid download_id" do
    resume = upload_resume
    download_id = SecureRandom.uuid
    Rails.cache.write(
      Resume::OptimizedPdfJob.cache_key(download_id),
      { resume_id: resume.id, bytes: "%PDF-1.4 fake bytes" }
    )

    reset!

    get download_path(download_id)

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
    path = Rails.root.join("tmp/resume_downloads_test_#{SecureRandom.hex(4)}.json").to_s
    File.write(path, content)
    path
  end
end
