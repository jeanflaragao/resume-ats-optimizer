require "test_helper"

class CreditTest < ActiveSupport::TestCase
  test "available? is true with a positive balance" do
    user = users(:jordan)
    user.update!(credits: 1, unlimited_until: nil)

    assert Credit.available?(user)
  end

  test "available? is false at zero credits with no unlimited window" do
    user = users(:jordan)
    user.update!(credits: 0, unlimited_until: nil)

    assert_not Credit.available?(user)
  end

  test "available? is true at zero credits inside an active unlimited window" do
    user = users(:jordan)
    user.update!(credits: 0, unlimited_until: 1.day.from_now)

    assert Credit.available?(user)
  end

  test "available? is false once the unlimited window has passed, falling back to the balance" do
    user = users(:jordan)
    user.update!(credits: 0, unlimited_until: 1.day.ago)

    assert_not Credit.available?(user)
  end

  test "consume! decrements the balance by one" do
    user = users(:jordan)
    user.update!(credits: 2, unlimited_until: nil)

    Credit.consume!(user)

    assert_equal 1, user.reload.credits
  end

  test "consume! is unconditional -- it can take the balance to -1 rather than refuse" do
    user = users(:jordan)
    user.update!(credits: 0, unlimited_until: nil)

    Credit.consume!(user)

    assert_equal(-1, user.reload.credits)
  end

  test "consume! does not touch the balance inside an active unlimited window" do
    user = users(:jordan)
    user.update!(credits: 2, unlimited_until: 1.day.from_now)

    Credit.consume!(user)

    assert_equal 2, user.reload.credits
  end

  test "consume! does touch the balance once the unlimited window has passed" do
    user = users(:jordan)
    user.update!(credits: 2, unlimited_until: 1.day.ago)

    Credit.consume!(user)

    assert_equal 1, user.reload.credits
  end
end
