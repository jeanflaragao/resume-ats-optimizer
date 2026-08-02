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
#
# The cap is enforced in two layers (issue #75):
#
# 1. A pre-flight check (.ensure_headroom!) at the point a flow knows how many
#    requests it will make, so a flow that cannot fit is refused before any
#    money is spent. It deliberately does not reserve — see below.
# 2. A per-request backstop inside MeteredChat#ask. Because pre-flight does not
#    reserve, two concurrent flows can both pass it and then both consume; this
#    is what makes the cap hold anyway, and it covers any flow whose predicted
#    count is wrong.
class LlmCallGuard
  class DailyLimitExceededError < StandardError; end

  # Deliberately NOT a subclass of DailyLimitExceededError. "Today's budget is
  # spent" and "we cannot tell what today's budget is" call for different
  # advice: come back tomorrow vs. try again shortly. Conflating them would
  # send users away for a day over a transient database blip.
  class BudgetUnavailableError < StandardError; end

  # Returns a stateless handle, not a live RubyLLM::Chat. Resolving a chat is
  # free; issuing a request is what costs money and what counts. Before #75
  # this method both counted and returned a live chat, so a caller that
  # resolved once and asked N times (Resume::Optimization) was billed N times
  # and counted once, while the shared chat's message history grew with every
  # rewrite.
  def self.chat
    return StubChat.new unless enabled?

    MeteredChat.new
  end

  def self.enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("ENABLE_REAL_LLM_CALLS", "false"))
  end

  def self.max_calls_per_day
    Integer(ENV.fetch("MAX_LLM_CALLS_PER_DAY", "10"))
  end

  def self.counter_key
    "llm_call_guard/calls_on/#{Date.current}"
  end

  # Pre-flight: refuses a flow that cannot fit inside today's remaining budget,
  # before its first billable request. Read-only by design — reserving would
  # need a refund path on every failure mode, and sizing a per-flow reservation
  # is #22's job, not this stopgap's.
  def self.ensure_headroom!(requests)
    return unless enabled?
    return if requests.to_i.zero?

    used = Rails.cache.read(counter_key).to_i
    return if used + requests <= max_calls_per_day

    raise DailyLimitExceededError,
      "Daily LLM call cap (#{max_calls_per_day}) would be exceeded: #{used} used, #{requests} more needed"
  end

  # Counts a request as it is issued, not once it succeeds. This overcounts
  # when a request fails in transit and returns no billable completion, and
  # that is the intended direction: a cost guard that counted only successes
  # could not gate at all, because the spend has already happened by the time
  # the response arrives. Overcounting costs a user some headroom;
  # undercounting costs money.
  #
  # One ask is one billable completion, not one HTTP attempt: RubyLLM wraps the
  # call in Faraday retry (ruby_llm/connection.rb:106) for rate-limit, 5xx and
  # timeout conditions, and those attempts return no completion to bill.
  # Fails closed. A working store always answers increment with a number, so
  # nil means the count could not be established: a miss the store could not
  # initialise, or — in production — one of the transient ActiveRecord errors
  # Solid Cache's failsafe swallows before returning nil (AdapterTimeout,
  # ConnectionNotEstablished, Deadlocked, LockWaitTimeout, QueryCanceled,
  # StatementTimeout; solid_cache/store/failsafe.rb). nil.to_i is 0, so
  # comparing it against the cap used to disable the cap silently, precisely
  # when the database was already in trouble.
  #
  # Refusing costs availability: a cache outage now blocks resume generation
  # rather than uncapping spend. That is the same answer this method's
  # count-before-the-request ordering gives to the same question, and a guard
  # that answered it one way for failed requests and the other way for a failed
  # counter would not be a guard.
  def self.record_call!
    count = Rails.cache.increment(counter_key, 1, expires_in: 1.day)
    raise BudgetUnavailableError, "LLM call counter is unavailable; refusing to issue an uncounted call" if count.nil?
    return if count <= max_calls_per_day

    raise DailyLimitExceededError, "Daily LLM call cap (#{max_calls_per_day}) exceeded"
  end

  # Duck-types the same with_schema(schema).ask(prompt, with: nil).content
  # interface as StubChat below, counting each request and issuing it against a
  # freshly built RubyLLM::Chat.
  #
  # A fresh chat per ask is what keeps the payload flat. RubyLLM::Chat is
  # stateful — #ask appends the user message and the assistant reply to
  # @messages (ruby_llm/chat.rb:40, :167, :229) and re-sends the whole array —
  # so one chat reused across N rewrites sends a transcript that grows with N.
  # Nothing is lost by starting fresh: no call site sets system instructions,
  # and each prompt already re-embeds everything the model needs.
  #
  # with_schema returns a NEW handle rather than mutating self, so a handle
  # shared across experiences (Resume::Optimization) or across Solid Queue
  # threads cannot leak one call's schema into the next.
  class MeteredChat
    attr_reader :schema

    def initialize(schema: nil)
      @schema = schema
    end

    def with_schema(schema)
      self.class.new(schema: schema)
    end

    def ask(prompt = nil, **options)
      LlmCallGuard.record_call!

      chat = RubyLLM.chat
      chat = chat.with_schema(schema) if schema
      chat.ask(prompt, **options)
    end
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
