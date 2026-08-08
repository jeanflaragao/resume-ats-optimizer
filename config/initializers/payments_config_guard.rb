# Refuses to finish booting a production deploy with no Stripe credentials/
# Price ids configured (issue #123). The rule lives in
# Payments::ConfigGuard.validate_configuration! so it can be unit-tested;
# this file only decides *when* it runs.
#
# Same to_prepare + Rails.env.production? shape as
# config/initializers/{llm_call_guard,usage_quota,authentication_config_guard}.rb,
# for the same two reasons: Payments::ConfigGuard is autoloadable
# (app/services), so referencing it unguarded at plain top-level is
# unsupported under Zeitwerk and would autoload the file in every environment,
# costing SimpleCov's coverage measurement across parallel test workers; and
# Payments::ConfigGuard.validate_configuration! remains the sole authority on
# WHICH environments get validated (it checks Rails.env itself). If that
# policy ever widens, both places have to change together.
#
# Sorts alphabetically before config/initializers/stripe.rb, so this guard's
# to_prepare block registers -- and therefore runs -- before that file's own,
# the same "validate before configure" ordering config/initializers/ruby_llm.rb
# relies on relative to llm_call_guard.rb.
#
# Verified by booting a real production environment in a subprocess -- see
# test/config/payments_config_guard_boot_test.rb -- for the same reason the
# other three guards are verified that way: this guard is invisible to the
# suite's normal in-process assertions.
Rails.application.config.to_prepare do
  Payments::ConfigGuard.validate_configuration! if Rails.env.production?
end
