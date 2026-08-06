# Refuses to finish booting a production deploy with no Google OAuth
# credentials configured (issue #120, ADR-0032). The rule lives in
# Authentication::ConfigGuard.validate_configuration! so it can be
# unit-tested; this file only decides *when* it runs.
#
# Same to_prepare + Rails.env.production? shape as
# config/initializers/llm_call_guard.rb and config/initializers/usage_quota.rb,
# for the same two reasons: Authentication::ConfigGuard is autoloadable
# (app/services), so referencing it unguarded at plain top-level is
# unsupported under Zeitwerk and would autoload the file in every environment,
# costing SimpleCov's coverage measurement across parallel test workers; and
# Authentication::ConfigGuard.validate_configuration! remains the sole
# authority on WHICH environments get validated (it checks Rails.env itself).
# If that policy ever widens, both places have to change together.
#
# Verified by booting a real production environment in a subprocess — see
# test/config/authentication_config_guard_boot_test.rb — for the same reason
# the other two guards are verified that way: this guard is invisible to the
# suite's normal in-process assertions.
Rails.application.config.to_prepare do
  Authentication::ConfigGuard.validate_configuration! if Rails.env.production?
end
