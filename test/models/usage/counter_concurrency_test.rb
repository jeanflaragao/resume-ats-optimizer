require "test_helper"

# The one property that makes Usage::Counter a rate limiter rather than an
# approximate tally: concurrent increments for the same subject must not lose
# updates. A double-submitted form, or a Puma thread and a Solid Queue worker
# running for one session at once, is not an exotic case -- it is the case the
# limit exists to catch, and the one a read-then-write counter gets wrong.
#
# NON-VACUITY (CLAUDE.md's "prove new safety assertions are non-vacuous"): this
# test was first run against a read-then-write implementation of consume! --
#
#   row = find_or_create_by!(subject_token:, action_type:, period:, period_start:)
#   row.update!(count: row.count + 1)
#   row.count
#
# -- and failed, both by losing updates and by raising RecordNotUnique from the
# find_or_create_by race. The failing output is recorded in the PR body. The
# atomic single-statement UPSERT is what makes it pass.
#
# use_transactional_tests is off because the point is genuine concurrency:
# inside the suite's usual wrapping transaction the worker threads would each
# get their own connection, be unable to see the uncommitted row, and block on
# the unique index against a transaction that never commits.
class Usage::CounterConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  # Four, not more: config/database.yml's pool is
  # ENV.fetch("RAILS_MAX_THREADS") { 5 }, so a wider fan-out would queue on
  # connection checkout and stop being concurrent at the database, which is
  # where the race has to be resolved. Four overlapping writers is already more
  # than enough to lose an update without the UPSERT -- the read-then-write run
  # this is proven against lost them at four.
  CONCURRENT_WRITERS = 4

  # Each writer increments this many times rather than once. A single round of
  # four writes does not reliably interleave -- the read-then-write version this
  # is proven against passes that -- because the window between the read and the
  # write is a fraction of the thread-scheduling quantum, so the four requests
  # usually serialise by luck. Repeating widens the number of chances, not the
  # window: 100 increments hits the race every run, while the implementation
  # under test is not slowed down or otherwise bent to make it fail.
  INCREMENTS_PER_WRITER = 25

  TOTAL_INCREMENTS = CONCURRENT_WRITERS * INCREMENTS_PER_WRITER

  setup { Usage::Counter.where(subject_token: subject).delete_all }
  teardown { Usage::Counter.where(subject_token: subject).delete_all }

  test "concurrent consume! calls for one subject leave the count at exactly the number of calls" do
    results = run_concurrently(CONCURRENT_WRITERS) do
      INCREMENTS_PER_WRITER.times.map do
        Usage::Counter.consume!(subject_token: subject, action_type: :pdf_generation)
      end
    end.flatten

    assert_equal TOTAL_INCREMENTS, Usage::Counter.sole.count,
      "lost an update: #{TOTAL_INCREMENTS} concurrent increments did not add up"

    # Every caller must also learn a *distinct* position. Two callers handed the
    # same number each believe they were the same nth use, which is how a limit
    # of N lets N + 1 through even when the stored total happens to be right.
    assert_equal (1..TOTAL_INCREMENTS).to_a, results.sort
  end

  test "concurrent consume! calls for different subjects do not collide" do
    tokens = CONCURRENT_WRITERS.times.map { |i| "#{subject}-#{i}" }

    begin
      run_concurrently(CONCURRENT_WRITERS) do |i|
        Usage::Counter.consume!(subject_token: tokens[i], action_type: :pdf_generation)
      end

      assert_equal CONCURRENT_WRITERS, Usage::Counter.where(subject_token: tokens).count
      assert_equal [ 1 ] * CONCURRENT_WRITERS, Usage::Counter.where(subject_token: tokens).pluck(:count)
    ensure
      Usage::Counter.where(subject_token: tokens).delete_all
    end
  end

  private

  # Distinct per test run so a leftover row from a crashed run cannot make the
  # next one pass or fail for the wrong reason -- there is no transaction to
  # roll this class's writes back.
  def subject
    @subject ||= "concurrency-#{SecureRandom.hex(8)}"
  end

  # Starts all threads before letting any of them write, so the writes actually
  # overlap instead of happening to serialise while the later threads are still
  # being spawned. Each thread takes its own pooled connection; exceptions are
  # re-raised on join so a failure inside a thread fails the test.
  def run_concurrently(count)
    barrier = Concurrent::CyclicBarrier.new(count)

    count.times.map { |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait
          yield i
        end
      end
    }.map(&:value)
  end
end
