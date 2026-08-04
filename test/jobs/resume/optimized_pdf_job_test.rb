require "test_helper"
require "pdf/reader"
require "turbo/broadcastable/test_helper"

class Resume::OptimizedPdfJobTest < ActiveJob::TestCase
  include Turbo::Broadcastable::TestHelper

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

  test "renders the optimized resume to a real PDF, caches it, and broadcasts a ready state" do
    resume = resumes(:one)
    resume.experiences.create!(company: "Acme", title: "Engineer", bullets: [ "Built REST APIs" ], position: 1)
    download_id = SecureRandom.uuid

    assert_turbo_stream_broadcasts "download_#{download_id}" do
      perform_download(resume, download_id)
    end

    cached = Rails.cache.read(Resume::OptimizedPdfJob.cache_key(download_id))
    assert_equal resume.id, cached[:resume_id]
    assert_match(/\A%PDF/, cached[:bytes])

    text = PDF::Reader.new(StringIO.new(cached[:bytes])).pages.map(&:text).join("\n")
    assert_includes text, "Built REST APIs"
  end

  test "a failed job logs only the exception class, not the message, to avoid logging PII" do
    resume = resumes(:one)
    download_id = SecureRandom.uuid
    secret_message = "SECRET CONTENT THAT MUST NOT APPEAR IN LOGS"
    original_call = Resume::Optimization.method(:call)
    Resume::Optimization.define_singleton_method(:call) { |**| raise RubyLLM::ServiceUnavailableError.new(secret_message) }

    original_logger = Rails.logger
    io = StringIO.new
    Rails.logger = Logger.new(io)

    assert_raises(RubyLLM::ServiceUnavailableError) do
      perform_download(resume, download_id)
    end

    log_output = io.string
    assert_includes log_output, "RubyLLM::ServiceUnavailableError"
    assert_not_includes log_output, secret_message
  ensure
    Rails.logger = original_logger
    Resume::Optimization.define_singleton_method(:call, original_call)
  end

  # The log line is the regression risk here, not the raise: emitting "U+1F680"
  # looks harmless next to emitting the name itself, but for a script whose
  # codepoints double as the content, that's the same leak (ADR-0015). Uses
  # emoji, not CJK (issue #81, ADR-0024 -- CJK renders now, so it no longer
  # reaches this rescue clause). Assert on both what it must say and what it
  # must never say.
  test "an unrenderable script logs the Unicode block and count, never the characters or codepoints" do
    resume = resumes(:one)
    resume.update!(name: "Rocket 🚀")
    download_id = SecureRandom.uuid

    original_logger = Rails.logger
    io = StringIO.new
    Rails.logger = Logger.new(io)

    assert_raises(Resume::Pdf::UnrenderableCharacterError) do
      perform_download(resume, download_id)
    end

    log_output = io.string
    assert_includes log_output, "Emoji and Pictographs"
    assert_includes log_output, "1 characters"
    assert_not_includes log_output, "🚀"
    assert_not_includes log_output, "U+"
    assert_not_includes log_output, "1F680"
  ensure
    Rails.logger = original_logger
  end

  test "a missing-glyph refusal tells the user which script is unsupported and not to retry" do
    resume = resumes(:one)
    resume.update!(name: "Rocket 🚀")
    download_id = SecureRandom.uuid

    broadcasts = capture_turbo_stream_broadcasts "download_#{download_id}" do
      assert_raises(Resume::Pdf::UnrenderableCharacterError) do
        perform_download(resume, download_id)
      end
    end

    message = broadcasts.first.to_s
    assert_includes message, "emoji"
    assert_includes message, "doesn't support yet"
    assert_includes message, "Retrying will not help"
    assert_not_includes message, "🚀"
  end

  # ADR-0024: a shaping-required refusal (glyphs exist, Prawn can't shape them
  # correctly) must read as a different fact from a missing-glyph refusal
  # ("we don't have this yet" vs. "we have this and won't draw it wrong") --
  # tested here, at the job level, where the phrasing a candidate actually
  # sees lives.
  test "a shaping-required refusal tells the user it needs complex text layout, not that it's simply unsupported" do
    resume = resumes(:one)
    resume.update!(name: "שלום")
    download_id = SecureRandom.uuid

    broadcasts = capture_turbo_stream_broadcasts "download_#{download_id}" do
      assert_raises(Resume::Pdf::UnrenderableCharacterError) do
        perform_download(resume, download_id)
      end
    end

    message = broadcasts.first.to_s
    assert_includes message, "Hebrew characters"
    assert_includes message, "right-to-left"
    assert_not_includes message, "doesn't support yet"
    assert_not_includes message, "שלום"
  end

  # Without this the failure is only ever broadcast, and a broadcast lost to
  # #72's race leaves the page on "Generating..." forever.
  test "a failure is recorded in the cache so a late subscriber can still see it" do
    resume = resumes(:one)
    download_id = SecureRandom.uuid
    original_call = Resume::Optimization.method(:call)
    Resume::Optimization.define_singleton_method(:call) { |**| raise "boom" }

    assert_raises(RuntimeError) do
      perform_download(resume, download_id)
    end

    cached = Rails.cache.read(Resume::OptimizedPdfJob.cache_key(download_id))
    assert_equal resume.id, cached[:resume_id]
    assert_equal Resume::OptimizedPdfJob::GENERIC_FAILURE_MESSAGE, cached[:error]
    assert_nil cached[:bytes]
  ensure
    Resume::Optimization.define_singleton_method(:call, original_call)
  end

  # #56's rescue_from handlers live in ApplicationController and never reach a
  # job, so before #75 this fell into the blanket StandardError clause and told
  # the user "Please try again" -- advice that is wrong twice over: retrying now
  # fails identically, and retrying tomorrow would have worked.
  test "hitting the daily LLM cap tells the user to come back tomorrow, not to retry now" do
    resume = resumes(:one)
    download_id = SecureRandom.uuid
    original_call = Resume::Optimization.method(:call)
    Resume::Optimization.define_singleton_method(:call) do |**|
      raise LlmCallGuard::DailyLimitExceededError, "Daily LLM call cap (10) exceeded"
    end

    broadcasts = capture_turbo_stream_broadcasts "download_#{download_id}" do
      assert_raises(LlmCallGuard::DailyLimitExceededError) do
        perform_download(resume, download_id)
      end
    end

    cached = Rails.cache.read(Resume::OptimizedPdfJob.cache_key(download_id))
    assert_equal Resume::OptimizedPdfJob::DAILY_LIMIT_MESSAGE, cached[:error]
    assert_not_equal Resume::OptimizedPdfJob::GENERIC_FAILURE_MESSAGE, cached[:error]
    assert_includes cached[:error], "tomorrow"
    assert_includes broadcasts.first.to_s, "tomorrow"
  ensure
    Resume::Optimization.define_singleton_method(:call, original_call)
  end

  test "an unverifiable call budget tells the user to retry shortly, not tomorrow" do
    resume = resumes(:one)
    download_id = SecureRandom.uuid
    original_call = Resume::Optimization.method(:call)
    Resume::Optimization.define_singleton_method(:call) do |**|
      raise LlmCallGuard::BudgetUnavailableError, "LLM call counter is unavailable"
    end

    assert_raises(LlmCallGuard::BudgetUnavailableError) do
      perform_download(resume, download_id)
    end

    cached = Rails.cache.read(Resume::OptimizedPdfJob.cache_key(download_id))
    assert_equal Resume::OptimizedPdfJob::BUDGET_UNAVAILABLE_MESSAGE, cached[:error]
    assert_not_includes cached[:error], "tomorrow"
  ensure
    Resume::Optimization.define_singleton_method(:call, original_call)
  end

  test "broadcasts a failed state and re-raises when Resume::Optimization errors" do
    resume = resumes(:one)
    download_id = SecureRandom.uuid
    original_call = Resume::Optimization.method(:call)
    Resume::Optimization.define_singleton_method(:call) { |**| raise "boom" }

    broadcasts = capture_turbo_stream_broadcasts "download_#{download_id}" do
      assert_raises(RuntimeError) do
        perform_download(resume, download_id)
      end
    end

    # The cache holds a failure marker rather than nothing, so the #ready
    # fallback can distinguish a failed job from one still running -- but it
    # must never hold bytes a failed render didn't produce.
    assert_nil Rails.cache.read(Resume::OptimizedPdfJob.cache_key(download_id))[:bytes]
    assert_includes broadcasts.first.to_s, "went wrong"
  ensure
    Resume::Optimization.define_singleton_method(:call, original_call)
  end

  # Issue #76: the job description now lives in a Resume::PdfRequest rather than
  # in the job's arguments, so the row must not outlive the work it exists for.
  test "the pdf request is destroyed once the PDF has been rendered" do
    resume = resumes(:one)
    resume.experiences.create!(company: "Acme", title: "Engineer", bullets: [ "Built REST APIs" ], position: 1)

    perform_download(resume, SecureRandom.uuid)

    assert_not Resume::PdfRequest.exists?(@pdf_request.id)
  end

  # The mirror of the test above: a failure keeps the row so the work is not
  # lost mid-flight, and Resume::PdfRequest.purge_stale! is what removes it.
  test "a failed job leaves the pdf request for the scheduled purge" do
    resume = resumes(:one)
    original_call = Resume::Optimization.method(:call)
    Resume::Optimization.define_singleton_method(:call) { |**| raise "boom" }

    assert_raises(RuntimeError) { perform_download(resume, SecureRandom.uuid) }

    assert Resume::PdfRequest.exists?(@pdf_request.id)
  ensure
    Resume::Optimization.define_singleton_method(:call, original_call)
  end

  # A purged or already-completed request is an expected state, not a bug --
  # but the status page is still subscribed and waiting, so it must be told.
  # Reporting nothing here reintroduces exactly the "Generating..." hang
  # ADR-0018 closed, just through a new door.
  test "a missing pdf request reports an expired download instead of hanging the page" do
    resume = resumes(:one)
    download_id = SecureRandom.uuid

    broadcasts = capture_turbo_stream_broadcasts "download_#{download_id}" do
      Resume::OptimizedPdfJob.perform_now(
        resume_id: resume.id, pdf_request_id: 0, download_id: download_id
      )
    end

    cached = Rails.cache.read(Resume::OptimizedPdfJob.cache_key(download_id))
    assert_equal resume.id, cached[:resume_id]
    assert_equal Resume::OptimizedPdfJob::EXPIRED_REQUEST_MESSAGE, cached[:error]
    assert_nil cached[:bytes]
    assert_includes broadcasts.first.to_s, "expired"
  end

  private

  # Issue #76: the job takes a Resume::PdfRequest id, never the text itself.
  # Exposes the record it created as @pdf_request so the two lifecycle tests can
  # still name it after perform_now has either destroyed it or raised past it.
  def perform_download(resume, download_id, text: "We need a Ruby engineer.")
    @pdf_request = Resume::PdfRequest.create!(resume: resume, download_id: download_id, text: text)

    Resume::OptimizedPdfJob.perform_now(
      resume_id: resume.id, pdf_request_id: @pdf_request.id, download_id: download_id
    )
  end
end
