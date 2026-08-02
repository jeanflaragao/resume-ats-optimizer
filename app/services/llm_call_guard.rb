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
# Both defaults are local-only. In production neither has one, and the app
# refuses to boot until both are set explicitly — see .validate_configuration!
# and ADR-0020.
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

  # Raised at boot, not at first call. See .validate_configuration! below.
  class ConfigurationError < StandardError; end

  # Boot-time check that production is configured deliberately rather than
  # inheriting the local-testing defaults above (issue #77). Called from
  # config/initializers/llm_call_guard.rb; extracted here so the rules are
  # unit-testable without booting a second Rails environment.
  #
  # Every rule exists because the failure it prevents is silent: the app boots
  # clean and the damage shows up in a user's downloaded PDF, or in everyone
  # else's "we've hit today's processing limit". Three shapes of that:
  #
  # 1. ENABLE_REAL_LLM_CALLS unset -> every resume ships StubChat's placeholder
  #    text in place of the summary, job title, and every bullet.
  # 2. MAX_LLM_CALLS_PER_DAY unset -> the whole service shares the local
  #    default. Since ADR-0019 that means 10 real provider requests, and one
  #    upload + analyze + preview + download is 2 + 2x(experiences with
  #    bullets) — a single ordinary resume exhausts the day for everyone.
  # 3. ANTHROPIC_API_KEY unset -> config/initializers/ruby_llm.rb reads it with
  #    a bare ENV[], so nothing fails until the first user's upload, which
  #    surfaces as "the AI service is temporarily unavailable".
  #
  # Deliberately production-only, and deliberately *not* wrapped in a rescue:
  # refusing to boot is the whole mechanism. Development and test keep the
  # defaults unchanged — stub mode is the correct local state.
  #
  # env is injectable so the production rules can be tested directly.
  def self.validate_configuration!(env: Rails.env)
    # The single build-time exemption. Dockerfile:23 sets RAILS_ENV=production
    # and Dockerfile:50 boots Rails to run assets:precompile, which loads this
    # initializer (propshaft's `task precompile: :environment`, plus
    # tailwindcss-rails enhancing it with `task build: [:environment, ...]`).
    # No deploy-time environment exists at image-build time, and there is
    # nothing to validate: the build issues no LLM requests. SECRET_KEY_BASE_DUMMY
    # is Rails' own marker for exactly this boot (rails/application.rb:476-480),
    # already set on that line — one variable wide, not an env-shaped guess.
    return if ENV.key?("SECRET_KEY_BASE_DUMMY")
    return unless env.production?

    validate_mode!
    validate_api_key!
    validate_cap!
  end

  # "Are we stubbing?" — the mode itself, independent of who wants to know.
  def self.stub_mode?
    !enabled?
  end

  # "Should the UI say so?" — the mode plus the places it needs announcing.
  # Silent in development and test (Rails.env.local?), where stub mode is the
  # documented normal state and a banner would only add noise to every view
  # assertion; visible anywhere else, which is where a user could otherwise
  # receive placeholder text without knowing it (issue #77).
  def self.stub_mode_banner?(env: Rails.env)
    stub_mode? && !env.local?
  end

  # Stub mode is a deliberate deployment choice, never a default. An unset
  # ENABLE_REAL_LLM_CALLS and an explicit "false" are different mistakes, and
  # only the second one can be intentional — so it takes a second variable to
  # confirm it.
  def self.stub_allowed?
    ActiveModel::Type::Boolean.new.cast(ENV["ALLOW_STUB_LLM"])
  end

  def self.validate_mode!
    unless ENV.key?("ENABLE_REAL_LLM_CALLS")
      raise ConfigurationError,
        "ENABLE_REAL_LLM_CALLS is not set. It has no default in production: set it to true " \
        "to call the real API, or to false with ALLOW_STUB_LLM=true to serve stub responses."
    end

    return if enabled? || stub_allowed?

    raise ConfigurationError,
      "ENABLE_REAL_LLM_CALLS is false in production, which serves every user placeholder text " \
      "instead of a tailored resume. Set ALLOW_STUB_LLM=true to confirm that is intended."
  end

  # Only when real calls are on: stub mode never touches the network, so a key
  # would be dead configuration there. Blank counts as unset — an empty value
  # in a deploy config is the likelier mistake than an absent one.
  def self.validate_api_key!
    return unless enabled?
    return if ENV["ANTHROPIC_API_KEY"].present?

    raise ConfigurationError,
      "ANTHROPIC_API_KEY is not set, but ENABLE_REAL_LLM_CALLS is true. Every LLM call would " \
      "fail at request time instead of at boot."
  end

  # Required even when stub mode is allowed, where it is never read: it makes
  # turning ALLOW_STUB_LLM off a one-variable change that cannot half-fail, and
  # keeps the production rule statable in one sentence.
  #
  # Parsed here rather than left to .max_calls_per_day's Integer() so an
  # unusable value is a boot failure with an actionable message, not an
  # ArgumentError raised mid-request against the first user to upload a resume.
  def self.validate_cap!
    unless ENV.key?("MAX_LLM_CALLS_PER_DAY")
      raise ConfigurationError,
        "MAX_LLM_CALLS_PER_DAY is not set. It has no default in production — the value belongs " \
        "in the deploy config (issue #48), sized against 2 + 2x(experiences with bullets) " \
        "provider requests per full user flow."
    end

    raw = ENV["MAX_LLM_CALLS_PER_DAY"]
    cap = Integer(raw, exception: false)
    return if cap&.positive?

    raise ConfigurationError,
      "MAX_LLM_CALLS_PER_DAY must be a positive integer, got #{raw.inspect}."
  end

  private_class_method :validate_mode!, :validate_api_key!, :validate_cap!

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
