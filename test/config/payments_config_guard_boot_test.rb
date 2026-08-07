require "test_helper"
require "open3"

# Boots a real production environment in a subprocess and asserts it refuses
# to start without Stripe credentials/Price ids configured (issue #123). Same
# technique and same reason as the other three boot tests in this directory
# (issue #84): the rule in Payments::ConfigGuard.validate_configuration! is
# worth nothing if config/initializers/payments_config_guard.rb stops calling
# it, and no in-process unit test of the method can tell the difference.
class PaymentsConfigGuardBootTest < ActiveSupport::TestCase
  # Initializers load alphabetically: "authentication_..." < "llm_call_guard"
  # < "payments_config_guard" < "usage_quota" -- so authentication's and
  # LlmCallGuard's guards fire before this one and must already be satisfied
  # in BASE_ENV, or a test aimed at Payments::ConfigGuard would actually be
  # failing on an earlier guard instead. usage_quota fires after this one, so
  # it only needs satisfying for the "boots normally" counterweight below.
  BASE_ENV = {
    "RAILS_ENV" => "production",
    "SECRET_KEY_BASE" => "0" * 64,
    "SECRET_KEY_BASE_DUMMY" => nil,
    "ENABLE_REAL_LLM_CALLS" => "true",
    "MAX_LLM_CALLS_PER_DAY" => "200",
    "ANTHROPIC_API_KEY" => "sk-ant-not-a-real-key",
    "GOOGLE_OAUTH_CLIENT_ID" => "test-client-id",
    "GOOGLE_OAUTH_CLIENT_SECRET" => "test-client-secret",
    "STRIPE_SECRET_KEY" => nil,
    "STRIPE_WEBHOOK_SECRET" => nil,
    "STRIPE_PRICE_ID_5_CREDITS" => nil,
    "STRIPE_PRICE_ID_15_CREDITS" => nil,
    "STRIPE_PRICE_ID_UNLIMITED_30_DAYS" => nil
  }.freeze

  QUOTA_ENV = Usage::Quota::ACTION_TYPES.to_h { |a| [ Usage::Quota.env_var_for(a), "200" ] }.freeze

  STRIPE_ENV = {
    "STRIPE_SECRET_KEY" => "sk_test_not_a_real_key",
    "STRIPE_WEBHOOK_SECRET" => "whsec_not_a_real_secret",
    "STRIPE_PRICE_ID_5_CREDITS" => "price_test_5",
    "STRIPE_PRICE_ID_15_CREDITS" => "price_test_15",
    "STRIPE_PRICE_ID_UNLIMITED_30_DAYS" => "price_test_unlimited"
  }.freeze

  def boot_production(**overrides)
    Open3.capture2e(
      BASE_ENV.merge(overrides.transform_keys(&:to_s)),
      Rails.root.join("bin/rails").to_s, "runner", "puts 'BOOTED-OK'",
      chdir: Rails.root.to_s
    ).first
  end

  test "a production boot refuses to start with no Stripe configuration at all" do
    output = boot_production

    assert_match(/Payments::ConfigGuard::ConfigurationError/, output)
    assert_match(/STRIPE_SECRET_KEY is not set/, output)
    refute_match(/BOOTED-OK/, output, "the app must not finish booting with no Stripe configuration")
  end

  # One at a time, same reasoning as the other three boot tests' equivalent
  # case: a check that only fires when everything is missing would let a
  # deploy that forgot exactly one variable ship with either purchases
  # failing at request time or the webhook silently unverifiable.
  test "a production boot refuses to start when any single required var is missing" do
    Payments::ConfigGuard::REQUIRED_ENV_VARS.each do |missing_var|
      present = STRIPE_ENV.reject { |k, _| k == missing_var }
      output = boot_production(**present)

      assert_match(/#{Regexp.escape(missing_var)} is not set/, output, "expected a refusal naming #{missing_var}")
      refute_match(/BOOTED-OK/, output, "must not boot with #{missing_var} missing")
    end
  end

  # The counterweight: without this, the assertions above would pass against
  # an app that could not boot production for some entirely unrelated reason.
  test "a production boot with everything configured starts normally" do
    output = boot_production(**QUOTA_ENV, **STRIPE_ENV)

    assert_match(/BOOTED-OK/, output)
    refute_match(/ConfigurationError/, output)
  end
end
