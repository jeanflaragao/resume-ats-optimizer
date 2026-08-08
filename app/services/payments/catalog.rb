# The three one-off products this app sells (issue #123). ENV holds the
# Stripe-specific, deploy-scoped half of each entry (a Price id is different
# per Stripe account/mode, exactly like ANTHROPIC_API_KEY); the grant amount
# and BRL price are business logic and belong in code, reviewed like any
# other constant -- see Usage::Quota::ACTION_LABELS for the same split
# elsewhere in this app.
#
# Named "Catalog", not "Product" or "Price": this app's own gem dependency
# already defines Stripe::Product and Stripe::Price as real API resources,
# and a same-named app-level class next to them would be confusing to read,
# even though the namespaces don't actually collide.
class Payments::Catalog
  Entry = Data.define(:key, :env_var, :credits, :unlimited_days, :amount_cents, :label)

  ENTRIES = [
    Entry.new(key: :five_credits, env_var: "STRIPE_PRICE_ID_5_CREDITS",
              credits: 5, unlimited_days: nil, amount_cents: 1490, label: "5 credits"),
    Entry.new(key: :fifteen_credits, env_var: "STRIPE_PRICE_ID_15_CREDITS",
              credits: 15, unlimited_days: nil, amount_cents: 2490, label: "15 credits"),
    Entry.new(key: :unlimited_30_days, env_var: "STRIPE_PRICE_ID_UNLIMITED_30_DAYS",
              credits: nil, unlimited_days: 30, amount_cents: 3990, label: "30-day unlimited")
  ].freeze

  class << self
    def all
      ENTRIES
    end

    def find(key)
      ENTRIES.find { |entry| entry.key == key.to_sym } or
        raise ArgumentError, "unknown product #{key.inspect}"
    end

    # Forward lookup, for creating a Checkout Session: which Price id to bill.
    def price_id_for(key)
      ENV.fetch(find(key).env_var)
    end

    # Reverse lookup, for the webhook: given the Price id Stripe reports as
    # actually paid, which entry (and therefore which grant) does it mean.
    # Reads ENV at call time, not at class-load time -- same reason
    # Usage::Quota.limit_for doesn't memoize at boot: the mapping must reflect
    # whatever's configured right now, not whatever was configured when this
    # class first loaded.
    def for_price_id(price_id)
      ENTRIES.find { |entry| ENV[entry.env_var] == price_id }
    end
  end
end
