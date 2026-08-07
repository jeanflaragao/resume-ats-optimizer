# The single entry point for Stripe's server-to-server webhook delivery
# (issue #123). Deliberately does not inherit ApplicationController: there is
# no browser here (would fail allow_browser versions: :modern), no session
# cookie (Stripe carries none, so the Authentication concern's
# require_authentication has nothing to resume), and no use for
# ApplicationController's flash-redirect-shaped rescue_from handlers. Answers
# with bare HTTP status codes only.
class Payments::WebhooksController < ActionController::Base
  # CSRF protection exists to stop a browser from being tricked into
  # replaying an authenticated session's cookie; a request with no session to
  # forge has nothing for it to protect.
  skip_before_action :verify_authenticity_token

  def create
    event = Stripe::Webhook.construct_event(
      request.body.read, request.headers["Stripe-Signature"], ENV.fetch("STRIPE_WEBHOOK_SECRET")
    )

    Payments::GrantFromEvent.call(event: event)

    head :ok
  rescue Stripe::SignatureVerificationError, JSON::ParserError => e
    # Class only -- an invalid signature attempt or malformed body could be
    # anything, including an attacker's crafted payload; never echo it back
    # into the logs (ADR-0015).
    Rails.logger.warn("Payments::WebhooksController: #{e.class}")
    head :bad_request
  end
end
