# Refuses to finish booting a production deploy that inherited Usage::Quota's
# local-testing defaults (issue #22, ADR-0023). Deliberately identical in shape
# to config/initializers/llm_call_guard.rb (issue #77, ADR-0020) — same failure
# mode, same remedy, so the two should stay recognisably the same file.
#
# to_prepare rather than a bare call: Usage::Quota lives in app/services and is
# autoloadable, and referencing an autoloadable constant during initialization
# is unsupported under Zeitwerk. to_prepare blocks run inside
# Rails.application.initialize!, so raising here still aborts boot.
#
# The `if Rails.env.production?` guard is about *constant loading*, not about
# validation scope — the same trap documented at length in the LlmCallGuard
# initializer. Referencing Usage::Quota here unguarded autoloads it during boot
# in every environment, and a file loaded before
# ActiveSupport::Testing::Parallelization forks is inherited already-loaded by
# every worker, so SimpleCov never instruments it and reports the whole file as
# 0% covered against test_helper.rb's minimum_coverage 90 gate.
#
# Usage::Quota.validate_configuration! remains the sole authority on WHICH
# environments are validated: it checks Rails.env itself and no-ops outside
# production. Widening the policy means relaxing it in BOTH places, or the
# method will simply never be called and the check will go silently missing.
Rails.application.config.to_prepare do
  Usage::Quota.validate_configuration! if Rails.env.production?
end
