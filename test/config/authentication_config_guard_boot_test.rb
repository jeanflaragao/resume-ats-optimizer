require "test_helper"
require "open3"

# Boots a real production environment in a subprocess and asserts it refuses to
# start without Google OAuth credentials (issue #120, ADR-0032). Same
# technique and same reason as test/config/llm_call_guard_boot_test.rb and
# test/config/usage_quota_boot_test.rb (issue #84): the rule in
# Authentication::ConfigGuard.validate_configuration! is worth nothing if
# config/initializers/authentication_config_guard.rb stops calling it, and no
# in-process unit test of the method can tell the difference.
class AuthenticationConfigGuardBootTest < ActiveSupport::TestCase
  # authentication_config_guard.rb loads before llm_call_guard.rb and
  # usage_quota.rb (initializers load alphabetically: "authentication_..." <
  # "llm_..." < "usage_..."), so this guard fires first — the LLM/quota vars
  # below only matter for the "boots normally" counterweight, which has to
  # satisfy all three guards or it would pass for the wrong reason.
  BASE_ENV = {
    "RAILS_ENV" => "production",
    "SECRET_KEY_BASE" => "0" * 64,
    "SECRET_KEY_BASE_DUMMY" => nil,
    "ENABLE_REAL_LLM_CALLS" => "true",
    "MAX_LLM_CALLS_PER_DAY" => "200",
    "ANTHROPIC_API_KEY" => "sk-ant-not-a-real-key",
    "GOOGLE_OAUTH_CLIENT_ID" => nil,
    "GOOGLE_OAUTH_CLIENT_SECRET" => nil
  }.freeze

  QUOTA_ENV = Usage::Quota::ACTION_TYPES.to_h { |a| [ Usage::Quota.env_var_for(a), "200" ] }.freeze

  OAUTH_ENV = {
    "GOOGLE_OAUTH_CLIENT_ID" => "test-client-id",
    "GOOGLE_OAUTH_CLIENT_SECRET" => "test-client-secret"
  }.freeze

  def boot_production(**overrides)
    Open3.capture2e(
      BASE_ENV.merge(overrides.transform_keys(&:to_s)),
      Rails.root.join("bin/rails").to_s, "runner", "puts 'BOOTED-OK'",
      chdir: Rails.root.to_s
    ).first
  end

  test "a production boot refuses to start with no Google OAuth credentials configured" do
    output = boot_production

    assert_match(/Authentication::ConfigGuard::ConfigurationError/, output)
    assert_match(/GOOGLE_OAUTH_CLIENT_ID is not set/, output)
    refute_match(/BOOTED-OK/, output, "the app must not finish booting with no Google OAuth credentials")
  end

  # One at a time, same reasoning as usage_quota_boot_test.rb's equivalent
  # case: a check that only fires when both are missing would let a deploy
  # that forgot exactly one variable ship with sign-in silently broken.
  test "a production boot refuses to start when only one of the two variables is set" do
    output = boot_production("GOOGLE_OAUTH_CLIENT_ID" => "test-client-id")

    assert_match(/GOOGLE_OAUTH_CLIENT_SECRET is not set/, output)
    refute_match(/BOOTED-OK/, output)
  end

  # The counterweight: without this, the assertions above would pass against
  # an app that could not boot production for some entirely unrelated reason.
  test "a production boot with everything configured starts normally" do
    output = boot_production(**QUOTA_ENV, **OAUTH_ENV)

    assert_match(/BOOTED-OK/, output)
    refute_match(/ConfigurationError/, output)
  end
end
