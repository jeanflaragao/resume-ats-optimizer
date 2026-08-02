require "test_helper"

class LlmCallGuardTest < ActiveSupport::TestCase
  # RecordingChat and with_recording_chat used to live here as private helpers.
  # They moved to test/support/recording_llm.rb unchanged in behaviour once
  # test/integration/preview_download_reuse_test.rb needed to count the same
  # thing (issue #83); ActiveSupport::TestCase includes the module.

  setup do
    @original_enabled = ENV["ENABLE_REAL_LLM_CALLS"]
    @original_max_calls = ENV["MAX_LLM_CALLS_PER_DAY"]
    @original_allow_stub = ENV["ALLOW_STUB_LLM"]
    @original_api_key = ENV["ANTHROPIC_API_KEY"]
    @original_dummy_secret = ENV["SECRET_KEY_BASE_DUMMY"]
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
    ENV["ALLOW_STUB_LLM"] = @original_allow_stub
    ENV["ANTHROPIC_API_KEY"] = @original_api_key
    ENV["SECRET_KEY_BASE_DUMMY"] = @original_dummy_secret
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

  # Rails.cache.increment returns nil when the store cannot answer -- a cache
  # miss it could not initialise, or, in production, any of the transient
  # ActiveRecord errors Solid Cache's failsafe swallows (AdapterTimeout,
  # Deadlocked, LockWaitTimeout, ...). nil.to_i is 0, so before this the cap
  # silently stopped existing exactly when the database was in trouble.
  #
  # A distinct error, not DailyLimitExceededError: "we cannot verify the
  # budget" and "the budget is spent" need different advice to the user.
  test "fails closed when the call counter cannot be verified" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "true"
    ENV["MAX_LLM_CALLS_PER_DAY"] = "1000"
    Rails.cache = ActiveSupport::Cache::NullStore.new

    with_recording_chat do |log|
      assert_raises(LlmCallGuard::BudgetUnavailableError) do
        LlmCallGuard.chat.with_schema(BulletRewriter::Schema).ask("1. Built a thing")
      end

      assert_empty log, "must not issue a request whose cost it cannot account for"
    end
  end

  test "a counter that cannot be verified is not reported as a daily limit" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "true"
    ENV["MAX_LLM_CALLS_PER_DAY"] = "1000"
    Rails.cache = ActiveSupport::Cache::NullStore.new

    with_recording_chat do
      error = assert_raises(LlmCallGuard::BudgetUnavailableError) do
        LlmCallGuard.chat.with_schema(BulletRewriter::Schema).ask("1. Built a thing")
      end

      refute_kind_of LlmCallGuard::DailyLimitExceededError, error
    end
  end

  # --- Boot-time configuration checks (issue #77) ------------------------
  #
  # env is injected rather than these booting a second Rails environment. The
  # counterpart assertion — that the initializer actually calls this — lives in
  # test/config/llm_call_guard_boot_test.rb, because nothing here can see a
  # deleted initializer.

  test "production boots when real calls, the cap, and the API key are all set explicitly" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "true"
    ENV["MAX_LLM_CALLS_PER_DAY"] = "200"
    ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"

    assert_nothing_raised { LlmCallGuard.validate_configuration!(env: production) }
  end

  test "production refuses to boot when ENABLE_REAL_LLM_CALLS is unset" do
    ENV.delete("ENABLE_REAL_LLM_CALLS")
    ENV["MAX_LLM_CALLS_PER_DAY"] = "200"
    ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"

    error = assert_raises(LlmCallGuard::ConfigurationError) do
      LlmCallGuard.validate_configuration!(env: production)
    end
    assert_includes error.message, "ENABLE_REAL_LLM_CALLS is not set"
  end

  test "production refuses to boot when MAX_LLM_CALLS_PER_DAY is unset" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "true"
    ENV.delete("MAX_LLM_CALLS_PER_DAY")
    ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"

    error = assert_raises(LlmCallGuard::ConfigurationError) do
      LlmCallGuard.validate_configuration!(env: production)
    end
    assert_includes error.message, "MAX_LLM_CALLS_PER_DAY is not set"
  end

  # Explicitly false is not a mode — it is the state that ships StubChat's
  # label into every user's summary, job title, and bullets.
  test "production refuses to boot in stub mode without the separate opt-in" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "false"
    ENV.delete("ALLOW_STUB_LLM")
    ENV["MAX_LLM_CALLS_PER_DAY"] = "200"

    error = assert_raises(LlmCallGuard::ConfigurationError) do
      LlmCallGuard.validate_configuration!(env: production)
    end
    assert_includes error.message, "ALLOW_STUB_LLM"
  end

  test "production boots in stub mode when it is explicitly allowed" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "false"
    ENV["ALLOW_STUB_LLM"] = "true"
    ENV["MAX_LLM_CALLS_PER_DAY"] = "200"
    ENV.delete("ANTHROPIC_API_KEY")

    assert_nothing_raised { LlmCallGuard.validate_configuration!(env: production) }
  end

  # Mandatory even where it is never read, so that flipping ALLOW_STUB_LLM off
  # is a one-variable change that cannot half-fail.
  test "the cap is required even when stub mode is explicitly allowed" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "false"
    ENV["ALLOW_STUB_LLM"] = "true"
    ENV.delete("MAX_LLM_CALLS_PER_DAY")

    assert_raises(LlmCallGuard::ConfigurationError) do
      LlmCallGuard.validate_configuration!(env: production)
    end
  end

  test "production refuses to boot on a cap that is not a positive integer" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "true"
    ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"

    [ "", "ten", "0", "-1", "10.5" ].each do |value|
      ENV["MAX_LLM_CALLS_PER_DAY"] = value

      error = assert_raises(LlmCallGuard::ConfigurationError, "expected #{value.inspect} to be refused") do
        LlmCallGuard.validate_configuration!(env: production)
      end
      assert_includes error.message, "positive integer"
    end
  end

  # config/initializers/ruby_llm.rb reads this with a bare ENV[], so an unset
  # key is invisible until the first user's upload fails.
  test "production refuses to boot with real calls enabled and no API key" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "true"
    ENV["MAX_LLM_CALLS_PER_DAY"] = "200"
    ENV.delete("ANTHROPIC_API_KEY")

    error = assert_raises(LlmCallGuard::ConfigurationError) do
      LlmCallGuard.validate_configuration!(env: production)
    end
    assert_includes error.message, "ANTHROPIC_API_KEY is not set"
  end

  test "production refuses to boot with real calls enabled and a blank API key" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "true"
    ENV["MAX_LLM_CALLS_PER_DAY"] = "200"
    ENV["ANTHROPIC_API_KEY"] = "   "

    assert_raises(LlmCallGuard::ConfigurationError) do
      LlmCallGuard.validate_configuration!(env: production)
    end
  end

  # Dockerfile:50 boots Rails under RAILS_ENV=production to precompile assets,
  # with no deploy-time environment to validate and no LLM request to make.
  test "the image build is exempt, and only via SECRET_KEY_BASE_DUMMY" do
    ENV.delete("ENABLE_REAL_LLM_CALLS")
    ENV.delete("MAX_LLM_CALLS_PER_DAY")
    ENV.delete("ANTHROPIC_API_KEY")
    ENV["SECRET_KEY_BASE_DUMMY"] = "1"

    assert_nothing_raised { LlmCallGuard.validate_configuration!(env: production) }

    ENV.delete("SECRET_KEY_BASE_DUMMY")
    assert_raises(LlmCallGuard::ConfigurationError) do
      LlmCallGuard.validate_configuration!(env: production)
    end
  end

  test "development keeps its defaults and never refuses to boot" do
    ENV.delete("ENABLE_REAL_LLM_CALLS")
    ENV.delete("MAX_LLM_CALLS_PER_DAY")
    ENV.delete("ANTHROPIC_API_KEY")

    assert_nothing_raised do
      LlmCallGuard.validate_configuration!(env: ActiveSupport::EnvironmentInquirer.new("development"))
    end
    refute LlmCallGuard.enabled?, "stub mode must stay the local default"
    assert_equal 10, LlmCallGuard.max_calls_per_day
  end

  test "the stub-mode banner appears outside local environments only" do
    ENV["ENABLE_REAL_LLM_CALLS"] = "false"

    assert LlmCallGuard.stub_mode?
    assert LlmCallGuard.stub_mode_banner?(env: production)
    refute LlmCallGuard.stub_mode_banner?(env: ActiveSupport::EnvironmentInquirer.new("development"))
    refute LlmCallGuard.stub_mode_banner?(env: ActiveSupport::EnvironmentInquirer.new("test"))

    ENV["ENABLE_REAL_LLM_CALLS"] = "true"
    refute LlmCallGuard.stub_mode?
    refute LlmCallGuard.stub_mode_banner?(env: production), "real calls must never show a demo-mode banner"
  end

  private

  def production
    ActiveSupport::EnvironmentInquirer.new("production")
  end

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
end
