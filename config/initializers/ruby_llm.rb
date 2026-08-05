require "ruby_llm/schema" # not auto-required by ruby_llm; needed for RubyLLM::Schema subclasses

# Deferred to to_prepare, not called bare at the top level: ANTHROPIC_API_KEY has no
# validation of its own here (a bare ENV[] tolerates nil), and its only real
# guard is LlmCallGuard.validate_api_key! (app/services/llm_call_guard.rb,
# ADR-0020), registered from config/initializers/llm_call_guard.rb's own
# to_prepare block. Rails runs to_prepare callbacks in registration order as
# part of Rails.application.initialize!, and llm_call_guard.rb sorts before
# this file alphabetically, so that check has already had the chance to abort
# boot by the time this block runs -- RubyLLM is never configured with a key
# a production deploy would have already refused to boot without. This is
# about structural ordering, not Zeitwerk autoloading (RubyLLM is a plain gem
# constant, already require'd) -- unlike LlmCallGuard/Usage::Quota's own
# to_prepare blocks, nothing here is unsafe to reference at plain initializer
# time; the point is purely to run after the guard, not before it.
Rails.application.config.to_prepare do
  RubyLLM.configure do |config|
    config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
    config.default_model = "claude-sonnet-4-5"
  end
end
