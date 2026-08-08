require "application_system_test_case"

# The one real-browser test for this feature: proves the "buy credits" form's
# CSRF token is genuine and accepted, the same thing that caught a real bug
# for the download flow (issue #57/ADR-0013) that no integration test could
# see, since integration tests never render real forms or carry real tokens.
#
# Stubs Stripe::Checkout::Session.create to redirect back into this app
# itself (not a real checkout.stripe.com URL) -- Capybara/Chrome would
# actually try to load an external URL for real, which is both a genuine
# network dependency in CI and pointless here: what this test needs to prove
# is that the POST was accepted and redirected, not what Stripe's hosted page
# looks like.
class Payments::CheckoutTest < ApplicationSystemTestCase
  test "clicking a product's buy button submits a real, CSRF-protected form and redirects" do
    sign_in_as_in_browser(users(:jordan))
    stub_checkout_session_create(new_resume_url)
    original_price_env = ENV["STRIPE_PRICE_ID_5_CREDITS"]
    ENV["STRIPE_PRICE_ID_5_CREDITS"] = "price_5credits_system_test"

    visit new_payments_checkout_path
    assert_text "Buy credits"

    click_on "R$ 14.90"

    assert_text "Upload your LinkedIn export"
  ensure
    restore_checkout_session_create
    ENV["STRIPE_PRICE_ID_5_CREDITS"] = original_price_env
  end

  private

  def stub_checkout_session_create(url)
    @original_create = Stripe::Checkout::Session.method(:create)
    Stripe::Checkout::Session.define_singleton_method(:create) do |*|
      Struct.new(:url, :id).new(url, "cs_system_test_fake")
    end
  end

  def restore_checkout_session_create
    Stripe::Checkout::Session.define_singleton_method(:create, @original_create) if @original_create
  end
end
