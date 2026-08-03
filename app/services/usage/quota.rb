# Per-subject, per-action daily quota (issue #22). The second of two
# independent spend guards, and the narrower one:
#
#   LlmCallGuard  -- one global counter, the whole service's emergency ceiling
#                    for a day. Protects the Anthropic bill.
#   Usage::Quota  -- one counter per subject per action per day. Protects every
#                    *other* user from a single subject eating that ceiling.
#
# They are deliberately not merged. Issue #45 records the case for folding them
# together later; ADR-0023 records why doing it here would be premature.
#
# ## The subject is a browser session, not a person
#
# There is no User model and no authentication in this app yet -- ownership is
# ApplicationController#current_owner_token, an opaque per-session token
# (ADR-0007). So "per-user" here means per browser session, and a visitor who
# opens an incognito window gets a fresh quota. That is a real, known limit:
#
#   - It does stop the case this issue was opened for: one person re-submitting
#     large job descriptions in one sitting, and taking down everyone else's day
#     with them by exhausting the global cap.
#   - It does NOT make public signup safe, which issue #45's "trigger condition"
#     comment assumed #22 would. Bypassing it costs one keystroke. The global
#     cap remains the only thing standing between a determined abuser and the
#     bill, which is exactly why #45 says not to remove it.
#
# When real auth lands, `subject` becomes a user id and nothing else here
# changes -- Usage::Counter#subject_token is an opaque string by design.
class Usage::Quota
  # Raised instead of performing the action. Carries the action and the limit so
  # the controller can say which quota was hit and how large it is, without the
  # handler needing its own copy of either.
  class ExceededError < StandardError
    attr_reader :action, :limit

    def initialize(action:, limit:)
      @action = action
      @limit = limit
      super("Daily quota for #{action} (#{limit}) exceeded")
    end
  end

  # Raised at boot, not at first request -- same contract as
  # LlmCallGuard::ConfigurationError. See .validate_configuration!.
  class ConfigurationError < StandardError; end

  # The four points at which a visitor can spend money or a worker thread.
  #
  # Issue #22's body names three (requirement extraction, bullet rewriting, PDF
  # generation) and omits the upload. The upload is a real Anthropic request --
  # Resume::Extractors::Llm, one of the two calls in issue #45's `2 + 2E` -- and
  # it is the first thing an anonymous visitor can trigger, so leaving it
  # uncounted would leave the entrance to the whole flow unguarded. Recorded as
  # a deliberate departure in ADR-0023.
  ACTION_TYPES = %i[
    resume_extraction
    requirement_extraction
    bullet_rewriting
    pdf_generation
  ].freeze

  # What each action is called in a sentence addressed to the person who just
  # hit its limit. Lives next to ACTION_TYPES rather than in the controller so
  # adding an action type cannot half-land: a missing label is a fetch failure
  # in a test, not an ungrammatical flash in production.
  ACTION_LABELS = {
    resume_extraction: "resume uploads",
    requirement_extraction: "job description analyses",
    bullet_rewriting: "resume previews",
    pdf_generation: "PDF downloads"
  }.freeze

  # Local (development and test) defaults only. Production has none: see
  # .validate_configuration!.
  #
  # Sized for a day of real local use rather than for cost, since local runs are
  # stubbed by default (LlmCallGuard's ENABLE_REAL_LLM_CALLS). They are loose
  # enough not to interrupt manual testing and tight enough that a runaway loop
  # in development still trips them.
  #
  # The three downstream actions are set well above the upload because a single
  # resume is legitimately analyzed, previewed and downloaded against many
  # different job postings -- that is the product -- while re-uploading five
  # resumes in a day is already unusual.
  LOCAL_DEFAULTS = {
    resume_extraction: 5,
    requirement_extraction: 25,
    bullet_rewriting: 15,
    pdf_generation: 15
  }.freeze

  class << self
    # Records one use of `action` by `subject` and raises if that puts the
    # subject over the limit.
    #
    # Increment first, compare second -- the same direction LlmCallGuard.
    # record_call! takes, and for the same reason. Checking first and
    # incrementing after leaves a window in which two concurrent requests both
    # read a count under the limit and both proceed, which is precisely the
    # double-submit this guards. The cost is that a refused attempt still
    # occupies a slot; that is moot, because the subject is already over the
    # limit for the rest of the period either way.
    #
    # Nothing is refunded when the work that follows fails. A failed upload
    # still cost an Anthropic request in most cases, and a refund path would
    # need every caller to know which failures were free.
    def consume!(subject:, action:)
      raise ArgumentError, "unknown action #{action.inspect}" unless ACTION_TYPES.include?(action)
      raise ArgumentError, "subject is required" if subject.blank?

      limit = limit_for(action)
      count = Usage::Counter.consume!(subject_token: subject, action_type: action)
      return count if count <= limit

      raise ExceededError.new(action: action, limit: limit)
    end

    def limit_for(action)
      Integer(ENV.fetch(env_var_for(action)) { LOCAL_DEFAULTS.fetch(action) })
    end

    def env_var_for(action)
      "RATE_LIMIT_#{action.to_s.upcase}_PER_DAY"
    end

    def label_for(action)
      ACTION_LABELS.fetch(action)
    end

    # Boot-time check that production quotas were set deliberately rather than
    # inherited from LOCAL_DEFAULTS above. Same rule, same shape and same
    # reasoning as LlmCallGuard.validate_configuration! (issue #77, ADR-0020):
    # the failure it prevents is silent in both directions. Numbers sized for a
    # laptop would throttle real users off a working product, and there is no
    # signal that it happened other than people leaving.
    #
    # Called from config/initializers/usage_quota.rb; the rules live here so
    # they are unit-testable without booting a second Rails environment, and
    # `env` is injectable for the same reason.
    def validate_configuration!(env: Rails.env)
      # The one build-time exemption, identical to LlmCallGuard's and for the
      # identical reason: Dockerfile:50 boots Rails under RAILS_ENV=production
      # to run assets:precompile, with no deploy environment and no requests to
      # quota. SECRET_KEY_BASE_DUMMY is Rails' own marker for that boot.
      return if ENV.key?("SECRET_KEY_BASE_DUMMY")
      return unless env.production?

      ACTION_TYPES.each { |action| validate_limit!(action) }
    end

    private

      def validate_limit!(action)
        var = env_var_for(action)

        unless ENV.key?(var)
          raise ConfigurationError,
            "#{var} is not set. Per-action quotas have no default in production — the value belongs " \
            "in the deploy config (issue #48). Size it from counts observed after issue #82; earlier " \
            "figures under-report (issue #45)."
        end

        raw = ENV[var]
        limit = Integer(raw, exception: false)
        return if limit&.positive?

        raise ConfigurationError, "#{var} must be a positive integer, got #{raw.inspect}."
      end
  end
end
