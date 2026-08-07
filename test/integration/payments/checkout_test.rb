require "test_helper"

class Payments::CheckoutTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:jordan))
    @original_price_env = ENV["STRIPE_PRICE_ID_5_CREDITS"]
    ENV["STRIPE_PRICE_ID_5_CREDITS"] = "price_5credits_test"
  end

  teardown do
    ENV["STRIPE_PRICE_ID_5_CREDITS"] = @original_price_env
  end

  test "the buy-credits page lists all three products with their price" do
    get new_payments_checkout_path

    assert_response :success
    assert_includes response.body, "5 credits"
    assert_includes response.body, "R$ 14.90"
    assert_includes response.body, "15 credits"
    assert_includes response.body, "30-day unlimited"
  end

  test "starting checkout for a known product redirects to the Stripe-hosted URL" do
    with_stubbed_session_create("https://checkout.stripe.com/fake-session") do
      post payments_checkout_path, params: { product: "five_credits" }
    end

    assert_redirected_to "https://checkout.stripe.com/fake-session"
  end

  test "starting checkout for an unknown product redirects back without calling Stripe" do
    called = false
    original = Stripe::Checkout::Session.method(:create)
    Stripe::Checkout::Session.define_singleton_method(:create) { |*| called = true }

    post payments_checkout_path, params: { product: "not_a_real_product" }

    assert_redirected_to new_payments_checkout_path
    assert_not called
  ensure
    Stripe::Checkout::Session.define_singleton_method(:create, original)
  end

  test "the success page renders for the checkout session's own owner" do
    with_stubbed_session_retrieve(client_reference_id: users(:jordan).id.to_s) do
      get success_payments_checkout_path(session_id: "cs_owned_by_jordan")
    end

    assert_response :success
    assert_includes response.body, "Confirming your payment"
  end

  test "the success page redirects, not renders, when the session belongs to a different user" do
    with_stubbed_session_retrieve(client_reference_id: users(:alex).id.to_s) do
      get success_payments_checkout_path(session_id: "cs_owned_by_alex")
    end

    assert_redirected_to root_path
    follow_redirect!
    assert_includes response.body, "could not be found"
  end

  test "the success page gives the identical response for a nonexistent session id" do
    with_stubbed_session_retrieve(raises: true) do
      get success_payments_checkout_path(session_id: "cs_does_not_exist")
    end

    assert_redirected_to root_path
    follow_redirect!
    assert_includes response.body, "could not be found"
  end

  test "#ready returns no content before the grant has landed" do
    get ready_payments_checkout_path(session_id: "cs_never_granted")

    assert_response :no_content
    assert_empty response.body
  end

  test "#ready renders the ready partial once the grant has landed" do
    user = users(:jordan)
    Payments::Grant.create!(
      user: user, stripe_event_id: "evt_test", stripe_checkout_session_id: "cs_granted_already",
      stripe_price_id: "price_5credits_test", credits: 5
    )

    get ready_payments_checkout_path(session_id: "cs_granted_already")

    assert_response :success
    assert_includes response.body, "Payment received"
  end

  test "#ready does not leak another user's grant" do
    Payments::Grant.create!(
      user: users(:alex), stripe_event_id: "evt_test2", stripe_checkout_session_id: "cs_alex_only",
      stripe_price_id: "price_5credits_test", credits: 5
    )

    get ready_payments_checkout_path(session_id: "cs_alex_only")

    assert_response :no_content
  end

  private

  def with_stubbed_session_create(url)
    original = Stripe::Checkout::Session.method(:create)
    Stripe::Checkout::Session.define_singleton_method(:create) do |*|
      Struct.new(:url, :id).new(url, "cs_fake")
    end
    yield
  ensure
    Stripe::Checkout::Session.define_singleton_method(:create, original)
  end

  def with_stubbed_session_retrieve(client_reference_id: nil, raises: false)
    original = Stripe::Checkout::Session.method(:retrieve)
    Stripe::Checkout::Session.define_singleton_method(:retrieve) do |*|
      raise Stripe::InvalidRequestError.new("No such checkout session", "id") if raises

      Struct.new(:client_reference_id).new(client_reference_id)
    end
    yield
  ensure
    Stripe::Checkout::Session.define_singleton_method(:retrieve, original)
  end
end
