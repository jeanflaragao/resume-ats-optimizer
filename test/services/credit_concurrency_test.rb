require "test_helper"

# Credit.consume! is the actual money-moving step (issue #122) -- the same
# rigor test/models/usage/counter_concurrency_test.rb already applies to
# Usage::Counter.consume!, here proving the balance itself never loses a
# concurrent decrement.
#
# NON-VACUITY (CLAUDE.md's "prove new safety assertions are non-vacuous"):
# this test was first run against a read-modify-write consume! --
#
#   user.update!(credits: user.credits - 1)
#
# -- and failed by losing updates (final balance higher than expected). The
# failing output is recorded in the PR body. The atomic single UPDATE
# statement is what makes it pass.
class CreditConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  # Same bound as Usage::CounterConcurrencyTest, for the same reason: wider
  # than config/database.yml's pool (RAILS_MAX_THREADS, default 5) just moves
  # the race to connection checkout instead of resolving it at the database.
  CONCURRENT_WRITERS = 4
  DECREMENTS_PER_WRITER = 25
  TOTAL_DECREMENTS = CONCURRENT_WRITERS * DECREMENTS_PER_WRITER

  setup { @user = User.create!(email: "credit-concurrency-#{SecureRandom.hex(8)}@example.com", credits: TOTAL_DECREMENTS) }
  teardown { @user.destroy }

  test "concurrent consume! calls for one user leave the balance at exactly the starting balance minus every call" do
    user_id = @user.id

    # Each call reloads its own User instance, the same way two separate web
    # requests each load their own copy of Current.user -- reusing one shared
    # Ruby object across threads would let every write update that object's
    # in-memory attribute immediately (before the SQL round-trip even starts),
    # which accidentally self-heals the exact staleness this test exists to
    # catch and made the read-modify-write version above pass anyway.
    run_concurrently(CONCURRENT_WRITERS) do
      DECREMENTS_PER_WRITER.times { Credit.consume!(User.find(user_id)) }
    end

    assert_equal 0, @user.reload.credits,
      "lost an update: #{TOTAL_DECREMENTS} concurrent decrements from #{TOTAL_DECREMENTS} did not reach exactly zero"
  end

  # Issue #123: grant_unlimited_days!'s GREATEST/COALESCE expression is the
  # same "single atomic SQL statement, not a Ruby read-then-write" discipline
  # as consume! above, guarding against a different race -- two genuinely
  # concurrent grants (e.g. two purchases landing at once) each reading the
  # same prior unlimited_until and computing a stale "extend from" point.
  # GRANTS_PER_WRITER x CONCURRENT_WRITERS grants of 1 day each must add up to
  # exactly that many days from the starting point, regardless of ordering.
  test "concurrent grant_unlimited_days! calls for one user stack every grant with none lost" do
    user_id = @user.id
    grants_per_writer = 10
    total_grants = CONCURRENT_WRITERS * grants_per_writer
    # Far enough in the future that every grant unambiguously stacks on top of
    # it (GREATEST(current expiry, now) always picks the expiry here) --
    # starting from an already-expired window would make the first grant
    # extend from "now" instead (by design, see credit_test.rb), which would
    # make this test's arithmetic ambiguous without testing anything about
    # lost updates.
    started_from = 100.days.from_now
    @user.update!(unlimited_until: started_from)

    run_concurrently(CONCURRENT_WRITERS) do
      grants_per_writer.times { Credit.grant_unlimited_days!(User.find(user_id), 1) }
    end

    assert_in_delta started_from + total_grants.days, @user.reload.unlimited_until, 5.seconds,
      "lost an update: #{total_grants} concurrent one-day grants did not add up"
  end

  private

  def run_concurrently(count)
    barrier = Concurrent::CyclicBarrier.new(count)

    count.times.map {
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait
          yield
        end
      end
    }.each(&:value)
  end
end
