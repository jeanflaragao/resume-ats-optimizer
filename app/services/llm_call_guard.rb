# Shared chat: default for every LLM call site (Resume::Extractors::Llm,
# BulletRewriter, JobDescription::Extractor, and Resume::Optimization's
# passthrough) so real Claude API usage during local/manual testing requires
# an explicit opt-in rather than happening by accident. This is a blunt,
# process-wide stopgap ahead of issue #22's per-user rate limiting, not a
# replacement for it.
#
# - ENABLE_REAL_LLM_CALLS (default false): when unset/false, .chat returns a
#   StubChat that never touches the network. When true, real calls are
#   metered against a daily cap.
# - MAX_LLM_CALLS_PER_DAY (default 10): once real calls for the current day
#   reach this count, the next call raises rather than silently proceeding.
class LlmCallGuard
  class DailyLimitExceededError < StandardError; end

  def self.chat
    return StubChat.new unless enabled?

    record_call!
    RubyLLM.chat
  end

  def self.enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("ENABLE_REAL_LLM_CALLS", "false"))
  end

  def self.max_calls_per_day
    Integer(ENV.fetch("MAX_LLM_CALLS_PER_DAY", "10"))
  end

  def self.record_call!
    key = "llm_call_guard/calls_on/#{Date.current}"
    count = Rails.cache.increment(key, 1, expires_in: 1.day)
    return if count.to_i <= max_calls_per_day

    raise DailyLimitExceededError, "Daily LLM call cap (#{max_calls_per_day}) exceeded"
  end

  # Duck-types the with_schema(schema).ask(prompt, with: nil).content interface
  # every real chat.with_schema(...).ask(...) call site relies on, returning
  # clearly-labeled canned data instead of calling the real API. Dispatches by
  # schema class since each LLM call site expects a different response shape.
  class StubChat
    STUB_LABEL = "[LlmCallGuard stub response — ENABLE_REAL_LLM_CALLS is not set]".freeze

    def with_schema(schema)
      @schema = schema
      self
    end

    def ask(prompt = nil, **)
      Struct.new(:content).new(stub_content(prompt))
    end

    private

    def stub_content(prompt)
      case @schema.name
      when "Resume::ExtractionSchema"
        {
          "name" => "Stub Candidate",
          "email" => "stub@example.com",
          "phone" => nil,
          "summary" => STUB_LABEL,
          "skills" => [],
          "experiences" => [],
          "educations" => []
        }
      when "BulletRewriter::Schema"
        # BulletRewriter requires exactly one rewritten bullet per input bullet
        # (raises MismatchedBulletCountError otherwise), so the stub echoes the
        # original bullets it parses back out of the prompt rather than
        # returning an empty array.
        { "bullets" => prompt.to_s.scan(/^\d+\.\s+(.+)$/).flatten.map { |bullet| "#{STUB_LABEL} #{bullet}" } }
      when "JobDescription::ExtractionSchema"
        {
          "title" => STUB_LABEL,
          "required_skills" => [],
          "preferred_skills" => [],
          "keywords" => []
        }
      else
        raise NotImplementedError, "LlmCallGuard::StubChat has no stub response for #{@schema.inspect}"
      end
    end
  end
end
