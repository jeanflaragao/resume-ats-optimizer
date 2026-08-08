# Wraps Stripe::Checkout::Session.create for the one authenticated action that
# starts a purchase (issue #123). Deliberately thin: the only two things worth
# naming here are (a) client_reference_id, set from the *authenticated*
# Current.user, never from anything the browser submits -- this is what lets
# the webhook resolve "which user" without a session cookie, unforgeably --
# and (b) customer_creation: "always", which guarantees session.customer is
# populated for stripe_customer_id backfilling even on a user's very first
# purchase (payment-mode Checkout sessions don't create a Customer object by
# default otherwise).
#
# Everything about *what this session grants* is deliberately absent from
# this class -- Payments::GrantFromEvent derives that later, from the
# completed event's own line items, never from anything decided here.
class Payments::CreateCheckoutSession
  def self.call(user:, product_key:, success_url:, cancel_url:)
    new(user: user, product_key: product_key, success_url: success_url, cancel_url: cancel_url).call
  end

  def initialize(user:, product_key:, success_url:, cancel_url:)
    @user = user
    @entry = Payments::Catalog.find(product_key)
    @success_url = success_url
    @cancel_url = cancel_url
  end

  def call
    Stripe::Checkout::Session.create(session_params)
  end

  private

  attr_reader :user, :entry, :success_url, :cancel_url

  def session_params
    {
      mode: "payment",
      payment_method_types: [ "card" ],
      line_items: [ { price: Payments::Catalog.price_id_for(entry.key), quantity: 1 } ],
      client_reference_id: user.id.to_s,
      success_url: success_url,
      cancel_url: cancel_url
    }.merge(customer_params)
  end

  # Reuse the same Stripe Customer across a user's purchases once one exists,
  # rather than letting Stripe mint a new Customer object per session.
  def customer_params
    if user.stripe_customer_id.present?
      { customer: user.stripe_customer_id }
    else
      { customer_email: user.email, customer_creation: "always" }
    end
  end
end
