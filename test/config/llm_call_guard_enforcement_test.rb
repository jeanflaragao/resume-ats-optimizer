require "test_helper"

class LlmCallGuardEnforcementTest < ActiveSupport::TestCase
  # Structural test, not a behavior test: guards against a call site being
  # written that bypasses LlmCallGuard's request counter, per ADR-0019.
  # Deliberately a plain grep — must fail on the offending line before it ever
  # runs, and must not depend on the new call site having its own test coverage.
  #
  # Known blind spot: aliasing (e.g. `Chat = RubyLLM::Chat`) will not be caught.
  test "RubyLLM chats are only built inside LlmCallGuard" do
    offenders = Dir.glob(Rails.root.join("app/**/*.rb")).select do |path|
      next false if path.end_with?("app/services/llm_call_guard.rb")
      File.read(path).match?(/RubyLLM\.chat|RubyLLM::Chat\.new/)
    end

    assert_empty offenders,
      "LLM requests must be issued through LlmCallGuard so they are counted (ADR-0019). " \
      "Offending files: #{offenders.join(', ')}"
  end
end
