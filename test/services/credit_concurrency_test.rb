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
