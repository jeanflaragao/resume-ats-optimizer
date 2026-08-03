require "test_helper"

# Storage-level behaviour of issue #22's quota counters. The property that
# actually matters -- that concurrent increments do not lose updates -- needs a
# non-transactional test with real threads and lives in
# test/models/usage/counter_concurrency_test.rb.
class Usage::CounterTest < ActiveSupport::TestCase
  test "the first consume! inserts a row at one and returns it" do
    count = Usage::Counter.consume!(subject_token: "token-a", action_type: :pdf_generation)

    assert_equal 1, count
    row = Usage::Counter.sole
    assert_equal "token-a", row.subject_token
    assert_equal "pdf_generation", row.action_type
    assert_equal Usage::Counter::DAY, row.period
    assert_equal Date.current, row.period_start
    assert_equal 1, row.count
  end

  test "repeated consume! increments the same row and returns the running count" do
    counts = 3.times.map { Usage::Counter.consume!(subject_token: "token-a", action_type: :pdf_generation) }

    assert_equal [ 1, 2, 3 ], counts
    assert_equal 1, Usage::Counter.count, "expected one row, not one per call"
    assert_equal 3, Usage::Counter.sole.count
  end

  # Each of the four dimensions of the unique index gets its own row. Without
  # this, one subject's usage would suppress another's, or yesterday's count
  # would still be enforced today.
  test "counters are separate per subject, per action and per period_start" do
    Usage::Counter.consume!(subject_token: "token-a", action_type: :pdf_generation)
    Usage::Counter.consume!(subject_token: "token-b", action_type: :pdf_generation)
    Usage::Counter.consume!(subject_token: "token-a", action_type: :bullet_rewriting)
    Usage::Counter.consume!(subject_token: "token-a", action_type: :pdf_generation, period_start: Date.current - 1)

    assert_equal 4, Usage::Counter.count
    assert_equal [ 1, 1, 1, 1 ], Usage::Counter.pluck(:count)
  end

  test "consume! accepts a symbol action type and stores it as a string" do
    Usage::Counter.consume!(subject_token: "token-a", action_type: :resume_extraction)
    Usage::Counter.consume!(subject_token: "token-a", action_type: "resume_extraction")

    assert_equal 1, Usage::Counter.count
    assert_equal 2, Usage::Counter.sole.count
  end

  test "consume! sets both timestamps on insert and moves only updated_at on increment" do
    Usage::Counter.consume!(subject_token: "token-a", action_type: :pdf_generation)
    row = Usage::Counter.sole
    created_at, updated_at = row.created_at, row.updated_at

    travel 1.minute do
      Usage::Counter.consume!(subject_token: "token-a", action_type: :pdf_generation)
    end

    row.reload
    assert_equal created_at, row.created_at
    assert_operator row.updated_at, :>, updated_at
  end

  test "purge_stale! deletes counters older than RETAIN_FOR and keeps the rest" do
    stale = Date.current - Usage::Counter::RETAIN_FOR - 1.day
    boundary = Date.current - Usage::Counter::RETAIN_FOR
    Usage::Counter.consume!(subject_token: "token-a", action_type: :pdf_generation, period_start: stale)
    Usage::Counter.consume!(subject_token: "token-a", action_type: :pdf_generation, period_start: boundary)
    Usage::Counter.consume!(subject_token: "token-a", action_type: :pdf_generation)

    Usage::Counter.purge_stale!

    assert_equal [ boundary, Date.current ], Usage::Counter.order(:period_start).pluck(:period_start)
  end

  # RETAIN_FOR has to outlive the longest period the app enforces over, or the
  # purge deletes counters that are still being counted against. Today that is
  # one day; ADR-0023 records that adding a monthly period means raising this.
  test "RETAIN_FOR exceeds the period the counters enforce over" do
    assert_operator Usage::Counter::RETAIN_FOR, :>, 1.day
  end
end
