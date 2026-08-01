require "test_helper"

class LlmCallGuardTest < ActiveSupport::TestCase
  setup do
    @original_enabled = ENV["ENABLE_REAL_LLM_CALLS"]
    @original_max_calls = ENV["MAX_LLM_CALLS_PER_DAY"]
    # Test env's cache_store is :null_store (see config/environments/test.rb),
    # which no-ops increment — swap in a real store so the daily-cap counting
    # under test actually counts.
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    ENV["ENABLE_REAL_LLM_CALLS"] = @original_enabled
    ENV["MAX_LLM_CALLS_PER_DAY"] = @original_max_calls
    Rails.cache = @original_cache
  end

  test "stub mode returns a labeled stub chat without touching the real API or the daily cap" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "false"

    chat = LlmCallGuard.chat

    assert_instance_of LlmCallGuard::StubChat, chat
    content = chat.with_schema(Resume::ExtractionSchema).ask("prompt", with: "file.pdf").content
    assert_includes content["summary"], "LlmCallGuard stub response"
    assert_equal [], content["experiences"]
  end

  test "stub chat echoes back the right number of bullets for BulletRewriter's schema" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "false"

    prompt = <<~PROMPT
      Original bullets:
      1. Led migration to microservices
      2. Mentored three junior engineers
    PROMPT

    content = LlmCallGuard.chat.with_schema(BulletRewriter::Schema).ask(prompt).content

    assert_equal 2, content["bullets"].size
    content["bullets"].each { |bullet| assert_includes bullet, "LlmCallGuard stub response" }
  end

  test "stub chat raises for an unrecognized schema" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "false"

    unknown_schema = Class.new(RubyLLM::Schema)

    assert_raises(NotImplementedError) do
      LlmCallGuard.chat.with_schema(unknown_schema).ask("prompt")
    end
  end

  test "real mode allows exactly the configured number of calls per day, then raises" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "true"
    ENV["MAX_LLM_CALLS_PER_DAY"] = "2"
    original_key = RubyLLM.config.anthropic_api_key
    RubyLLM.config.anthropic_api_key = "test-key"

    2.times { refute_instance_of LlmCallGuard::StubChat, LlmCallGuard.chat }

    assert_raises(LlmCallGuard::DailyLimitExceededError) { LlmCallGuard.chat }
  ensure
    RubyLLM.config.anthropic_api_key = original_key
  end
end
