require "test_helper"

# The one controller test that proves signature verification is actually
# wired end to end -- Payments::GrantFromEventTest covers the grant logic
# itself in isolation, with no real HTTP request or signature involved.
class Payments::WebhooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_secret = ENV["STRIPE_WEBHOOK_SECRET"]
    ENV["STRIPE_WEBHOOK_SECRET"] = "whsec_test_secret"
    @original_price_env = ENV["STRIPE_PRICE_ID_5_CREDITS"]
    ENV["STRIPE_PRICE_ID_5_CREDITS"] = "price_5credits_test"
  end

  teardown do
    ENV["STRIPE_WEBHOOK_SECRET"] = @original_secret
    ENV["STRIPE_PRICE_ID_5_CREDITS"] = @original_price_env
  end

  test "a validly signed event is accepted and grants credits" do
    user = users(:jordan)
    user.update!(credits: 2)
    payload = build_payload(client_reference_id: user.id.to_s)

    with_stubbed_line_items("price_5credits_test") do
      post payments_webhooks_path, params: payload, headers: signed_headers(payload).merge("CONTENT_TYPE" => "application/json")
    end

    assert_response :success
    assert_equal 7, user.reload.credits
  end

  test "an unsigned request is refused and grants nothing" do
    user = users(:jordan)
    user.update!(credits: 2)
    payload = build_payload(client_reference_id: user.id.to_s)

    with_stubbed_line_items("price_5credits_test") do
      post payments_webhooks_path, params: payload, headers: { "CONTENT_TYPE" => "application/json" }
    end

    assert_response :bad_request
    assert_equal 2, user.reload.credits
  end

  test "a wrongly signed request is refused and grants nothing" do
    user = users(:jordan)
    user.update!(credits: 2)
    payload = build_payload(client_reference_id: user.id.to_s)
    bogus_header = Stripe::Webhook::Signature.generate_header(Time.current, "not-the-real-signature")

    with_stubbed_line_items("price_5credits_test") do
      post payments_webhooks_path, params: payload,
        headers: { "Stripe-Signature" => bogus_header, "CONTENT_TYPE" => "application/json" }
    end

    assert_response :bad_request
    assert_equal 2, user.reload.credits
  end

  test "a request signed with the wrong secret is refused and grants nothing" do
    user = users(:jordan)
    user.update!(credits: 2)
    payload = build_payload(client_reference_id: user.id.to_s)
    timestamp = Time.current
    wrong_secret_signature = Stripe::Webhook::Signature.compute_signature(timestamp, payload, "whsec_completely_different")
    header = Stripe::Webhook::Signature.generate_header(timestamp, wrong_secret_signature)

    with_stubbed_line_items("price_5credits_test") do
      post payments_webhooks_path, params: payload,
        headers: { "Stripe-Signature" => header, "CONTENT_TYPE" => "application/json" }
    end

    assert_response :bad_request
    assert_equal 2, user.reload.credits
  end

  private

  def build_payload(client_reference_id:)
    {
      id: "evt_#{SecureRandom.hex(12)}",
      type: "checkout.session.completed",
      data: {
        object: {
          id: "cs_#{SecureRandom.hex(12)}",
          object: "checkout.session",
          payment_status: "paid",
          client_reference_id: client_reference_id,
          customer: "cus_test"
        }
      }
    }.to_json
  end

  def signed_headers(payload)
    timestamp = Time.current
    signature = Stripe::Webhook::Signature.compute_signature(timestamp, payload, ENV["STRIPE_WEBHOOK_SECRET"])
    { "Stripe-Signature" => Stripe::Webhook::Signature.generate_header(timestamp, signature) }
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
