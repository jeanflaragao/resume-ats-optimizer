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
      Resume::OptimizedPdfJob.perform_now(
        resume_id: resume.id,
        job_description_text: "We need a Ruby engineer.",
        download_id: download_id
      )
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
      Resume::OptimizedPdfJob.perform_now(
        resume_id: resume.id,
        job_description_text: "We need a Ruby engineer.",
        download_id: download_id
      )
    end

    log_output = io.string
    assert_includes log_output, "RubyLLM::ServiceUnavailableError"
    assert_not_includes log_output, secret_message
  ensure
    Rails.logger = original_logger
    Resume::Optimization.define_singleton_method(:call, original_call)
  end

  test "broadcasts a failed state and re-raises when Resume::Optimization errors" do
    resume = resumes(:one)
    download_id = SecureRandom.uuid
    original_call = Resume::Optimization.method(:call)
    Resume::Optimization.define_singleton_method(:call) { |**| raise "boom" }

    broadcasts = capture_turbo_stream_broadcasts "download_#{download_id}" do
      assert_raises(RuntimeError) do
        Resume::OptimizedPdfJob.perform_now(
          resume_id: resume.id,
          job_description_text: "We need a Ruby engineer.",
          download_id: download_id
        )
      end
    end

    assert_nil Rails.cache.read(Resume::OptimizedPdfJob.cache_key(download_id))
    assert_includes broadcasts.first.to_s, "went wrong"
  ensure
    Resume::Optimization.define_singleton_method(:call, original_call)
  end
end
