# The idempotency guard for a webhook-driven credit/unlimited-window grant
# (issue #123), and incidentally an audit trail of what was granted for which
# Stripe event. The DB-level unique index on stripe_event_id -- not a Rails
# uniqueness validation, which would be a SELECT-then-INSERT race the same
# shape Credit.consume! already had to avoid -- is the actual safety
# property: Payments::GrantFromEvent relies on the INSERT itself raising
# ActiveRecord::RecordNotUnique for a replayed event, aborting the whole
# grant transaction atomically. No validates :stripe_event_id, uniqueness:
# true here, deliberately, to avoid implying the model layer is what
# enforces this.
#
# self.table_name set explicitly, matching Usage::Counter's precedent, rather
# than relying on Rails' nested-model table-name inference for a namespaced
# class.
class Payments::Grant < ApplicationRecord
  self.table_name = "payment_grants"

  belongs_to :user
end
