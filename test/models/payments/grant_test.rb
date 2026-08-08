require "test_helper"

class Payments::GrantTest < ActiveSupport::TestCase
  test "uses the payment_grants table" do
    assert_equal "payment_grants", Payments::Grant.table_name
  end

  test "belongs to a user" do
    grant = Payments::Grant.create!(
      user: users(:jordan), stripe_event_id: "evt_#{SecureRandom.hex(8)}",
      stripe_checkout_session_id: "cs_#{SecureRandom.hex(8)}",
      stripe_price_id: "price_123", credits: 5
    )

    assert_equal users(:jordan), grant.user
  end

  test "the database refuses a second row for the same stripe_event_id" do
    event_id = "evt_#{SecureRandom.hex(8)}"
    Payments::Grant.create!(
      user: users(:jordan), stripe_event_id: event_id,
      stripe_checkout_session_id: "cs_#{SecureRandom.hex(8)}",
      stripe_price_id: "price_123", credits: 5
    )

    assert_raises(ActiveRecord::RecordNotUnique) do
      Payments::Grant.create!(
        user: users(:alex), stripe_event_id: event_id,
        stripe_checkout_session_id: "cs_#{SecureRandom.hex(8)}",
        stripe_price_id: "price_123", credits: 5
      )
    end
  end

  test "the database refuses a second row for the same stripe_checkout_session_id" do
    session_id = "cs_#{SecureRandom.hex(8)}"
    Payments::Grant.create!(
      user: users(:jordan), stripe_event_id: "evt_#{SecureRandom.hex(8)}",
      stripe_checkout_session_id: session_id,
      stripe_price_id: "price_123", credits: 5
    )

    assert_raises(ActiveRecord::RecordNotUnique) do
      Payments::Grant.create!(
        user: users(:alex), stripe_event_id: "evt_#{SecureRandom.hex(8)}",
        stripe_checkout_session_id: session_id,
        stripe_price_id: "price_123", credits: 5
      )
    end
  end
end
