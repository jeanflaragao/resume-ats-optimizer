class AddStripeCustomerIdAndPaymentGrants < ActiveRecord::Migration[8.1]
  def change
    # Nullable: not every user has purchased yet. Unique because it's a 1:1
    # link to a Stripe Customer object, backfilled on first purchase and
    # reused on every subsequent Checkout session (issue #123).
    add_column :users, :stripe_customer_id, :string
    add_index :users, :stripe_customer_id, unique: true

    # Issue #123: the idempotency guard for webhook-driven grants (a Stripe
    # retry must not double-grant) and, incidentally, an audit trail of what
    # was granted for which event. The DB-level unique index on
    # stripe_event_id -- not a Rails uniqueness validation, which is a
    # SELECT-then-INSERT race the same shape Credit.consume! already had to
    # avoid -- is the actual safety property: a replayed event's INSERT
    # raises and aborts the whole grant transaction atomically.
    #
    # stripe_checkout_session_id is also unique (one session completes once)
    # and is what the pending-payment page's #ready fallback looks up by, so
    # it doesn't need a live Stripe API call to answer "has this landed yet".
    # credits/unlimited_days both record what THIS grant added, not a running
    # total -- consistent with each other, and avoids needing an audit-time
    # read of the user's current balance that could itself race a concurrent
    # grant. The authoritative resulting balance is always users.credits/
    # users.unlimited_until, computed atomically by Credit.grant_credits!/
    # grant_unlimited_days!, never recomputed or duplicated here.
    create_table :payment_grants do |t|
      t.references :user, null: false, foreign_key: true
      t.string :stripe_event_id, null: false
      t.string :stripe_checkout_session_id, null: false
      t.string :stripe_price_id, null: false
      t.integer :credits
      t.integer :unlimited_days

      t.timestamps
    end
    add_index :payment_grants, :stripe_event_id, unique: true
    add_index :payment_grants, :stripe_checkout_session_id, unique: true
  end
end
