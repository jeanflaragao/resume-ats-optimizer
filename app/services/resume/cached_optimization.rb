# Shared entry point to Resume::Optimization for the two paths that optimize
# the same resume against the same job description -- the preview
# (PreviewsController) and the download (Resume::OptimizedPdfJob). Before issue
# #83 they each ran the pipeline independently, which cost one BulletRewriter
# request per experience twice over, and, less obviously, delivered a PDF that
# was not the resume the user had approved on screen: two independent LLM runs
# produce two different rewrites.
#
# Wraps Resume::Optimization rather than changing it; that class stays a pure,
# cache-unaware fan-out. Cached in Rails.cache (Solid Cache in production)
# rather than in a table on purpose -- see ADR-0021 and issue #76: a cache entry
# expires by construction, a row has to be remembered about.
class Resume::CachedOptimization
  # Issue #122, case 2 of the three deterministic failures that must not
  # consume a credit: a resume missing a name, or with zero experiences,
  # cannot produce anything a user would call "an optimized resume" --
  # BulletRewriter would fan out over nothing, and a would-be cache miss would
  # still cache and charge for that no-op. Each condition independently
  # disqualifies: a missing name means a blank PDF header even with real
  # experience history; zero experiences means nothing to compare or rewrite
  # even with a name present. A missing summary, missing skills, or any other
  # single dropped field is acceptable degradation, not this.
  #
  # A live predicate, not a persisted flag, deliberately: filling in a missing
  # name via the existing pending-items flow (PendingItemsController, issue
  # #118) un-blocks Preview/Download automatically on the next request, with
  # nothing to clear.
  class UnusableResumeError < StandardError
    def initialize
      super("resume is missing a name or has no experiences to optimize")
    end

    def user_message
      "This resume doesn't have enough information to optimize yet -- it's missing a name or has no work " \
      "experience listed. Fill in the missing details above, then try again."
    end
  end

  # One week (issue #122, docs/adr/0035-credit-balance-and-unlimited-window.md),
  # up from the original 15 minutes -- with accounts and a permanent resume
  # history, "read it later" is a real usage pattern a single sitting no longer
  # covers. Deliberately still the same value Resume::OptimizedPdfJob::CACHE_EXPIRY
  # gives a generated download link, for the reason ADR-0021 originally gave:
  # two different windows for one user journey would be two numbers to keep in
  # sync. Still comfortably below Resume::LAST_ACCESSED_PURGE_AFTER (1 month,
  # ADR-0034), so this can never be the longest-lived copy of anything.
  #
  # This is also, now, a real charging boundary: issue #122 charges a credit on
  # the cache-miss branch below, so once an entry expires, the next Preview or
  # Download of the same (resume, job description) pair is a genuine new miss
  # and is charged again. Deliberate, not a bug -- the underlying LLM cost is
  # genuinely re-incurred too. See the ADR for the full reasoning.
  CACHE_TTL = 1.week

  # Shape of the cached value: the members of Resume::Optimization::Result,
  # Experience and Education. Bump when they change, so a deploy cannot read
  # yesterday's shape back.
  #
  # 2 (issue #117): Experience gained bullet_fallbacks, so a cached v1 entry
  # is missing an attribute Result#bullet_fallbacks callers now expect.
  KEY_VERSION = 2

  CONTEXTS = %i[preview download].freeze

  # --- Lock timing -----------------------------------------------------------
  #
  # Measured, not guessed (issue #83). Against **claude-sonnet-4-5** (the model
  # in config/initializers/ruby_llm.rb) on a 795-word job posting, timing every
  # BulletRewriter request in a 3-experience and a 5-experience run:
  #
  #   N=3  total=13.85s  per-request=[4.93, 4.92, 3.77]
  #   N=5  total=22.25s  per-request=[3.99, 3.54, 3.41, 8.17, 3.08]
  #
  # 8 samples: mean 4.48s, median 3.88s, min 3.08s, max 8.17s. The fan-out is
  # sequential -- the per-request latencies sum to within 0.23s of each total --
  # so duration is affine in N, and the per-experience figure is the pooled mean
  # rather than the two-point slope (T5-T3)/2, which differences two noisy
  # totals and discards six of the eight samples.
  #
  # These numbers belong to that model. Changing config.default_model
  # invalidates them: re-measure before trusting the constants below.
  PIPELINE_FIXED_OVERHEAD = 0.25.seconds
  PIPELINE_PER_EXPERIENCE = 4.5.seconds

  # 2.0 because the worst single request observed was 1.82x the mean, so a
  # smaller factor would send a waiter into the fallthrough branch whenever one
  # call in a batch ran long -- and fallthrough is the expensive failure: it
  # costs a full pipeline *and* N billed requests. Uniform across contexts
  # because the two thread budgets are identical (Puma 3 threads,
  # config/puma.rb:27-28; Solid Queue 3 threads, config/queue.yml:6-9), so
  # there is no basis for waiting longer on one path than the other.
  LOCK_WAIT_SAFETY_FACTOR = 2.0

  # Strictly larger than LOCK_WAIT_SAFETY_FACTOR, so the lock always outlives
  # the longest possible wait by one whole expected pipeline (22.75s at N=5,
  # 40.75s at N=9). A waiter therefore always gives up *before* the lock can
  # expire, instead of both timing out together and the winner finishing an
  # instant later.
  LOCK_TTL_SAFETY_FACTOR = 3.0

  # --- Why neither wait is capped ---------------------------------------------
  #
  # No ceiling from Solid Queue, and the numbers say why. A download waits
  # inside a worker thread -- 81.5s at N=9 -- and a worker whose process is
  # pruned has its claimed executions *failed*, not released
  # (SolidQueue::Process#prune -> fail_all_claimed_executions_with), so being
  # reclaimed mid-wait would cost the wait and the download both.
  #
  # It cannot happen. Pruning needs last_heartbeat_at older than
  # SolidQueue.process_alive_threshold (5 minutes), swept by the supervisor
  # every 5 minutes, and the heartbeat is written every 60s by a separate
  # Concurrent::TimerTask (solid_queue/processes/registrable.rb:39) -- not by
  # the worker thread pool. A thread parked here keeps its process heartbeating,
  # so only a genuinely dead process is pruned, and its jobs are lost with or
  # without a wait.
  #
  # Even pretending the two were coupled: the wait only reaches the 5-minute
  # threshold at (0.25 + 4.5N) x 2 = 300, i.e. N ~= 33 experiences, against
  # 81.5s at N=9. What does interrupt a wait is a deploy --
  # SolidQueue.shutdown_timeout is 5s -- but that is well under the pipeline
  # itself (13.85s measured at N=3), so the winner is equally exposed and the
  # wait adds no failure mode; a graceful shutdown releases the execution to run
  # again rather than failing it. There is no job execution timeout anywhere in
  # the app or the gem.

  LOCK_POLL_INTERVAL = 0.25.seconds

  class << self
    def call(resume:, job_description_text:, context:, chat: LlmCallGuard.chat(subject: resume.user_id.to_s), lock_wait: nil)
      new(
        resume: resume, job_description_text: job_description_text,
        context: context, chat: chat, lock_wait: lock_wait
      ).call
    end

    # Issue #122, case 2. Called from PreviewsController#create and
    # DownloadsController#create before their credit gate and enforce_quota!
    # -- the same relative position Resume::Pdf.guard_renderable! already has
    # in Downloads (ADR-0025): free, deterministic, knowable from the resume's
    # own persisted attributes, so it must run before anything downstream can
    # be spent on a resume that can't produce anything usable anyway.
    def guard_usable!(resume:)
      return unless resume.name.blank? || resume.experiences.empty?

      raise UnusableResumeError
    end

    # A cheap existence check, no lock and no computation -- whether calling
    # .call right now would be a free hit or a chargeable miss. Issue #122:
    # lets a view label the Preview/Download button ("uses 1 credit" vs.
    # "free -- already generated") and lets the credit gate let a 0-credit
    # user through to something already paid for, before ever calling .call.
    def cached?(resume:, job_description_text:)
      Rails.cache.exist?(cache_key(resume: resume, job_description_text: job_description_text))
    end

    # Carries no job description text and no resume field values: ids,
    # timestamps and digests only (ADR-0015). A cached entry is reachable only
    # by someone who has already passed find_owned_resume! for this resume.id,
    # so keying on the resume rather than on the owner token cannot leak across
    # users.
    def cache_key(resume:, job_description_text:)
      [
        "resume_optimization",
        "v#{KEY_VERSION}",
        "p#{BulletRewriter.prompt_fingerprint}",
        resume_state_digest(resume),
        job_description_digest(job_description_text)
      ].join("/")
    end

    def lock_key(resume:, job_description_text:)
      "#{cache_key(resume: resume, job_description_text: job_description_text)}/lock"
    end

    def counter_key(context, outcome, date: Date.current)
      "resume_optimization/#{context}_#{outcome}_on/#{date}"
    end

    def expected_duration(experience_count)
      PIPELINE_FIXED_OVERHEAD + (experience_count * PIPELINE_PER_EXPERIENCE)
    end

    def lock_wait(experience_count)
      expected_duration(experience_count) * LOCK_WAIT_SAFETY_FACTOR
    end

    def lock_ttl(experience_count)
      expected_duration(experience_count) * LOCK_TTL_SAFETY_FACTOR
    end

    private

      # Identity *and* current state. The relation cache keys fold in each
      # collection's count and its newest updated_at, which is what catches an
      # edited bullet, an added experience and a deleted one. resume.cache_key_
      # with_version alone would not: neither Experience nor Education declares
      # belongs_to :resume, touch: true, so changing a child never moves the
      # parent's timestamp.
      def resume_state_digest(resume)
        Digest::SHA256.hexdigest(
          [
            resume.cache_key_with_version,
            resume.experiences.cache_key_with_version,
            resume.educations.cache_key_with_version
          ].join("/")
        )
      end

      # Normalisation is deliberately minimal: line endings, because the same
      # text reaches us from a textarea and from the preview page's hidden
      # field, and outer whitespace. No downcasing and no collapsing of internal
      # whitespace -- those would let a rewrite produced from one text be served
      # for a different one, which is exactly what this key exists to prevent.
      def job_description_digest(text)
        Digest::SHA256.hexdigest(text.to_s.gsub(/\r\n?/, "\n").strip)
      end
  end

  def initialize(resume:, job_description_text:, context:, chat:, lock_wait: nil)
    raise ArgumentError, "unknown context #{context.inspect}" unless CONTEXTS.include?(context)

    @resume = resume
    @job_description_text = job_description_text
    @context = context
    @chat = chat
    @lock_wait = lock_wait
  end

  def call
    cached = Rails.cache.read(cache_key)
    return record(:hit, cached) if cached

    if acquire_lock
      begin
        record(:miss, optimize_and_store)
      ensure
        Rails.cache.delete(lock_key)
      end
    else
      waited = await_winner
      waited ? record(:hit, waited) : record(:miss, optimize_and_store)
    end
  end

  private

  attr_reader :resume, :job_description_text, :context, :chat

  # The one place a credit is ever spent (issue #122). Reached from both
  # branches of #call that genuinely run the pipeline -- the lock winner, and
  # a waiter that fell through after the winner never wrote a result -- so
  # every real pipeline run charges exactly once, wherever it happens to run,
  # with no per-call-site duplication. Free inside an active unlimited window
  # (Credit.consume! checks that itself, freshly, not from an earlier read).
  #
  # After the cache write, not before: this is bookkeeping for a computation
  # that already happened, not a gate on whether it's allowed to -- that
  # already ran, upstream, in PreviewsController/DownloadsController before
  # .call was ever invoked. See docs/adr/0035-credit-balance-and-unlimited-window.md
  # for why this is an unconditional charge-on-success rather than a
  # reserve-then-confirm scheme.
  def optimize_and_store
    result = Resume::Optimization.call(resume: resume, job_description_text: job_description_text, chat: chat)
    Rails.cache.write(cache_key, result, expires_in: CACHE_TTL)
    Credit.consume!(resume.user)
    result
  end

  # Rails.cache.fetch is not atomic across processes, so a double-submitted
  # preview would otherwise run the pipeline twice concurrently -- the exact
  # case this class exists to eliminate. write(unless_exist:) is a real
  # cross-process lock under Solid Cache: it goes through Entry.lock_and_write,
  # the same SELECT ... FOR UPDATE inside a transaction that ADR-0019 relies on
  # for the call counter (solid_cache/store/api.rb:52-64).
  def acquire_lock
    Rails.cache.write(lock_key, SecureRandom.uuid, unless_exist: true, expires_in: lock_ttl)
  end

  # Waits for whoever holds the lock, and gives up for either of two reasons:
  # the wait ran out, or the lock disappeared without a result appearing. The
  # second is what keeps a cache that cannot lock from parking every caller for
  # the full timeout -- under Solid Cache's failsafe a write returns nil, so
  # nobody acquires and nobody holds, and callers fall through within one poll
  # interval instead.
  #
  # Falling through costs a duplicate pipeline, never a failed download.
  def await_winner
    deadline = monotonic_now + lock_wait

    while monotonic_now < deadline
      sleep LOCK_POLL_INTERVAL

      cached = Rails.cache.read(cache_key)
      return cached if cached
      return nil if Rails.cache.read(lock_key).nil?
    end

    nil
  end

  # Counted the way ADR-0019 counts LLM calls: a dated Rails.cache counter plus
  # a log line, no new instrumentation stack. "miss" means the pipeline ran, so
  # a rising download_miss count is precisely the #83 regression signal -- a
  # download that paid for a second fan-out, and delivered content its user
  # never previewed.
  #
  # Unlike LlmCallGuard.record_call!, an unreadable counter is ignored rather
  # than fatal: this is bookkeeping, and a cache blip must not fail a download.
  # increment returns nil in that case rather than raising, so there is nothing
  # to rescue.
  def record(outcome, result)
    Rails.cache.increment(self.class.counter_key(context, outcome), 1, expires_in: 1.day)
    if outcome == :miss
      Rails.logger.info("Resume::CachedOptimization: #{context} miss for resume #{resume.id}, ran the pipeline")
    end
    result
  end

  def cache_key
    @cache_key ||= self.class.cache_key(resume: resume, job_description_text: job_description_text)
  end

  def lock_key
    @lock_key ||= self.class.lock_key(resume: resume, job_description_text: job_description_text)
  end

  def lock_wait
    @lock_wait ||= self.class.lock_wait(experience_count)
  end

  def lock_ttl
    self.class.lock_ttl(experience_count)
  end

  # The fan-out width, which is what both timings scale with.
  def experience_count
    @experience_count ||= Resume::Optimization.rewrite_request_count(resume)
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
