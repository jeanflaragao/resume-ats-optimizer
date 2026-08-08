require "test_helper"
require "open3"

# Boots a real production environment in a subprocess and asserts it refuses to
# start on a missing or unusable per-action quota (issue #22, ADR-0023).
#
# Same technique and same reason as test/config/llm_call_guard_boot_test.rb
# (issue #84): the rules in Usage::Quota.validate_configuration! are worth
# nothing if config/initializers/usage_quota.rb stops calling them, and no
# in-process unit test of the method can tell the difference. The unit tests in
# test/services/usage/quota_test.rb check the rules; this checks that they run.
class UsageQuotaBootTest < ActiveSupport::TestCase
  # The LLM guard's initializer runs first (initializers load alphabetically),
  # so every case here has to get past it before the quota check is even
  # reached. Configured, not bypassed -- bypassing it would mean asserting
  # against a boot that fails for a reason this file does not control.
  BASE_ENV = {
    "RAILS_ENV" => "production",
    "SECRET_KEY_BASE" => "0" * 64,
    "SECRET_KEY_BASE_DUMMY" => nil,
    "ENABLE_REAL_LLM_CALLS" => "true",
    "MAX_LLM_CALLS_PER_DAY" => "200",
    "ALLOW_STUB_LLM" => nil,
    "ANTHROPIC_API_KEY" => "sk-ant-not-a-real-key",
    # Issue #120's Authentication::ConfigGuard loads before both this guard
    # and LlmCallGuard's (alphabetically first) -- set here to valid values
    # for the same reason the LLM vars above are, so every case below still
    # gets past it to exercise Usage::Quota's own rule.
    "GOOGLE_OAUTH_CLIENT_ID" => "test-client-id",
    "GOOGLE_OAUTH_CLIENT_SECRET" => "test-client-secret",
    # Issue #123's Payments::ConfigGuard also loads before this one
    # ("payments_config_guard" < "usage_quota" alphabetically) -- same reason,
    # same fix.
    "STRIPE_SECRET_KEY" => "sk_test_not_a_real_key",
    "STRIPE_WEBHOOK_SECRET" => "whsec_not_a_real_secret",
    "STRIPE_PRICE_ID_5_CREDITS" => "price_test_5",
    "STRIPE_PRICE_ID_15_CREDITS" => "price_test_15",
    "STRIPE_PRICE_ID_UNLIMITED_30_DAYS" => "price_test_unlimited"
  }.freeze

  QUOTA_ENV = Usage::Quota::ACTION_TYPES.to_h { |a| [ Usage::Quota.env_var_for(a), "200" ] }.freeze

  def boot_production(**overrides)
    Open3.capture2e(
      BASE_ENV.merge(overrides.transform_keys(&:to_s)),
      Rails.root.join("bin/rails").to_s, "runner", "puts 'BOOTED-OK'",
      chdir: Rails.root.to_s
    ).first
  end

  test "a production boot refuses to start with no quotas configured" do
    output = boot_production(**QUOTA_ENV.transform_values { nil })

    assert_match(/Usage::Quota::ConfigurationError/, output)
    refute_match(/BOOTED-OK/, output, "the app must not finish booting on Usage::Quota's local-testing defaults")
  end

  # One at a time, because a check that only fires when everything is missing
  # would let a deploy that forgot exactly one action ship with a laptop-sized
  # limit on it -- the failure ADR-0023 says is silent in both directions.
  test "a production boot refuses to start when any single quota is unset" do
    Usage::Quota::ACTION_TYPES.each do |missing|
      var = Usage::Quota.env_var_for(missing)
      output = boot_production(**QUOTA_ENV, var => nil)

      assert_match(/#{var} is not set/, output)
      refute_match(/BOOTED-OK/, output, "#{var} being unset must stop the boot")
    end
  end

  test "a production boot refuses to start on a non-positive quota" do
    output = boot_production(**QUOTA_ENV, "RATE_LIMIT_PDF_GENERATION_PER_DAY" => "0")

    assert_match(/must be a positive integer/, output)
    refute_match(/BOOTED-OK/, output)
  end

  # The counterweight, as in the LLM guard's boot test: without it every
  # assertion above would pass against an app that could not boot production for
  # some entirely unrelated reason.
  test "a production boot with every quota set starts normally" do
    output = boot_production(**QUOTA_ENV)

    assert_match(/BOOTED-OK/, output)
    refute_match(/ConfigurationError/, output)
  end
end
