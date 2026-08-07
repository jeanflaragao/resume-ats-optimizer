require "test_helper"

class Payments::CreateCheckoutSessionTest < ActiveSupport::TestCase
  setup do
    @original_price_env = ENV["STRIPE_PRICE_ID_5_CREDITS"]
    ENV["STRIPE_PRICE_ID_5_CREDITS"] = "price_5credits_test"
  end

  teardown do
    ENV["STRIPE_PRICE_ID_5_CREDITS"] = @original_price_env
  end

  test "creates a payment-mode, card-only session with client_reference_id set from the user" do
    user = users(:jordan)
    user.update!(stripe_customer_id: nil)
    captured = with_stubbed_session_create do
      Payments::CreateCheckoutSession.call(
        user: user, product_key: :five_credits,
        success_url: "https://example.com/success", cancel_url: "https://example.com/cancel"
      )
    end

    assert_equal "payment", captured[:mode]
    assert_equal [ "card" ], captured[:payment_method_types]
    assert_equal [ { price: "price_5credits_test", quantity: 1 } ], captured[:line_items]
    assert_equal user.id.to_s, captured[:client_reference_id]
    assert_equal "https://example.com/success", captured[:success_url]
    assert_equal "https://example.com/cancel", captured[:cancel_url]
  end

  test "passes customer_email and forces customer_creation when the user has no stripe_customer_id yet" do
    user = users(:jordan)
    user.update!(stripe_customer_id: nil)

    captured = with_stubbed_session_create do
      Payments::CreateCheckoutSession.call(user: user, product_key: :five_credits, success_url: "s", cancel_url: "c")
    end

    assert_equal user.email, captured[:customer_email]
    assert_equal "always", captured[:customer_creation]
    assert_nil captured[:customer]
  end

  test "reuses the existing stripe_customer_id instead of customer_email once one exists" do
    user = users(:jordan)
    user.update!(stripe_customer_id: "cus_existing123")

    captured = with_stubbed_session_create do
      Payments::CreateCheckoutSession.call(user: user, product_key: :five_credits, success_url: "s", cancel_url: "c")
    end

    assert_equal "cus_existing123", captured[:customer]
    assert_nil captured[:customer_email]
    assert_nil captured[:customer_creation]
  end

  test "raises for an unknown product key before ever calling Stripe" do
    called = false
    original = Stripe::Checkout::Session.method(:create)
    Stripe::Checkout::Session.define_singleton_method(:create) { |*| called = true }

    assert_raises(ArgumentError) do
      Payments::CreateCheckoutSession.call(user: users(:jordan), product_key: :nonexistent, success_url: "s", cancel_url: "c")
    end
    assert_not called, "Stripe must never be called for an invalid product key"
  ensure
    Stripe::Checkout::Session.define_singleton_method(:create, original)
  end

  private

  def with_stubbed_session_create
    captured = nil
    original = Stripe::Checkout::Session.method(:create)
    Stripe::Checkout::Session.define_singleton_method(:create) do |params|
      captured = params
      Struct.new(:url, :id).new("https://checkout.stripe.com/fake-session", "cs_fake123")
    end
    yield
    captured
  ensure
    Stripe::Checkout::Session.define_singleton_method(:create, original)
  end
end
