# Boot-time check that production has real Google OAuth credentials, the same
# shape as LlmCallGuard.validate_configuration!/Usage::Quota.validate_configuration!
# (ADR-0020, ADR-0023): a missing credential must fail the deploy at boot, not
# surface as "sign-in failed" to the first real visitor. Called from
# config/initializers/authentication_config_guard.rb; extracted here so the
# rule is unit-testable without booting a second Rails environment.
module Authentication
  class ConfigGuard
    # Raised at boot, not at first sign-in attempt.
    class ConfigurationError < StandardError; end

    REQUIRED_ENV_VARS = %w[GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET].freeze

    # env is injectable so the production rule can be tested directly.
    def self.validate_configuration!(env: Rails.env)
      # Same build-time exemption as LlmCallGuard/Usage::Quota — the image
      # build boots Rails under RAILS_ENV=production with no deploy
      # environment and never reaches a sign-in flow.
      return if ENV.key?("SECRET_KEY_BASE_DUMMY")
      return unless env.production?

      REQUIRED_ENV_VARS.each do |var|
        next if ENV[var].present?

        raise ConfigurationError,
          "#{var} is not set. It has no default in production: Google OAuth sign-in would fail " \
          "for every visitor at request time instead of refusing to boot."
      end
    end
  end
end
