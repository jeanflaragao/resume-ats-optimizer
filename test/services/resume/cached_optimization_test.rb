require "test_helper"

class Resume::CachedOptimizationTest < ActiveSupport::TestCase
  # Counts the rewrites it is asked for, so "the pipeline did not run" is an
  # assertion about this object rather than an inference from timing.
  FakeChat = Struct.new(:prompts) do
    def with_schema(schema)
      @schema = schema
      self
    end

    def ask(prompt)
      prompts << prompt
      Struct.new(:content).new({ "bullets" => prompt.to_s.scan(/^\d+\.\s+(.+)$/).flatten })
    end
  end

  JOB_DESCRIPTION = "We need a Ruby engineer who has led platform migrations.".freeze

  setup do
    # Test env's cache_store is :null_store (see config/environments/test.rb),
    # which no-ops read/write. This swap is LOAD-BEARING: under :null_store
    # every entry this class writes would be discarded, every call would be a
    # miss, and the whole file would pass while asserting nothing. Same reason
    # test/services/llm_call_guard_test.rb documents its own swap.
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "a second call for the same resume and job description does not run the pipeline again" do
    resume = resumes(:one)
    first = optimize(resume, JOB_DESCRIPTION)

    chat = FakeChat.new([])
    second = Resume::CachedOptimization.call(
      resume: resume, job_description_text: JOB_DESCRIPTION, context: :download, chat: chat
    )

    assert_empty chat.prompts, "a cache hit must issue no rewrite requests"
    assert_equal first.experiences.flat_map(&:bullets), second.experiences.flat_map(&:bullets)
  end

  test "an edited job description is not served the earlier rewrite" do
    resume = resumes(:one)
    optimize(resume, JOB_DESCRIPTION)

    chat = FakeChat.new([])
    Resume::CachedOptimization.call(
      resume: resume, job_description_text: "#{JOB_DESCRIPTION} Kubernetes required.", context: :download, chat: chat
    )

    refute_empty chat.prompts, "different job description text must miss the cache"
  end

  # Nothing but line endings and outer whitespace: the same text arrives from a
  # textarea and from the preview page's hidden field, and those must agree.
  test "line-ending and surrounding-whitespace differences still hit" do
    resume = resumes(:one)
    optimize(resume, "Line one\nLine two")

    chat = FakeChat.new([])
    Resume::CachedOptimization.call(
      resume: resume, job_description_text: "  Line one\r\nLine two\n  ", context: :download, chat: chat
    )

    assert_empty chat.prompts, "the same text with different line endings must not re-run the pipeline"
  end

  test "a changed prompt version is not served the earlier rewrite" do
    resume = resumes(:one)
    optimize(resume, JOB_DESCRIPTION)

    chat = FakeChat.new([])
    with_prompt_fingerprint("2-abcdef123456") do
      Resume::CachedOptimization.call(
        resume: resume, job_description_text: JOB_DESCRIPTION, context: :download, chat: chat
      )
    end

    refute_empty chat.prompts, "a rewrite produced by a different prompt must not be reused"
  end

  # resume.cache_key_with_version alone would not move here: Experience does not
  # declare belongs_to :resume, touch: true, so editing a bullet leaves the
  # parent's updated_at untouched.
  test "an edited bullet is not served the earlier rewrite" do
    resume = resumes(:one)
    optimize(resume, JOB_DESCRIPTION)

    experience = resume.experiences.first
    experience.update!(bullets: experience.bullets + [ "Ran the incident review process" ])

    chat = FakeChat.new([])
    Resume::CachedOptimization.call(
      resume: resume.reload, job_description_text: JOB_DESCRIPTION, context: :download, chat: chat
    )

    refute_empty chat.prompts, "a changed resume must not be served rewrites of its earlier state"
  end

  # Deletes the fixture's bullet-less experience (:earlier) on purpose. Deleting
  # the one with bullets would leave a resume that costs no rewrite requests at
  # all, so "no prompts were issued" would be true whether the key moved or not
  # -- the assertion would pass for the wrong reason.
  test "a deleted experience is not served the earlier rewrite" do
    resume = resumes(:one)
    optimize(resume, JOB_DESCRIPTION)

    experiences(:earlier).destroy!

    chat = FakeChat.new([])
    Resume::CachedOptimization.call(
      resume: resume.reload, job_description_text: JOB_DESCRIPTION, context: :download, chat: chat
    )

    refute_empty chat.prompts, "a deleted experience must move the key"
  end

  test "the cache key carries no job description text and no resume field values" do
    resume = resumes(:one)
    key = Resume::CachedOptimization.cache_key(resume: resume, job_description_text: JOB_DESCRIPTION)

    refute_includes key, "Ruby engineer"
    refute_includes key, resume.name.to_s
    assert_includes key, "p#{BulletRewriter.prompt_fingerprint}"
  end

  # --- The double-submit lock ------------------------------------------------

  test "a caller that loses the lock returns the winner's result without running the pipeline" do
    resume = resumes(:one)
    winner_result = optimize(resume, JOB_DESCRIPTION)
    hold_lock(resume, JOB_DESCRIPTION)

    chat = FakeChat.new([])
    result = Resume::CachedOptimization.call(
      resume: resume, job_description_text: JOB_DESCRIPTION, context: :preview, chat: chat
    )

    assert_empty chat.prompts, "the loser must wait for the winner rather than run a second pipeline"
    assert_equal winner_result.experiences.flat_map(&:bullets), result.experiences.flat_map(&:bullets)
  end

  # The lock is held and never released, and no result appears -- a winner whose
  # process died. The loser must give up and produce a resume itself: a
  # duplicate pipeline is the cost, but a failed download is not acceptable.
  test "a caller whose winner never delivers falls through and runs the pipeline itself" do
    resume = resumes(:one)
    hold_lock(resume, JOB_DESCRIPTION)

    chat = FakeChat.new([])
    result = Resume::CachedOptimization.call(
      resume: resume, job_description_text: JOB_DESCRIPTION, context: :preview, chat: chat,
      lock_wait: 0.5.seconds
    )

    refute_empty chat.prompts, "the wait must end rather than hang forever"
    assert_equal resume.experiences.size, result.experiences.size
  end

  # A store that cannot lock (Solid Cache's failsafe returns nil on a write it
  # could not perform) must not park every caller for the full wait.
  test "a caller stops waiting as soon as the lock disappears without a result" do
    resume = resumes(:one)
    hold_lock(resume, JOB_DESCRIPTION, expires_in: 0.3.seconds)

    chat = FakeChat.new([])
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Resume::CachedOptimization.call(
      resume: resume, job_description_text: JOB_DESCRIPTION, context: :download, chat: chat,
      lock_wait: 30.seconds
    )
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    refute_empty chat.prompts
    assert_operator elapsed, :<, 5, "an abandoned lock must not hold a caller for the whole wait"
  end

  test "the lock always outlives the longest wait it can produce" do
    [ 0, 1, 3, 5, 9, 25 ].each do |count|
      assert_operator Resume::CachedOptimization.lock_ttl(count), :>, Resume::CachedOptimization.lock_wait(count),
        "a lock expiring while a caller is still waiting reintroduces the race the lock exists to remove (N=#{count})"
    end
  end

  test "both timings scale with the number of experiences that cost a request" do
    assert_operator Resume::CachedOptimization.lock_wait(9), :>, Resume::CachedOptimization.lock_wait(5)
    assert_operator Resume::CachedOptimization.lock_ttl(9), :>, Resume::CachedOptimization.lock_ttl(5)
  end

  test "an unknown context is refused rather than counted under a name nobody reads" do
    assert_raises(ArgumentError) do
      Resume::CachedOptimization.call(
        resume: resumes(:one), job_description_text: JOB_DESCRIPTION, context: :export, chat: FakeChat.new([])
      )
    end
  end

  # --- Issue #122: guard_usable! ----------------------------------------------

  test "guard_usable! passes silently for a resume with a name and at least one experience" do
    assert_nil Resume::CachedOptimization.guard_usable!(resume: resumes(:one))
  end

  test "guard_usable! raises for a resume with a blank name" do
    resume = resumes(:one)
    resume.update_column(:name, nil)

    assert_raises(Resume::CachedOptimization::UnusableResumeError) do
      Resume::CachedOptimization.guard_usable!(resume: resume)
    end
  end

  test "guard_usable! raises for a resume with zero experiences even when it has a name" do
    resume = resumes(:one)
    resume.experiences.destroy_all

    assert_raises(Resume::CachedOptimization::UnusableResumeError) do
      Resume::CachedOptimization.guard_usable!(resume: resume.reload)
    end
  end

  test "guard_usable! does not raise for a missing summary alone -- acceptable degradation, not critical" do
    resume = resumes(:one)
    resume.update_column(:summary, nil)

    assert_nil Resume::CachedOptimization.guard_usable!(resume: resume)
  end

  # --- Issue #122: .cached? ----------------------------------------------------

  test ".cached? is false before any call and true after one, without itself running the pipeline" do
    resume = resumes(:one)

    assert_not Resume::CachedOptimization.cached?(resume: resume, job_description_text: JOB_DESCRIPTION)

    optimize(resume, JOB_DESCRIPTION)

    assert Resume::CachedOptimization.cached?(resume: resume, job_description_text: JOB_DESCRIPTION)
  end

  test ".cached? is false for a different job description than the one that was cached" do
    resume = resumes(:one)
    optimize(resume, JOB_DESCRIPTION)

    assert_not Resume::CachedOptimization.cached?(resume: resume, job_description_text: "#{JOB_DESCRIPTION} Kubernetes required.")
  end

  # --- Issue #122: credit consumption -----------------------------------------

  test "a cache miss that runs the pipeline consumes exactly one credit" do
    resume = resumes(:one)
    resume.user.update!(credits: 2, unlimited_until: nil)

    optimize(resume, JOB_DESCRIPTION)

    assert_equal 1, resume.user.reload.credits
  end

  test "a cache hit consumes no credit" do
    resume = resumes(:one)
    optimize(resume, JOB_DESCRIPTION)

    # .reload, not a bare update! on the association already in memory: the
    # first optimize call above charged via Credit.consume!'s update_all,
    # which -- deliberately, see Credit -- writes straight to the row and
    # never touches this Ruby object's in-memory attributes. Without reload
    # first, update!(credits: 2) sees no change from its own (stale, still-2)
    # in-memory value and silently skips writing the column, leaving the row
    # at its real value (1) while this object still believes it wrote 2.
    resume.user.reload.update!(credits: 2, unlimited_until: nil)

    optimize(resume, JOB_DESCRIPTION)

    assert_equal 2, resume.user.reload.credits, "a cache hit must not be charged"
  end

  test "a loser that falls through and runs the pipeline itself still consumes exactly one credit" do
    resume = resumes(:one)
    resume.user.update!(credits: 2, unlimited_until: nil)
    hold_lock(resume, JOB_DESCRIPTION)

    Resume::CachedOptimization.call(
      resume: resume, job_description_text: JOB_DESCRIPTION, context: :preview, chat: FakeChat.new([]),
      lock_wait: 0.5.seconds
    )

    assert_equal 1, resume.user.reload.credits
  end

  test "a cache miss inside an active unlimited window consumes no credit" do
    resume = resumes(:one)
    resume.user.update!(credits: 2, unlimited_until: 1.day.from_now)

    optimize(resume, JOB_DESCRIPTION)

    assert_equal 2, resume.user.reload.credits
  end

  private

  def optimize(resume, job_description_text, context: :preview)
    Resume::CachedOptimization.call(
      resume: resume, job_description_text: job_description_text, context: context, chat: FakeChat.new([])
    )
  end

  def hold_lock(resume, job_description_text, expires_in: 1.minute)
    Rails.cache.write(
      Resume::CachedOptimization.lock_key(resume: resume, job_description_text: job_description_text),
      "another-process", expires_in: expires_in
    )
  end

  def with_prompt_fingerprint(fingerprint)
    original = BulletRewriter.method(:prompt_fingerprint)
    BulletRewriter.define_singleton_method(:prompt_fingerprint) { fingerprint }
    yield
  ensure
    BulletRewriter.define_singleton_method(:prompt_fingerprint, original)
  end
end
