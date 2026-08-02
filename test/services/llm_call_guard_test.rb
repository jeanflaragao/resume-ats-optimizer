require "test_helper"

class LlmCallGuardTest < ActiveSupport::TestCase
  # Mimics RubyLLM::Chat's message accumulation so a shared chat is *visible*
  # here rather than having to be inferred: #ask appends the user message
  # (ruby_llm/chat.rb:40 -> :167) and the assistant reply is appended too
  # (:229), and every ask re-sends the whole array. Recording messages.size at
  # each ask is therefore exactly the payload-growth signal we want to guard.
  class RecordingChat
    attr_reader :messages

    def initialize(sizes_log)
      @sizes_log = sizes_log
      @messages = []
    end

    def with_schema(schema)
      @schema = schema
      self
    end

    def ask(prompt = nil, **)
      @messages << { role: :user, content: prompt }
      @sizes_log << @messages.size
      reply = { "bullets" => prompt.to_s.scan(/^\d+\.\s+(.+)$/).flatten }
      @messages << { role: :assistant, content: reply }
      Struct.new(:content).new(reply)
    end
  end

  setup do
    @original_enabled = ENV["ENABLE_REAL_LLM_CALLS"]
    @original_max_calls = ENV["MAX_LLM_CALLS_PER_DAY"]
    # Test env's cache_store is :null_store (see config/environments/test.rb),
    # which no-ops increment — swap in a real store so the daily-cap counting
    # under test actually counts.
    #
    # This swap is LOAD-BEARING, in the same way #57's forgery_protection
    # toggle is: under :null_store, Rails.cache.increment returns nil for
    # every call, so a cap test would pass against a guard that counts
    # nothing at all. Removing the swap does not make these tests fail — it
    # makes them vacuous. Do not drop it.
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

  # Replaces the pre-#75 version of this test, which drove the cap through
  # .chat (`3.times { LlmCallGuard.chat }`). Resolving a chat is free now —
  # issuing a request is what costs money and what counts. Same coverage
  # (N allowed, then raise), asserted at the boundary that bills.
  test "real mode allows exactly the configured number of requests per day, then raises" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "true"
    ENV["MAX_LLM_CALLS_PER_DAY"] = "2"

    with_recording_chat do
      chat = LlmCallGuard.chat
      refute_instance_of LlmCallGuard::StubChat, chat

      2.times { chat.with_schema(BulletRewriter::Schema).ask("1. Built a thing") }

      assert_raises(LlmCallGuard::DailyLimitExceededError) do
        chat.with_schema(BulletRewriter::Schema).ask("1. Built a thing")
      end
    end
  end

  test "resolving a chat does not consume cap headroom on its own" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "true"
    ENV["MAX_LLM_CALLS_PER_DAY"] = "2"

    with_recording_chat do
      5.times { LlmCallGuard.chat }

      assert_nil Rails.cache.read(counter_key)
    end
  end

  test "the daily counter moves once per real provider request across a whole optimization" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "true"
    ENV["MAX_LLM_CALLS_PER_DAY"] = "1000"

    sizes = with_recording_chat do |log|
      Resume::Optimization.call(resume: resume_with_experiences(3), job_description_text: "Anything.")
      log
    end

    assert_equal 3, sizes.size, "expected one provider request per experience"
    assert_equal sizes.size, Rails.cache.read(counter_key).to_i,
      "expected the daily counter to move once per real provider request"
  end

  test "the request payload does not grow across calls" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "true"
    ENV["MAX_LLM_CALLS_PER_DAY"] = "1000"

    sizes = with_recording_chat do |log|
      Resume::Optimization.call(resume: resume_with_experiences(3), job_description_text: "Anything.")
      log
    end

    assert_equal [ 1, 1, 1 ], sizes,
      "each rewrite must send exactly one message; a growing count means a RubyLLM::Chat is being shared"
  end

  test "with_schema returns a new handle rather than mutating the shared one" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "true"
    ENV["MAX_LLM_CALLS_PER_DAY"] = "1000"

    with_recording_chat do
      chat = LlmCallGuard.chat
      scoped = chat.with_schema(BulletRewriter::Schema)

      refute_same chat, scoped
      assert_nil chat.schema, "the base handle must not inherit a schema set on a derived one"
      assert_equal BulletRewriter::Schema, scoped.schema
    end
  end

  test "the pre-flight check refuses a flow that cannot fit, before spending anything" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "true"
    ENV["MAX_LLM_CALLS_PER_DAY"] = "2"

    sizes = with_recording_chat do |log|
      assert_raises(LlmCallGuard::DailyLimitExceededError) do
        Resume::Optimization.call(resume: resume_with_experiences(3), job_description_text: "Anything.")
      end
      log
    end

    assert_empty sizes, "pre-flight must refuse before issuing any provider request"
    assert_nil Rails.cache.read(counter_key)
  end

  test "the pre-flight check ignores experiences with no bullets" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "true"
    ENV["MAX_LLM_CALLS_PER_DAY"] = "2"

    resume = Resume.new(name: "Alex Doe")
    resume.experiences.build(company: "A", title: "Engineer", bullets: [ "Built a thing" ], position: 0)
    resume.experiences.build(company: "B", title: "Engineer", bullets: [], position: 1)
    resume.experiences.build(company: "C", title: "Engineer", bullets: [ "Led a team" ], position: 2)

    sizes = with_recording_chat do |log|
      Resume::Optimization.call(resume: resume, job_description_text: "Anything.")
      log
    end

    assert_equal 2, sizes.size, "an experience with no bullets costs no provider request"
  end

  # The pre-flight check does not reserve, so two concurrent flows can both
  # pass it and then both consume. record_call! aborting per request is what
  # makes the cap hold anyway — this exercises that path directly, with
  # pre-flight bypassed.
  test "the per-request backstop still holds when the pre-flight check is bypassed" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "true"
    ENV["MAX_LLM_CALLS_PER_DAY"] = "2"

    with_recording_chat do
      2.times do
        BulletRewriter.call(bullets: [ "Built a thing" ], job_description_text: "Anything.")
      end

      assert_raises(LlmCallGuard::DailyLimitExceededError) do
        BulletRewriter.call(bullets: [ "Built a thing" ], job_description_text: "Anything.")
      end
    end
  end

  private

  def counter_key
    "llm_call_guard/calls_on/#{Date.current}"
  end

  def resume_with_experiences(count)
    resume = Resume.new(name: "Alex Doe")
    count.times do |index|
      resume.experiences.build(
        company: "Company #{index}", title: "Engineer",
        bullets: [ "Built thing number #{index}" ], position: index
      )
    end
    resume
  end

  # Replaces RubyLLM.chat — the seam LlmCallGuard itself uses — so no real
  # connection is ever built. Yields the log of messages-array sizes seen at
  # each ask, one entry per provider request.
  def with_recording_chat
    log = []
    original = RubyLLM.method(:chat)
    RubyLLM.define_singleton_method(:chat) { |*, **| RecordingChat.new(log) }
    yield log
  ensure
    RubyLLM.define_singleton_method(:chat, original)
  end
end
