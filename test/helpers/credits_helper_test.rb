require "test_helper"

class CreditsHelperTest < ActionView::TestCase
  # Test env's cache_store is :null_store (config/environments/test.rb), which
  # no-ops read/write -- swap in a real store, same fix several other test
  # files already use for this exact problem.
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
    Current.session = nil
  end

  test "credit_balance_label shows the remaining balance outside an unlimited window" do
    user = users(:jordan)
    user.update!(credits: 3, unlimited_until: nil)

    assert_equal "3 credits remaining", credit_balance_label(user)
  end

  test "credit_balance_label pluralizes a single credit correctly" do
    user = users(:jordan)
    user.update!(credits: 1, unlimited_until: nil)

    assert_equal "1 credit remaining", credit_balance_label(user)
  end

  test "credit_balance_label shows the unlimited window instead of the balance while it's active" do
    user = users(:jordan)
    user.update!(credits: 0, unlimited_until: Date.new(2026, 8, 20).end_of_day)

    assert_equal "Unlimited until August 20, 2026", credit_balance_label(user)
  end

  test "credit_balance_label falls back to the balance once the unlimited window has passed" do
    user = users(:jordan)
    user.update!(credits: 2, unlimited_until: 1.day.ago)

    assert_equal "2 credits remaining", credit_balance_label(user)
  end

  test "optimization_cost_status returns no suffix when job_description_text is not yet known" do
    Current.session = Session.new(user: users(:jordan))

    assert_equal [ nil, false ], optimization_cost_status(resume: resumes(:one), job_description_text: nil)
    assert_equal [ nil, false ], optimization_cost_status(resume: resumes(:one), job_description_text: "")
  end

  test "optimization_cost_status flags a cached pair as free even at zero credits" do
    resume = resumes(:one)
    resume.user.update!(credits: 0, unlimited_until: nil)
    Current.session = Session.new(user: resume.user)
    write_cached_entry(resume, "We need a Ruby engineer.")

    suffix, disabled = optimization_cost_status(resume: resume, job_description_text: "We need a Ruby engineer.")

    assert_equal "— free, already generated", suffix
    assert_not disabled
  end

  test "optimization_cost_status flags an uncached pair as costing a credit when one is available" do
    resume = resumes(:one)
    resume.user.update!(credits: 1, unlimited_until: nil)
    Current.session = Session.new(user: resume.user)

    suffix, disabled = optimization_cost_status(resume: resume, job_description_text: "We need a Ruby engineer.")

    assert_equal "— uses 1 credit", suffix
    assert_not disabled
  end

  test "optimization_cost_status flags an uncached pair as disabled at zero credits" do
    resume = resumes(:one)
    resume.user.update!(credits: 0, unlimited_until: nil)
    Current.session = Session.new(user: resume.user)

    suffix, disabled = optimization_cost_status(resume: resume, job_description_text: "We need a Ruby engineer.")

    assert_equal "— out of credits", suffix
    assert disabled
  end

  private

  def write_cached_entry(resume, job_description_text)
    key = Resume::CachedOptimization.cache_key(resume: resume, job_description_text: job_description_text)
    Rails.cache.write(key, :placeholder)
  end
end
