# The webhook's entire reason to exist (issue #123): turn a verified Stripe
# event into a credit/unlimited-window grant. Signature verification already
# happened by the time this class is ever called (Payments::WebhooksController)
# -- everything here assumes `event` is genuine.
#
# Never trusts anything set at Checkout-session-creation time. The grant is
# derived from the price Stripe itself reports as paid
# (list_line_items(session.id), not session.metadata or anything else this
# app might have set earlier) -- deliberately stricter than trusting our own
# prior intent, so a tampered or diverged session-creation request still only
# grants what was actually paid for.
class Payments::GrantFromEvent
  HANDLED_EVENT_TYPE = "checkout.session.completed"

  def self.call(event:)
    new(event: event).call
  end

  def initialize(event:)
    @event = event
  end

  def call
    return unless relevant?

    entry = Payments::Catalog.for_price_id(price_id)
    return log_and_skip("unrecognized Stripe price id") if entry.nil?

    user = User.find_by(id: session.client_reference_id)
    return log_and_skip("no user for client_reference_id") if user.nil?

    grant!(user: user, entry: entry)
  rescue ActiveRecord::RecordNotUnique
    # The expected shape of a Stripe retry: the unique index on
    # stripe_event_id (or stripe_checkout_session_id) refused a second row,
    # which rolled back the whole transaction below before any credit/
    # unlimited_until write landed a second time. This is success, not an
    # error -- Payments::WebhooksController still answers 200 either way,
    # which is what stops Stripe from retrying further.
    Rails.logger.info("Payments::GrantFromEvent: event already processed, no-op")
  end

  private

  attr_reader :event

  # Only checkout.session.completed is handled; anything else no-ops rather
  # than raising, so a Stripe dashboard misconfiguration (subscribing to more
  # event types than intended) can't turn into errors. payment_status ==
  # "paid" is always true for v1's card-only flow (card payments confirm
  # synchronously) -- this check only starts to matter if/when Pix is added
  # later, since Pix confirms asynchronously and a session can reach
  # "completed" with payment_status still "unpaid" for it.
  def relevant?
    event.type == HANDLED_EVENT_TYPE && session.payment_status == "paid"
  end

  def session
    @session ||= event.data.object
  end

  # Not expanded on the event payload by default -- a follow-up API call,
  # deliberately, so the grant always reflects what Stripe's own records say
  # was actually charged, not anything decided at session-creation time.
  def price_id
    @price_id ||= Stripe::Checkout::Session.list_line_items(session.id, limit: 1).data.first.price.id
  end

  def grant!(user:, entry:)
    ActiveRecord::Base.transaction do
      Payments::Grant.create!(
        stripe_event_id: event.id,
        stripe_checkout_session_id: session.id,
        user: user,
        stripe_price_id: price_id,
        credits: entry.credits,
        unlimited_days: entry.unlimited_days
      )

      Credit.grant_credits!(user, entry.credits) if entry.credits
      Credit.grant_unlimited_days!(user, entry.unlimited_days) if entry.unlimited_days
      backfill_stripe_customer_id!(user)
    end

    broadcast_ready(user)
  end

  # Only on a user's first purchase -- session.customer is always populated
  # (Payments::CreateCheckoutSession forces customer_creation on that first
  # session), and every later purchase reuses the existing id instead of
  # passing customer_email again, so this is a no-op after the first grant.
  def backfill_stripe_customer_id!(user)
    return if user.stripe_customer_id.present? || session.customer.blank?

    User.where(id: user.id, stripe_customer_id: nil).update_all(stripe_customer_id: session.customer)
  end

  # Mirrors Resume::OptimizedPdfJob's broadcast_replace_to shape exactly --
  # same live-update-once-the-async-result-lands pattern, a second use of it
  # (issue #72/ADR-0018). Only reached after the transaction above commits,
  # so a replayed event (caught by RecordNotUnique above, before this line)
  # never re-broadcasts.
  def broadcast_ready(user)
    Turbo::StreamsChannel.broadcast_replace_to(
      "checkout_#{session.id}",
      target: "checkout_status",
      partial: "payments/checkouts/ready",
      locals: { user: user }
    )
  end

  # event.id (an opaque evt_... token, safe to log, same as this app logging
  # a download_id elsewhere) plus a fixed reason string -- never the event/
  # session payload itself, which embeds the customer's email and other
  # checkout details (ADR-0015), even for an unrecognized-price/unknown-user
  # case that should never happen in practice.
  def log_and_skip(reason)
    Rails.logger.warn("Payments::GrantFromEvent: skipped event #{event.id} (#{reason})")
    nil
  end
end
