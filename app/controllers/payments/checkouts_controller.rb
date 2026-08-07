# Starts and follows up on a Stripe Checkout purchase (issue #123). Ordinary
# authenticated flow -- inherits ApplicationController like every other
# user-facing controller, unlike Payments::WebhooksController.
class Payments::CheckoutsController < ApplicationController
  def new
    @entries = Payments::Catalog.all
  end

  # {CHECKOUT_SESSION_ID} is Stripe's own literal placeholder syntax --
  # substituted server-side by Stripe before it redirects the browser back
  # here, not something Rails' URL helpers should escape, so it's appended
  # to the generated URL as a raw string rather than passed as a params hash
  # value.
  def create
    checkout_session = Payments::CreateCheckoutSession.call(
      user: Current.user,
      product_key: params[:product],
      success_url: "#{success_payments_checkout_url}?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: new_payments_checkout_url
    )
    redirect_to checkout_session.url, allow_other_host: true
  rescue ArgumentError
    redirect_to new_payments_checkout_path, alert: "That's not a product we sell."
  end

  # The Checkout success_url target. A Checkout Session id reaches here as a
  # real, copyable query param (?session_id=cs_...), the same "URL that could
  # leak or be shared" property download_id has post-ADR-0029 -- so ownership
  # is verified the same way find_owned_resume! verifies it elsewhere, just
  # against Stripe's own record (client_reference_id) instead of a local
  # table, since nothing about this checkout is guaranteed to be persisted
  # locally yet (the webhook may not have landed). A mismatch and a
  # nonexistent session id get the identical response, for the same reason
  # ADR-0029 gives.
  def success
    @checkout_session_id = params[:session_id]
    stripe_checkout_session = Stripe::Checkout::Session.retrieve(@checkout_session_id)
    return if stripe_checkout_session.client_reference_id == Current.user.id.to_s

    redirect_to root_path, alert: "That checkout session could not be found."
  rescue Stripe::InvalidRequestError
    # Stripe itself raises this for a malformed or genuinely nonexistent
    # session id -- same message, same redirect as the ownership mismatch
    # above, deliberately, so the response can't be used to distinguish
    # "not yours" from "doesn't exist" (ADR-0029).
    redirect_to root_path, alert: "That checkout session could not be found."
  end

  # Mirrors DownloadsController#ready exactly: a one-shot fallback for the
  # same race (issue #72/ADR-0018) applied to a second async result type --
  # Payments::GrantFromEvent's broadcast can fire before this page's Turbo
  # Stream subscription has connected. Scoped by user in the same query, so
  # an owner mismatch and "not granted yet" both fall through to the same
  # 204, matching ADR-0030's convergence for the download analog.
  def ready
    if Payments::Grant.exists?(stripe_checkout_session_id: params[:session_id], user: Current.user)
      render partial: "payments/checkouts/ready", locals: { user: Current.user.reload }
    else
      head :no_content
    end
  end
end
