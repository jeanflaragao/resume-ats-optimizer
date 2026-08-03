require "test_helper"

class Usage::QuotaTest < ActiveSupport::TestCase
  setup do
    @original_env = Usage::Quota::ACTION_TYPES.to_h { |a| [ Usage::Quota.env_var_for(a), ENV[Usage::Quota.env_var_for(a)] ] }
    @original_dummy_secret = ENV["SECRET_KEY_BASE_DUMMY"]
    ENV.delete("SECRET_KEY_BASE_DUMMY")
  end

  teardown do
    @original_env.each { |var, value| value.nil? ? ENV.delete(var) : ENV[var] = value }
    ENV["SECRET_KEY_BASE_DUMMY"] = @original_dummy_secret
    ENV.delete("SECRET_KEY_BASE_DUMMY") if @original_dummy_secret.nil?
  end

  # --- limits -----------------------------------------------------------

  test "limit_for reads the action's ENV variable" do
    ENV["RATE_LIMIT_PDF_GENERATION_PER_DAY"] = "3"

    assert_equal 3, Usage::Quota.limit_for(:pdf_generation)
  end

  test "limit_for falls back to the local default when the variable is unset" do
    ENV.delete("RATE_LIMIT_PDF_GENERATION_PER_DAY")

    assert_equal Usage::Quota::LOCAL_DEFAULTS[:pdf_generation], Usage::Quota.limit_for(:pdf_generation)
  end

  test "every action type has a local default, an env var and a label" do
    Usage::Quota::ACTION_TYPES.each do |action|
      assert Usage::Quota::LOCAL_DEFAULTS.key?(action), "#{action} has no local default"
      assert_equal "RATE_LIMIT_#{action.to_s.upcase}_PER_DAY", Usage::Quota.env_var_for(action)
      assert Usage::Quota.label_for(action).present?, "#{action} has no user-facing label"
    end
  end

  # The upload is one of the two non-fan-out Anthropic requests in issue #45's
  # 2 + 2E, and the first thing an anonymous visitor can trigger. Issue #22's
  # body omits it; ADR-0023 records adding it as a deliberate departure, and
  # this pins it so a later tidy-up back to "the three in the issue" has to
  # argue with a test.
  test "resume extraction is a quotaed action, not just the three named in issue #22" do
    assert_includes Usage::Quota::ACTION_TYPES, :resume_extraction
  end

  # --- consuming --------------------------------------------------------

  test "consume! returns the running count while under the limit" do
    ENV["RATE_LIMIT_PDF_GENERATION_PER_DAY"] = "3"

    counts = 3.times.map { Usage::Quota.consume!(subject: "token-a", action: :pdf_generation) }

    assert_equal [ 1, 2, 3 ], counts
  end

  test "consume! raises once the subject goes past the limit" do
    ENV["RATE_LIMIT_PDF_GENERATION_PER_DAY"] = "2"
    2.times { Usage::Quota.consume!(subject: "token-a", action: :pdf_generation) }

    error = assert_raises(Usage::Quota::ExceededError) do
      Usage::Quota.consume!(subject: "token-a", action: :pdf_generation)
    end

    assert_equal :pdf_generation, error.action
    assert_equal 2, error.limit
  end

  # NON-VACUITY (CLAUDE.md): this test was first run against a Usage::Counter.
  # consume! whose unique key omitted subject_token, so every subject shared one
  # row. It failed -- token-b was refused on its first request because token-a
  # had exhausted the shared counter. The failing output is in the PR body.
  #
  # This is the property that makes the mechanism per-subject rather than a
  # second global cap, which is the entire distinction between issue #22 and the
  # LlmCallGuard cap it sits next to.
  test "one subject exhausting its quota does not refuse another subject" do
    ENV["RATE_LIMIT_PDF_GENERATION_PER_DAY"] = "1"
    Usage::Quota.consume!(subject: "token-a", action: :pdf_generation)
    assert_raises(Usage::Quota::ExceededError) { Usage::Quota.consume!(subject: "token-a", action: :pdf_generation) }

    assert_equal 1, Usage::Quota.consume!(subject: "token-b", action: :pdf_generation),
      "token-b was charged for token-a's usage: the counter is not per subject"
  end

  # The counters are per action type precisely so a cheap action cannot spend an
  # expensive one's budget, which a single aggregate number would allow.
  test "exhausting one action's quota does not refuse a different action" do
    ENV["RATE_LIMIT_PDF_GENERATION_PER_DAY"] = "1"
    ENV["RATE_LIMIT_BULLET_REWRITING_PER_DAY"] = "1"
    Usage::Quota.consume!(subject: "token-a", action: :pdf_generation)
    assert_raises(Usage::Quota::ExceededError) { Usage::Quota.consume!(subject: "token-a", action: :pdf_generation) }

    assert_equal 1, Usage::Quota.consume!(subject: "token-a", action: :bullet_rewriting)
  end

  test "a quota exhausted yesterday does not carry into today" do
    ENV["RATE_LIMIT_PDF_GENERATION_PER_DAY"] = "1"
    travel_to(Date.current - 1) do
      Usage::Quota.consume!(subject: "token-a", action: :pdf_generation)
      assert_raises(Usage::Quota::ExceededError) { Usage::Quota.consume!(subject: "token-a", action: :pdf_generation) }
    end

    assert_equal 1, Usage::Quota.consume!(subject: "token-a", action: :pdf_generation)
  end

  # A blank subject would silently pool every caller into one shared row, which
  # looks like a working quota and is really a second global cap.
  test "consume! refuses a blank subject rather than pooling callers together" do
    assert_raises(ArgumentError) { Usage::Quota.consume!(subject: "", action: :pdf_generation) }
    assert_raises(ArgumentError) { Usage::Quota.consume!(subject: nil, action: :pdf_generation) }
  end

  test "consume! refuses an unknown action rather than quietly counting it" do
    assert_raises(ArgumentError) { Usage::Quota.consume!(subject: "token-a", action: :not_an_action) }
    assert_equal 0, Usage::Counter.count
  end

  # ExceededError must not be reachable through the global cap's rescue_from.
  # "you are out of budget" and "we are out of budget" get different advice, and
  # a subclass relationship would let ApplicationController's handler order
  # collapse them into one message.
  test "ExceededError is not a kind of LlmCallGuard::DailyLimitExceededError" do
    assert_not_operator Usage::Quota::ExceededError, :<=, LlmCallGuard::DailyLimitExceededError
  end

  # --- boot-time configuration (ADR-0020's rule, ADR-0023's variables) ----

  test "validate_configuration! is a no-op outside production" do
    Usage::Quota::ACTION_TYPES.each { |a| ENV.delete(Usage::Quota.env_var_for(a)) }

    assert_nothing_raised do
      Usage::Quota.validate_configuration!(env: ActiveSupport::StringInquirer.new("development"))
      Usage::Quota.validate_configuration!(env: ActiveSupport::StringInquirer.new("test"))
    end
  end

  test "production refuses to boot when any per-action limit is unset" do
    Usage::Quota::ACTION_TYPES.each do |missing|
      set_all_limits
      ENV.delete(Usage::Quota.env_var_for(missing))

      error = assert_raises(Usage::Quota::ConfigurationError) { validate_production! }
      assert_includes error.message, Usage::Quota.env_var_for(missing)
    end
  end

  test "production refuses to boot on a non-integer or non-positive limit" do
    [ "0", "-1", "many", "" ].each do |bad|
      set_all_limits
      ENV["RATE_LIMIT_PDF_GENERATION_PER_DAY"] = bad

      error = assert_raises(Usage::Quota::ConfigurationError) { validate_production! }
      assert_includes error.message, "must be a positive integer"
    end
  end

  test "production boots when every limit is set to a positive integer" do
    set_all_limits

    assert_nothing_raised { validate_production! }
  end

  # Dockerfile:50 boots Rails under RAILS_ENV=production to precompile assets,
  # with no deploy environment to read and no requests to quota. Without this
  # exemption the image build would fail (ADR-0020, same carve-out).
  test "the assets:precompile boot is exempt even with nothing configured" do
    Usage::Quota::ACTION_TYPES.each { |a| ENV.delete(Usage::Quota.env_var_for(a)) }
    ENV["SECRET_KEY_BASE_DUMMY"] = "1"

    assert_nothing_raised { validate_production! }
  end

  private

  def set_all_limits(value = "10")
    Usage::Quota::ACTION_TYPES.each { |a| ENV[Usage::Quota.env_var_for(a)] = value }
  end

  def validate_production!
    Usage::Quota.validate_configuration!(env: ActiveSupport::StringInquirer.new("production"))
  end
end
