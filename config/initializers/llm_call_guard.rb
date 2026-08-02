# Refuses to finish booting a production deploy that inherited LlmCallGuard's
# local-testing defaults (issue #77, ADR-0020). The rules live in
# LlmCallGuard.validate_configuration! so they can be unit-tested; this file
# only decides *when* they run.
#
# to_prepare rather than a bare call: LlmCallGuard lives in app/services and is
# autoloadable, and referencing an autoloadable constant during initialization
# is unsupported under Zeitwerk. to_prepare blocks run inside
# Rails.application.initialize!, so raising here still aborts boot, and the
# check re-runs harmlessly on each development reload.
#
# Two things about the env guard, and the second one is the trap:
#
# (a) It is about *constant loading*, not about validation scope. Referencing
#     LlmCallGuard here unguarded autoloads app/services/llm_call_guard.rb during
#     boot in every environment, and a file loaded before
#     ActiveSupport::Testing::Parallelization forks is inherited already-loaded by
#     every worker, so SimpleCov never instruments it and reports the whole file
#     as 0% covered. Measured: 88.25% overall with the reference unguarded,
#     98.70% with it guarded, same tests, against a minimum_coverage 90 gate.
#
# (b) LlmCallGuard.validate_configuration! remains the sole authority on WHICH
#     environments get validated — it checks Rails.env itself and no-ops outside
#     production. This guard must therefore never be read as the env policy. If
#     the policy ever widens (say, validating a staging environment too), it has
#     to change in BOTH places: relax the method's own `return unless
#     env.production?`, and relax this condition, or the method will simply never
#     be called there and the check will go silently missing.
#
# The guard is load-bearing for the coverage gate but invisible to the suite's
# normal assertions, so the boot behaviour it controls is verified by booting a
# real production environment in a subprocess instead — see
# test/config/llm_call_guard_boot_test.rb.
Rails.application.config.to_prepare do
  LlmCallGuard.validate_configuration! if Rails.env.production?
end
