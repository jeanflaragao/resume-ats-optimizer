require "test_helper"
require "turbo/broadcastable/test_helper"

class Payments::GrantFromEventTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  setup do
    @original_price_env = ENV["STRIPE_PRICE_ID_5_CREDITS"]
    ENV["STRIPE_PRICE_ID_5_CREDITS"] = "price_5credits_test"
    @original_unlimited_env = ENV["STRIPE_PRICE_ID_UNLIMITED_30_DAYS"]
    ENV["STRIPE_PRICE_ID_UNLIMITED_30_DAYS"] = "price_unlimited_test"
  end

  teardown do
    ENV["STRIPE_PRICE_ID_5_CREDITS"] = @original_price_env
    ENV["STRIPE_PRICE_ID_UNLIMITED_30_DAYS"] = @original_unlimited_env
  end

  test "grants credits for a checkout.session.completed event paying the 5-credit price" do
    user = users(:jordan)
    user.update!(credits: 2, stripe_customer_id: nil)
    event = build_event(price_id: "price_5credits_test", client_reference_id: user.id.to_s, customer: "cus_new123")

    with_stubbed_line_items("price_5credits_test") do
      assert_turbo_stream_broadcasts "checkout_#{event.data.object.id}" do
        Payments::GrantFromEvent.call(event: event)
      end
    end

    assert_equal 7, user.reload.credits
    assert_equal "cus_new123", user.stripe_customer_id
  end

  test "grants an unlimited window for a checkout.session.completed event paying the unlimited price" do
    user = users(:jordan)
    user.update!(unlimited_until: nil)
    event = build_event(price_id: "price_unlimited_test", client_reference_id: user.id.to_s, customer: "cus_new456")

    with_stubbed_line_items("price_unlimited_test") do
      Payments::GrantFromEvent.call(event: event)
    end

    assert_in_delta 30.days.from_now, user.reload.unlimited_until, 5.seconds
  end

  test "records a Payments::Grant row with the granted amount, not a running total" do
    user = users(:jordan)
    user.update!(credits: 100)
    event = build_event(price_id: "price_5credits_test", client_reference_id: user.id.to_s)

    with_stubbed_line_items("price_5credits_test") do
      Payments::GrantFromEvent.call(event: event)
    end

    grant = Payments::Grant.find_by(stripe_event_id: event.id)
    assert_equal user, grant.user
    assert_equal 5, grant.credits
    assert_nil grant.unlimited_days
    assert_equal "price_5credits_test", grant.stripe_price_id
    assert_equal event.data.object.id, grant.stripe_checkout_session_id
  end

  test "does not backfill stripe_customer_id when the user already has one" do
    user = users(:jordan)
    user.update!(stripe_customer_id: "cus_original")
    event = build_event(price_id: "price_5credits_test", client_reference_id: user.id.to_s, customer: "cus_different")

    with_stubbed_line_items("price_5credits_test") do
      Payments::GrantFromEvent.call(event: event)
    end

    assert_equal "cus_original", user.reload.stripe_customer_id
  end

  test "ignores an event type other than checkout.session.completed" do
    user = users(:jordan)
    user.update!(credits: 2)
    event = build_event(price_id: "price_5credits_test", client_reference_id: user.id.to_s, type: "payment_intent.succeeded")

    Payments::GrantFromEvent.call(event: event)

    assert_equal 2, user.reload.credits
    assert_nil Payments::Grant.find_by(stripe_event_id: event.id)
  end

  test "ignores a session whose payment_status is not paid" do
    user = users(:jordan)
    user.update!(credits: 2)
    event = build_event(price_id: "price_5credits_test", client_reference_id: user.id.to_s, payment_status: "unpaid")

    Payments::GrantFromEvent.call(event: event)

    assert_equal 2, user.reload.credits
  end

  test "ignores a price id that matches no configured product, without raising" do
    user = users(:jordan)
    user.update!(credits: 2)
    event = build_event(price_id: "price_5credits_test", client_reference_id: user.id.to_s)

    with_stubbed_line_items("price_totally_unrecognized") do
      assert_nothing_raised { Payments::GrantFromEvent.call(event: event) }
    end

    assert_equal 2, user.reload.credits
  end

  test "ignores a client_reference_id that matches no user, without raising" do
    event = build_event(price_id: "price_5credits_test", client_reference_id: "999999999")

    with_stubbed_line_items("price_5credits_test") do
      assert_nothing_raised { Payments::GrantFromEvent.call(event: event) }
    end

    assert_nil Payments::Grant.find_by(stripe_event_id: event.id)
  end

  # --- Idempotency: the required acceptance criterion ------------------------
  #
  # NON-VACUITY (CLAUDE.md's "prove new safety assertions are non-vacuous"):
  # this test was first run with the unique index on stripe_event_id dropped
  # (a local schema edit) and the ActiveRecord::RecordNotUnique rescue in
  # Payments::GrantFromEvent#call removed, and failed by granting credits
  # twice (12, not 7) for the exact same event delivered twice. Output
  # recorded in the PR body. Restoring both is what makes it pass.
  test "the same event delivered twice grants credits exactly once" do
    user = users(:jordan)
    user.update!(credits: 2)
    event = build_event(price_id: "price_5credits_test", client_reference_id: user.id.to_s)

    with_stubbed_line_items("price_5credits_test") do
      Payments::GrantFromEvent.call(event: event)
      Payments::GrantFromEvent.call(event: event)
    end

    assert_equal 7, user.reload.credits, "a replayed event must not double-grant"
    assert_equal 1, Payments::Grant.where(stripe_event_id: event.id).count
  end

  test "a replayed event does not broadcast a second time" do
    user = users(:jordan)
    event = build_event(price_id: "price_5credits_test", client_reference_id: user.id.to_s)

    # assert_no_turbo_stream_broadcasts checks the whole stream's accumulated
    # broadcasts, not just what happened inside its own block -- so both
    # calls have to be inside one assertion window, asserting the total
    # across both is exactly 1, not "zero happened during the second call".
    with_stubbed_line_items("price_5credits_test") do
      assert_turbo_stream_broadcasts "checkout_#{event.data.object.id}", count: 1 do
        Payments::GrantFromEvent.call(event: event)
        Payments::GrantFromEvent.call(event: event)
      end
    end
  end

  private

  def build_event(price_id:, client_reference_id:, customer: "cus_test", type: Payments::GrantFromEvent::HANDLED_EVENT_TYPE, payment_status: "paid")
    Stripe::Event.construct_from(
      id: "evt_#{SecureRandom.hex(12)}",
      type: type,
      data: {
        object: {
          id: "cs_#{SecureRandom.hex(12)}",
          object: "checkout.session",
          payment_status: payment_status,
          client_reference_id: client_reference_id,
          customer: customer
        }
      }
    )
  end

  def with_stubbed_line_items(price_id)
    original = Stripe::Checkout::Session.method(:list_line_items)
    line_item = Struct.new(:price).new(Struct.new(:id).new(price_id))
    Stripe::Checkout::Session.define_singleton_method(:list_line_items) do |*|
      Struct.new(:data).new([ line_item ])
    end
    yield
  ensure
    Stripe::Checkout::Session.define_singleton_method(:list_line_items, original)
  end
end
