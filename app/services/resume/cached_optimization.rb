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
  # Only has to span one sitting: preview, read it, click download. Deliberately
  # the same 15 minutes Resume::OptimizedPdfJob::CACHE_EXPIRY gives a generated
  # download link, because that is the same sitting -- two different windows for
  # one user journey would be two numbers to keep in sync. Far below issue #59's
  # proposed 30-day window for the source records, so this can never be the
  # longest-lived copy of anything.
  CACHE_TTL = 15.minutes

  # Shape of the cached value: the members of Resume::Optimization::Result,
  # Experience and Education. Bump when they change, so a deploy cannot read
  # yesterday's shape back.
  KEY_VERSION = 1

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
    def call(resume:, job_description_text:, context:, chat: LlmCallGuard.chat, lock_wait: nil)
      new(
        resume: resume, job_description_text: job_description_text,
        context: context, chat: chat, lock_wait: lock_wait
      ).call
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

  def optimize_and_store
    result = Resume::Optimization.call(resume: resume, job_description_text: job_description_text, chat: chat)
    Rails.cache.write(cache_key, result, expires_in: CACHE_TTL)
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
