require "test_helper"
require "open3"

# Boots a real production environment in a subprocess and asserts it refuses to
# start. A structural assertion about boot rather than behaviour, in the same
# spirit as test/config/cache_test.rb — and the only kind that can see this:
# the production rules in LlmCallGuard.validate_configuration! are worth nothing
# if config/initializers/llm_call_guard.rb stops calling them, and no in-process
# unit test of the method can tell the difference (issue #84).
#
# It also verifies issue #77's acceptance criterion 1 literally — "a production
# deploy cannot start in stub mode without that being explicit" — rather than by
# proxy.
class LlmCallGuardBootTest < ActiveSupport::TestCase
  # A production boot needs a secret_key_base; SECRET_KEY_BASE supplies one
  # without config/master.key. Deliberately NOT SECRET_KEY_BASE_DUMMY, which is
  # the guard's own build-time exemption and would skip the very check under
  # test. nil values delete the variable in the child, so the result does not
  # depend on what docker-compose.yml happens to set for the test container.
  BASE_ENV = {
    "RAILS_ENV" => "production",
    "SECRET_KEY_BASE" => "0" * 64,
    "SECRET_KEY_BASE_DUMMY" => nil,
    "ENABLE_REAL_LLM_CALLS" => nil,
    "MAX_LLM_CALLS_PER_DAY" => nil,
    "ALLOW_STUB_LLM" => nil,
    "ANTHROPIC_API_KEY" => nil,
    # Issue #120 added a third boot check (config/initializers/
    # authentication_config_guard.rb, ADR-0032) that loads BEFORE this one --
    # initializers load alphabetically, "authentication_..." < "llm_...". Set
    # here to valid values so every case below still exercises LlmCallGuard's
    # own rule, not Authentication::ConfigGuard's.
    "GOOGLE_OAUTH_CLIENT_ID" => "test-client-id",
    "GOOGLE_OAUTH_CLIENT_SECRET" => "test-client-secret"
  }.freeze

  # Issue #22 added a second boot check (config/initializers/usage_quota.rb,
  # ADR-0023) with its own four required variables. It runs after this one --
  # initializers load alphabetically, llm_call_guard before usage_quota -- so
  # the two refusal tests below are unaffected: they never get that far. The
  # "boots normally" counterweight does, and has to satisfy both checks or it
  # would pass for the wrong reason, reporting a refusal from the wrong guard.
  # The quota guard's own boot cases live in test/config/usage_quota_boot_test.rb.
  QUOTA_ENV = Usage::Quota::ACTION_TYPES.to_h { |a| [ Usage::Quota.env_var_for(a), "200" ] }.freeze

  def boot_production(**overrides)
    Open3.capture2e(
      BASE_ENV.merge(overrides.transform_keys(&:to_s)),
      Rails.root.join("bin/rails").to_s, "runner", "puts 'BOOTED-OK'",
      chdir: Rails.root.to_s
    ).first
  end

  test "a production boot with nothing configured refuses to start" do
    output = boot_production

    assert_match(/ConfigurationError/, output)
    assert_match(/ENABLE_REAL_LLM_CALLS is not set/, output)
    refute_match(/BOOTED-OK/, output, "the app must not finish booting on the local-testing defaults")
  end

  test "a production boot in stub mode refuses to start without the explicit opt-in" do
    output = boot_production("ENABLE_REAL_LLM_CALLS" => "false", "MAX_LLM_CALLS_PER_DAY" => "200")

    assert_match(/ALLOW_STUB_LLM/, output)
    refute_match(/BOOTED-OK/, output, "stub mode in production must be opted into, not defaulted into")
  end

  # LlmCallGuard.validate_api_key! exists specifically for this (ADR-0020), but
  # until now nothing asserted it fires -- config/initializers/ruby_llm.rb's own
  # ANTHROPIC_API_KEY read is a bare ENV[] with no validation of its own, and is
  # safe only because this check has already had the chance to abort boot first
  # (registration order, both to_prepare). Confirmed manually before this test
  # existed: booting with real calls on and the key blanked raised
  # LlmCallGuard::ConfigurationError as expected -- this pins that behaviour so
  # it stays proven rather than merely observed once.
  test "a production boot with real calls enabled but no API key refuses to start" do
    output = boot_production("ENABLE_REAL_LLM_CALLS" => "true", "MAX_LLM_CALLS_PER_DAY" => "200")

    assert_match(/ConfigurationError/, output)
    assert_match(/ANTHROPIC_API_KEY is not set/, output)
    refute_match(/BOOTED-OK/, output, "real LLM calls must not run with no key configured")
  end

  # The counterweight: without this, none of the assertions above would pass
  # against an app that could not boot production for some entirely unrelated
  # reason.
  test "a production boot with everything configured starts normally" do
    output = boot_production(
      "ENABLE_REAL_LLM_CALLS" => "true",
      "MAX_LLM_CALLS_PER_DAY" => "200",
      "ANTHROPIC_API_KEY" => "sk-ant-not-a-real-key",
      **QUOTA_ENV
    )

    assert_match(/BOOTED-OK/, output)
    refute_match(/ConfigurationError/, output)
  end
end
