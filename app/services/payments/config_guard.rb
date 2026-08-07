# Boot-time check that production has real Stripe credentials and Price ids,
# the same shape as LlmCallGuard/Usage::Quota/Authentication::ConfigGuard
# (ADR-0020): a missing one must fail the deploy at boot, not surface as a
# broken "Buy credits" button or a silently-unverifiable webhook to the first
# real visitor. Called from config/initializers/payments_config_guard.rb;
# extracted here so the rule is unit-testable without booting a second Rails
# environment.
#
# No stub-mode/ENABLE_REAL_* toggle the way LlmCallGuard has one: Stripe's own
# test-mode secret key (sk_test_...) is already a free, safe-to-call sandbox --
# unlike the Anthropic API, there's no real-money cost in dev to guard
# against, so there's no "mode" to validate, only presence.
class Payments::ConfigGuard
  # Raised at boot, not at first checkout/webhook request.
  class ConfigurationError < StandardError; end

  REQUIRED_ENV_VARS = %w[
    STRIPE_SECRET_KEY
    STRIPE_WEBHOOK_SECRET
    STRIPE_PRICE_ID_5_CREDITS
    STRIPE_PRICE_ID_15_CREDITS
    STRIPE_PRICE_ID_UNLIMITED_30_DAYS
  ].freeze

  # env is injectable so the production rule can be tested directly.
  def self.validate_configuration!(env: Rails.env)
    # Same build-time exemption as every other guard -- the image build
    # boots Rails under RAILS_ENV=production with no deploy environment and
    # never reaches a checkout or webhook request.
    return if ENV.key?("SECRET_KEY_BASE_DUMMY")
    return unless env.production?

    REQUIRED_ENV_VARS.each do |var|
      next if ENV[var].present?

      raise ConfigurationError,
        "#{var} is not set. It has no default in production: Stripe purchases would fail " \
        "for every visitor at request time (or worse, a webhook would be unverifiable) " \
        "instead of refusing to boot."
    end
  end
end
