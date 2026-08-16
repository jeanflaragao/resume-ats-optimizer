require "test_helper"

# Issue #83: a preview followed by a download of the same resume against the
# same job description used to run Resume::Optimization twice -- one
# BulletRewriter request per experience each time. That is not only double the
# spend: the two runs are independent LLM calls, so the PDF a user downloaded
# was not the resume they approved on screen.
class PreviewDownloadReuseTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  EXPERIENCE_COUNT = 3

  JOB_DESCRIPTION = "We need a senior Ruby engineer to lead platform migrations.".freeze
  EDITED_JOB_DESCRIPTION = "We need a senior Ruby engineer to mentor a growing team.".freeze

  # Eight words each, and distinct from one another. RecordingChat's vary: mode
  # rewrites a bullet by rotating its own words by the number of requests made
  # so far, so a bullet needs more words than the number of requests in the
  # test for two runs to be reliably distinguishable -- rotating an eight-word
  # bullet by 0,1,2 (preview) and by 3,4,5 (download) never collides.
  BULLETS = [
    "Led the migration of billing services onto Kubernetes clusters",
    "Mentored three junior engineers through their first production launches",
    "Rebuilt the payment reconciliation pipeline for the finance organisation"
  ].freeze

  # Structural guard, not a behavior test (same spirit as
  # test/config/llm_call_guard_enforcement_test.rb's structural check). This
  # file's heaviest scenario ("an edited job description between preview and
  # download is not served the earlier rewrite", below) drives
  # 2 * EXPERIENCE_COUNT real per-subject-counted requests in one flow --
  # confirmed real, not stubbed: enable_real_calls + with_recording_chat
  # replaces RubyLLM.chat, the seam *inside* MeteredChat#ask, so
  # LlmCallGuard.record_call! (and its per-subject increment) genuinely runs.
  # If EXPERIENCE_COUNT ever grows enough to reach LlmCallGuard's local
  # per-subject default, that test starts failing with
  # SubjectLimitExceededError instead of testing what it's meant to -- a
  # confusing failure with no apparent connection to this file. Assert the
  # relationship directly so a violation fails here, with an explanatory
  # message, instead of there.
  test "this file's heaviest per-subject fan-out stays under LlmCallGuard's local per-subject cap" do
    assert_operator 2 * EXPERIENCE_COUNT, :<, LlmCallGuard.max_calls_per_day_per_subject,
      "raise MAX_LLM_CALLS_PER_DAY_PER_SUBJECT or shrink EXPERIENCE_COUNT -- otherwise the " \
      "edited-job-description test below will start failing with SubjectLimitExceededError"
  end

  setup do
    sign_in_as(users(:jordan))

    # Test env's cache_store is :null_store (see config/environments/test.rb),
    # which no-ops read/write -- swap in a real store, the same fix
    # test/services/llm_call_guard_test.rb and test/jobs/resume/
    # optimized_pdf_job_test.rb already use for this exact problem.
    #
    # This swap is LOAD-BEARING: under :null_store every cache write here is
    # discarded, so the reuse these tests assert could not happen and the
    # suite would be measuring nothing. Do not drop it.
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    @original_enabled = ENV["ENABLE_REAL_LLM_CALLS"]
    @original_max_calls = ENV["MAX_LLM_CALLS_PER_DAY"]
  end

  teardown do
    Rails.cache = @original_cache
    ENV["ENABLE_REAL_LLM_CALLS"] = @original_enabled
    ENV["MAX_LLM_CALLS_PER_DAY"] = @original_max_calls
  end

  test "a preview followed by a download issues one rewrite request per experience in total" do
    resume = resume_with_experiences
    enable_real_calls

    requests = with_recording_chat do |log|
      preview(JOB_DESCRIPTION)
      download(JOB_DESCRIPTION)
      log
    end

    assert_equal EXPERIENCE_COUNT, requests.size,
      "expected the download to reuse the preview's rewrites: one request per experience in total, not two"
  end

  # The property that makes #83 a correctness fix rather than a cost
  # optimisation. Non-vacuous only because RecordingChat is asked to vary its
  # rewrites (vary: true): with a deterministic stub, preview and download
  # would match even with no cache at all.
  test "the download delivers exactly the bullets the preview showed" do
    resume = resume_with_experiences
    enable_real_calls

    delivered = nil
    with_recording_chat(vary: true) do
      preview(JOB_DESCRIPTION)
      previewed = previewed_bullets

      delivered = capture_rendered_resume { download(JOB_DESCRIPTION) }

      assert_equal previewed, delivered.experiences.flat_map(&:bullets),
        "the downloaded PDF must be rendered from the same rewrites the user approved on screen"
    end
  end

  # The deliberate other half of the tradeoff: an edited job description must
  # never be served an earlier rewrite, even though re-running costs another
  # request per experience and delivers content the user has not previewed.
  #
  # Note for anyone reading the history: this test passed before the fix, and
  # it passed VACUOUSLY -- with no cache in existence nothing could serve a
  # stale rewrite, so both assertions held for a reason that had nothing to do
  # with what is being asserted. It only becomes meaningful once the cache
  # exists; the proof that it is meaningful is that making jd_digest constant
  # (so an edited job description collides with the original key) drops the
  # request count to N, makes the bullets match, and fails this test.
  test "an edited job description between preview and download is not served the earlier rewrite" do
    resume = resume_with_experiences
    enable_real_calls

    prompts = []
    delivered = nil

    requests = with_recording_chat(prompts, vary: true) do |log|
      preview(JOB_DESCRIPTION)
      previewed = previewed_bullets

      delivered = capture_rendered_resume { download(EDITED_JOB_DESCRIPTION) }

      refute_equal previewed, delivered.experiences.flat_map(&:bullets),
        "an edited job description must be rewritten afresh, not served the preview's cached result"
      log
    end

    assert_equal 2 * EXPERIENCE_COUNT, requests.size,
      "an edited job description must re-run the whole fan-out"
    assert prompts.last(EXPERIENCE_COUNT).all? { |prompt| prompt.include?(EDITED_JOB_DESCRIPTION) },
      "the second run must embed the edited job description, not the original"
  end

  # The reuse is asserted directly rather than inferred from the request count:
  # a download that quietly fell through the lock into a second pipeline run
  # would still deliver a correct PDF, and only these counters distinguish that
  # from a genuine reuse.
  test "a download that reuses the preview counts as a hit, and a cold download counts as a miss" do
    resume = resume_with_experiences
    enable_real_calls

    with_recording_chat do
      preview(JOB_DESCRIPTION)
      download(JOB_DESCRIPTION)
    end

    assert_equal 1, counter(:preview, :miss), "the preview is the cold path and must run the pipeline once"
    assert_equal 1, counter(:download, :hit), "the download must be served from the preview's entry"
    assert_nil counter(:download, :miss), "a reused download must not be recorded as a miss"
  end

  test "a download with no preview before it records a countable miss and still delivers a PDF" do
    resume = resume_with_experiences
    enable_real_calls

    delivered = nil
    log_output = with_captured_log do
      with_recording_chat do
        delivered = capture_rendered_resume { download(JOB_DESCRIPTION) }
      end
    end

    assert_equal 1, counter(:download, :miss), "a download that had to re-run must be countable"
    assert_equal EXPERIENCE_COUNT, delivered.experiences.size, "a miss must still produce a downloadable resume"
    assert_includes log_output, "download miss for resume #{resume.id}",
      "the miss must also be traceable in the log, without echoing any of the user's text"
    refute_includes log_output, JOB_DESCRIPTION, "ADR-0015: no job description content in logs"
  end

  private

  def counter(context, outcome)
    Rails.cache.read(Resume::CachedOptimization.counter_key(context, outcome))
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

  def enable_real_calls
    ENV["ENABLE_REAL_LLM_CALLS"] = "true"
    ENV["MAX_LLM_CALLS_PER_DAY"] = "1000"
  end

  def preview(job_description_text)
    post resume_preview_path(@resume), params: { job_description_text: job_description_text }
    assert_response :success
  end

  def download(job_description_text)
    perform_enqueued_jobs do
      post resume_downloads_path(@resume), params: { job_description_text: job_description_text }
    end
    # Issue #66/ADR-0029: #create now redirects to the addressable /downloads/:id
    # rather than rendering in place.
    assert_response :redirect
  end

  def previewed_bullets
    css_select("ul.list-disc li").map { |element| element.text.strip }
  end

  # Resume::Pdf is the last thing the download job touches, and it receives the
  # exact value object the PDF is rendered from -- so capturing its argument is
  # the delivered content, without having to extract text back out of a PDF.
  # Same define_singleton_method seam test/integration/resume_previews_test.rb
  # already uses to intercept a service call.
  def capture_rendered_resume
    captured = nil
    original = Resume::Pdf.method(:call)
    Resume::Pdf.define_singleton_method(:call) do |resume:|
      captured = resume
      original.call(resume: resume)
    end
    yield
    captured
  ensure
    Resume::Pdf.define_singleton_method(:call, original)
  end

  # Uploaded through the real controller so the resume is owned by the
  # signed-in user, then given experiences directly: the import path's
  # extraction is not what these tests are about. Uploaded before real calls
  # are enabled, so the import itself costs nothing and is not counted.
  def resume_with_experiences
    path = Rails.root.join("tmp/preview_download_reuse_#{SecureRandom.hex(4)}.json").to_s
    File.write(path, { note: "Stub Candidate, stub@example.com" }.to_json)
    post resumes_path, params: { file: Rack::Test::UploadedFile.new(path, "application/json") }

    @resume = Resume.last
    BULLETS.first(EXPERIENCE_COUNT).each_with_index do |bullet, index|
      @resume.experiences.create!(company: "Company #{index}", title: "Engineer", bullets: [ bullet ], position: index)
    end
    @resume
  ensure
    File.delete(path) if path && File.exist?(path)
  end
end
